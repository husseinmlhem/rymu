// Rymu control plane. The upstream stream is encrypted before any grant is sent.
#[cfg(windows)]
pub(crate) mod privacy;

use base::message_proto::{
    message, misc, Clipboard, ClipboardFormat, Hash, LoginRequest, Message, PeerInfo,
};
use hbb_common::{
    anyhow::{bail, Context},
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine},
    config::Config,
    protobuf::Message as _,
    sodiumoxide::{crypto::sign, randombytes::randombytes},
    tokio::{
        sync::Notify,
        time::{sleep, sleep_until, timeout, Duration, Instant},
    },
    ResultType, Stream,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io::Read,
    sync::{
        atomic::{AtomicI32, Ordering},
        Arc, Mutex,
    },
};
use url::Url;

pub(crate) mod files;
mod relay;

const MARKER: &str = "RYMU-AUTH-V1";
const DISPLAY_POLICY_VERSION: u8 = 1;
const LEASE: Duration = Duration::from_secs(45);
const RENEW: Duration = Duration::from_secs(15);
const API_TIMEOUT: Duration = Duration::from_secs(4);
const MAX_CONTROL_MESSAGE: usize = 65_536;

lazy_static::lazy_static! {
    static ref TRANSPORT: Mutex<Option<TransportMode>> = Mutex::new(None);
    static ref TICKETS: Mutex<HashMap<(String, bool), (Instant, Ticket)>> = Mutex::new(HashMap::new());
    static ref HOST: Mutex<Option<Host>> = Mutex::new(None);
    static ref HOST_CHANGED: Notify = Notify::new();
    static ref MANAGED_LISTENER: Mutex<Option<uuid::Uuid>> = Mutex::new(None);
    static ref PAIRS: Mutex<HashMap<String, Vec<String>>> = Mutex::new(HashMap::new());
    static ref RECONNECT: Mutex<HashMap<String, Reconnect>> = Mutex::new(HashMap::new());
    static ref VIEWER_CLIPBOARD: Mutex<Option<String>> = Mutex::new(None);
    static ref HTTP: Result<reqwest::Client, reqwest::Error> = reqwest::Client::builder()
        .use_rustls_tls().no_proxy().redirect(reqwest::redirect::Policy::none())
        .timeout(API_TIMEOUT).build();
}
static HOST_CLIPBOARD: AtomicI32 = AtomicI32::new(0);

pub(crate) fn host_select_clipboard(id: i32) {
    HOST_CLIPBOARD.store(id, Ordering::Release);
}

pub(crate) fn host_release_clipboard(id: i32) {
    let _ = HOST_CLIPBOARD.compare_exchange(id, 0, Ordering::AcqRel, Ordering::Relaxed);
}

pub(crate) fn host_owns_clipboard(id: i32) -> bool {
    HOST_CLIPBOARD.load(Ordering::Acquire) == id
}

pub(crate) fn viewer_owns_clipboard(peer: &str) -> bool {
    VIEWER_CLIPBOARD.lock().unwrap().as_deref() == Some(peer)
}

pub(crate) fn is_clipboard(msg: &Message) -> bool {
    matches!(
        msg.union.as_ref(),
        Some(
            message::Union::Clipboard(_)
                | message::Union::MultiClipboards(_)
                | message::Union::Cliprdr(_)
        )
    )
}

pub(crate) const MAX_FILE_BLOCK: usize = 1024 * 1024;

pub(crate) fn decompress_bounded(payload: &[u8], limit: usize) -> Option<Vec<u8>> {
    if payload.len() > limit {
        return None;
    }
    let decoder = zstd::Decoder::new(payload).ok()?;
    let mut bytes = Vec::new();
    decoder
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= limit).then_some(bytes)
}

fn plain_text(clip: &mut Clipboard) -> bool {
    const MAX: usize = 1024 * 1024;
    if clip.format.enum_value() != Ok(ClipboardFormat::Text) || clip.content.len() > MAX {
        return false;
    }
    if clip.compress {
        let Some(bytes) = decompress_bounded(&clip.content, MAX) else {
            return false;
        };
        clip.content = bytes.into();
        clip.compress = false;
    }
    std::str::from_utf8(&clip.content).is_ok()
}

/// Bound content before handing it to any platform clipboard implementation.
/// CLIPRDR, images, HTML, RTF and custom OS formats are outside the Rymu scope.
pub(crate) fn filter_clipboard(msg: &mut Message) -> bool {
    match msg.union.as_mut() {
        Some(message::Union::Clipboard(clip)) => plain_text(clip),
        Some(message::Union::MultiClipboards(multi)) => {
            if multi.clipboards.len() > 16 {
                return false;
            }
            multi.clipboards.retain_mut(plain_text);
            multi.clipboards.truncate(1);
            !multi.clipboards.is_empty()
        }
        Some(message::Union::Cliprdr(_)) => false,
        _ => true,
    }
}

#[derive(Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Transport {
    pub rendezvous_server: String,
    pub relay_server: String,
    pub rendezvous_key: String,
}

#[derive(PartialEq, Eq)]
enum TransportMode {
    Raw(Transport),
    Managed,
}

fn endpoint(raw: &str) -> bool {
    if raw.is_empty()
        || raw.len() > 253
        || !raw
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".:-[]".contains(&b))
    {
        return false;
    }
    let Ok(url) = Url::parse(&format!("http://{raw}/")) else {
        return false;
    };
    let host = url.host_str().unwrap_or_default().trim_end_matches('.');
    !host.is_empty() && host != "rustdesk.com" && !host.ends_with(".rustdesk.com")
}

fn configure_request(input: &Value) -> ResultType<bool> {
    if let Some(mode) = input.get("transportMode") {
        if mode.as_str() != Some("managed")
            || ["rendezvousServer", "relayServer", "rendezvousKey"]
                .iter().any(|key| input.get(*key).is_some())
        {
            bail!("Invalid Rymu transport mode");
        }
        replace_transport(Some(TransportMode::Managed));
        return Ok(true);
    }
    let t: Transport = serde_json::from_value(input.clone())?;
    if !endpoint(&t.rendezvous_server)
        || !endpoint(&t.relay_server)
        || crate::get_rs_pk(&t.rendezvous_key).is_none()
    {
        bail!("Enter a private rendezvous server, relay and server key.");
    }
    replace_transport(Some(TransportMode::Raw(t)));
    Ok(false)
}

fn replace_transport(next: Option<TransportMode>) {
    let mut route = TRANSPORT.lock().unwrap();
    if *route != next {
        stop_host();
        TICKETS.lock().unwrap().clear();
        RECONNECT.lock().unwrap().clear();
        *route = next;
        crate::rendezvous_mediator::RendezvousMediator::restart();
    }
}

pub(crate) fn transport() -> Option<Transport> {
    match TRANSPORT.lock().unwrap().as_ref() {
        Some(TransportMode::Raw(route)) => Some(route.clone()),
        _ => None,
    }
}

pub(crate) fn managed_transport() -> bool {
    matches!(TRANSPORT.lock().unwrap().as_ref(), Some(TransportMode::Managed))
}

pub(crate) fn hosting() -> bool {
    cfg!(target_os = "windows") && HOST.lock().unwrap().is_some()
}

fn stop_host() {
    *HOST.lock().unwrap() = None;
    HOST_CHANGED.notify_waiters();
}

fn api_base(raw: &str) -> ResultType<String> {
    let u = Url::parse(raw).context("Invalid control service URL")?;
    let local = option_env!("RYMU_LOCAL_BUILD") == Some("1")
        && u.scheme() == "http"
        && u.host_str() == Some("127.0.0.1");
    if (!local && u.scheme() != "https")
        || !u.has_host()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || u.path().trim_end_matches('/') != "/api/v1"
    {
        bail!("Invalid control service URL");
    }
    Ok(raw.trim_end_matches('/').to_owned())
}

fn secret<const N: usize>(encoded: &str) -> ResultType<[u8; N]> {
    let decoded = URL_SAFE_NO_PAD
        .decode(encoded)
        .context("Invalid key or challenge")?;
    if URL_SAFE_NO_PAD.encode(&decoded) != encoded {
        bail!("Invalid key or challenge");
    }
    decoded
        .try_into()
        .map_err(|_| hbb_common::anyhow::anyhow!("Invalid key or challenge"))
}

fn device_keys(encoded_seed: &str) -> ResultType<(sign::PublicKey, sign::SecretKey)> {
    hbb_common::sodiumoxide::init()
        .map_err(|_| hbb_common::anyhow::anyhow!("Crypto unavailable"))?;
    Ok(sign::keypair_from_seed(&sign::Seed(secret(encoded_seed)?)))
}

fn uuid_valid(id: &str) -> bool {
    uuid::Uuid::parse_str(id).map_or(false, |x| x.to_string() == id)
}

fn token_valid(token: &str) -> bool {
    secret::<32>(token).is_ok()
}

#[derive(Clone)]
struct Host {
    id: String,
    api: String,
    access_token: String,
    epoch: uuid::Uuid,
}

struct ManagedListener(uuid::Uuid);

impl ManagedListener {
    fn new(epoch: uuid::Uuid) -> Self {
        *MANAGED_LISTENER.lock().unwrap() = Some(epoch);
        Self(epoch)
    }
}

impl Drop for ManagedListener {
    fn drop(&mut self) {
        let mut current = MANAGED_LISTENER.lock().unwrap();
        if *current == Some(self.0) {
            *current = None;
        }
    }
}

pub(crate) async fn listen_managed(server: crate::server::ServerPtr) {
    let Some(epoch) = HOST.lock().unwrap().as_ref().map(|host| host.epoch) else {
        return;
    };
    loop {
        let changed = HOST_CHANGED.notified();
        let Some(host) = active_host(epoch) else { return };
        let opened = hbb_common::tokio::select! {
            _ = changed => return,
            opened = relay::open(&host.api, &host.access_token, None) => opened,
        };
        if let Ok(mut socket) = opened {
            let changed = HOST_CHANGED.notified();
            if active_host(epoch).is_none() { return; }
            let listener = ManagedListener::new(epoch);
            let paired = hbb_common::tokio::select! {
                _ = changed => return,
                paired = timeout(relay::IDLE_RENEWAL, relay::wait_for_pair(&mut socket)) => paired,
            };
            drop(listener);
            match paired {
                Ok(Ok(())) if active_host(epoch).is_some() => {
                    let server = server.clone();
                    hbb_common::tokio::spawn(async move {
                        if active_host(epoch).is_some() {
                            let result = crate::server::create_tcp_connection(
                                server, relay::stream(socket), relay::PEER_ADDR,
                                true, crate::server::ConnectionMeta {
                                    rymu_host_epoch: Some(epoch),
                                    ..Default::default()
                                },
                            ).await;
                            if result.is_err() {
                                hbb_common::log::debug!("Rymu relay peer session closed during setup");
                            }
                        }
                    });
                    continue;
                }
                Err(_) => continue,
                _ => {},
            }
        }
        let changed = HOST_CHANGED.notified();
        if active_host(epoch).is_none() { return; }
        hbb_common::tokio::select! {
            _ = changed => return,
            _ = sleep(Duration::from_secs(3)) => {},
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Ticket {
    peer_id: String,
    host_id: String,
    peer_public_key: String,
    access_token: String,
    signing_seed: String,
    api_base: String,
    controller_id: Option<String>,
    view_only: bool,
    files: bool,
    #[serde(skip)]
    pub(crate) managed: bool,
}

struct Reconnect {
    until: Instant,
    retries: u8,
    ticket: Ticket,
}

pub(crate) fn remember_connection(ticket: &Ticket) {
    if ticket.files || ticket.controller_id.is_none() {
        return;
    }
    let mut store = RECONNECT.lock().unwrap();
    store.retain(|_, entry| entry.until > Instant::now());
    if store.len() < 16 {
        store
            .entry(ticket.peer_id.clone())
            .or_insert_with(|| Reconnect {
                until: Instant::now() + Duration::from_secs(480),
                retries: 0,
                ticket: ticket.clone(),
            });
    }
}

fn retry_ticket(peer: &str) -> bool {
    let ticket = {
        let mut store = RECONNECT.lock().unwrap();
        let Some(entry) = store.get_mut(peer) else {
            return false;
        };
        if entry.retries >= 3 || entry.until <= Instant::now() {
            return false;
        }
        entry.retries += 1;
        entry.ticket.clone()
    };
    if ticket.managed != managed_transport() {
        return false;
    }
    TICKETS.lock().unwrap().insert(
        (peer.to_owned(), false),
        (Instant::now() + Duration::from_secs(10), ticket),
    );
    true
}

fn forget_connection(peer: &str) {
    RECONNECT.lock().unwrap().remove(peer);
    TICKETS.lock().unwrap().remove(&(peer.to_owned(), false));
}

fn peer_valid(id: &str) -> bool {
    // The Rymu host registers the engine-generated ID; no ID@server/hostname/port syntax.
    (6..=18).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_digit())
}

pub(crate) fn take_ticket(peer: &str, files: bool) -> Option<Ticket> {
    let mut tickets = TICKETS.lock().unwrap();
    tickets.retain(|_, (until, _)| *until > Instant::now());
    tickets
        .remove(&(peer.to_owned(), files))
        .map(|(_, ticket)| ticket)
}

#[derive(Deserialize, Serialize, Clone, Copy)]
pub(crate) struct Scope {
    pub input: bool,
    pub clipboard: bool,
    pub files: bool,
    #[serde(default, rename = "multiDisplay")]
    pub multi_display: bool,
    #[serde(default)]
    pub audio: bool,
}

impl Scope {
    pub(crate) fn allows_screen_privacy(self) -> bool {
        self.input && !self.files
    }

    pub(crate) fn host_display_index(self, viewer_index: i32, primary: usize) -> Option<usize> {
        if self.multi_display {
            usize::try_from(viewer_index).ok()
        } else {
            (viewer_index == 0).then_some(primary)
        }
    }
}

pub(crate) fn show_primary_display(info: &mut PeerInfo, primary: usize) {
    info.displays = std::mem::take(&mut info.displays)
        .into_iter()
        .nth(primary)
        .into_iter()
        .collect();
    info.current_display = 0;
}

pub(crate) fn show_primary_video(message: &mut Arc<Message>, primary: usize) -> bool {
    // The rest of the protocol sees the one advertised display at index zero.
    let display = match message.union.as_ref() {
        Some(message::Union::VideoFrame(frame)) => frame.display,
        Some(message::Union::Misc(misc)) => match misc.union.as_ref() {
            Some(misc::Union::SwitchDisplay(change)) => change.display,
            _ => return false,
        },
        _ => return false,
    };
    if usize::try_from(display).ok() != Some(primary) {
        return false;
    }
    if display != 0 {
        match Arc::make_mut(message).union.as_mut() {
            Some(message::Union::VideoFrame(frame)) => frame.display = 0,
            Some(message::Union::Misc(misc)) => misc.mut_switch_display().display = 0,
            _ => unreachable!(),
        }
    }
    true
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Proof {
    grant: String,
    controller_proof: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GrantedHost {
    id: String,
    peer_id: String,
    peer_public_key: String,
}

#[derive(Deserialize)]
struct Grant {
    id: String,
    grant: String,
    host: GrantedHost,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Redeemed {
    id: String,
    host_id: String,
    controller_id: String,
    permissions: Scope,
    lease_duration_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Renewed {
    id: String,
    lease_duration_ms: u64,
}

enum ApiError {
    Denied,
    Unavailable,
}

async fn post<T: serde::de::DeserializeOwned>(
    base: &str,
    bearer: &str,
    path: &str,
    data: Value,
) -> Result<T, ApiError> {
    let client = HTTP.as_ref().map_err(|_| ApiError::Unavailable)?;
    let mut response = client
        .post(format!("{base}{path}"))
        .bearer_auth(bearer)
        .json(&data)
        .send()
        .await
        .map_err(|_| ApiError::Unavailable)?;
    if response.status().is_client_error() {
        return Err(ApiError::Denied);
    }
    if !response.status().is_success()
        || response.content_length().unwrap_or(0) > MAX_CONTROL_MESSAGE as u64
    {
        return Err(ApiError::Unavailable);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| ApiError::Unavailable)? {
        if bytes.len() + chunk.len() > MAX_CONTROL_MESSAGE {
            return Err(ApiError::Unavailable);
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| ApiError::Unavailable)
}

async fn read_control(stream: &mut Stream) -> ResultType<Message> {
    let packet = timeout(API_TIMEOUT, stream.next())
        .await?
        .context("Missing Rymu authorization message")??;
    if packet.len() > MAX_CONTROL_MESSAGE {
        bail!("Invalid Rymu authorization message");
    }
    Ok(Message::parse_from_bytes(&packet)?)
}

fn signature_payload(host_id: &str, challenge: &str, grant: &str) -> String {
    format!("RYMU-SESSION-V1\n{host_id}\n{challenge}\n{grant}")
}

async fn request_grant(ticket: &Ticket) -> ResultType<Grant> {
    let grant: Grant = post(
        &ticket.api_base, &ticket.access_token, "/sessions", json!({
            "hostId": ticket.host_id,
            "computerAudio": !ticket.files,
            "permissions": { "input": !ticket.view_only && !ticket.files,
                             "clipboard": !ticket.view_only && !ticket.files, "files": ticket.files }
        }),
    ).await.map_err(|error| match error {
        ApiError::Denied if ticket.files => hbb_common::anyhow::anyhow!(
            "Rymu file transfer is unavailable. Check your plan and device trust."
        ),
        ApiError::Denied => hbb_common::anyhow::anyhow!("Rymu denied this connection. Check device trust."),
        ApiError::Unavailable => hbb_common::anyhow::anyhow!("The Rymu account service is unavailable."),
    })?;
    if !uuid_valid(&grant.id)
        || grant.host.id != ticket.host_id
        || grant.host.peer_id != ticket.peer_id
        || grant.host.peer_public_key != ticket.peer_public_key
        || !token_valid(&grant.grant)
    {
        bail!("The computer's registered identity changed.");
    }
    Ok(grant)
}

async fn authorize_controller(
    ticket: &Ticket,
    public_key: Option<&[u8]>,
    stream: &mut Stream,
    grant: Option<Grant>,
) -> ResultType<()> {
    let expected = secret::<32>(&ticket.peer_public_key)?;
    if !stream.is_secured() || public_key != Some(expected.as_slice()) {
        bail!("Rymu could not verify the computer's identity.");
    }
    let challenge = match read_control(stream).await?.union {
        Some(message::Union::Hash(hash)) if hash.salt == MARKER => hash.challenge,
        _ => bail!("The computer does not support Rymu authorization."),
    };
    secret::<32>(&challenge)?;
    let grant = match grant {
        Some(grant) => grant,
        None => request_grant(ticket).await?,
    };
    if ticket.managed && !managed_transport() {
        bail!("Rymu connection settings changed. Try again from Devices.");
    }
    let (_, key) = device_keys(&ticket.signing_seed)?;
    let signature = sign::sign_detached(
        signature_payload(&ticket.host_id, &challenge, &grant.grant).as_bytes(),
        &key,
    );
    let proof = Proof {
        grant: grant.grant,
        controller_proof: URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    };
    let mut request = Message::new();
    request.set_login_request(LoginRequest {
        username: ticket.peer_id.clone(),
        password: serde_json::to_vec(&proof)?.into(),
        ..Default::default()
    });
    timeout(API_TIMEOUT, stream.send(&request)).await??;
    if !ticket.view_only && !ticket.files {
        *VIEWER_CLIPBOARD.lock().unwrap() = Some(ticket.peer_id.clone());
    }
    Ok(())
}

pub(crate) async fn controller_authorize(
    ticket: &Ticket,
    public_key: Option<&[u8]>,
    stream: &mut Stream,
) -> ResultType<()> {
    authorize_controller(ticket, public_key, stream, None).await
}

pub(crate) async fn start_managed_controller(ticket: &Ticket) -> ResultType<(Stream, Vec<u8>)> {
    if !managed_transport() {
        bail!("Rymu connection settings changed. Try again from Devices.");
    }
    let grant = request_grant(ticket).await?;
    let expected = secret::<32>(&ticket.peer_public_key)?;
    let socket = relay::open(&ticket.api_base, &ticket.access_token, Some(&grant.id)).await?;
    let mut stream = relay::stream(socket);
    crate::client::Client::secure_pinned_connection(
        &ticket.peer_id, sign::PublicKey(expected), &mut stream,
    ).await?;
    authorize_controller(ticket, Some(expected.as_slice()), &mut stream, Some(grant)).await?;
    Ok((stream, expected.to_vec()))
}

pub(crate) struct HostLease {
    id: String,
    pub controller_id: String,
    pub permissions: Scope,
    epoch: uuid::Uuid,
    expires: Instant,
}

pub(crate) async fn host_authorize(
    stream: &mut Stream,
    expected_epoch: Option<uuid::Uuid>,
) -> ResultType<HostLease> {
    if !stream.is_secured() || !cfg!(target_os = "windows") {
        bail!("Rymu requires a secured Windows host connection");
    }
    let host = HOST
        .lock()
        .unwrap()
        .as_ref()
        .filter(|host| expected_epoch.map_or(true, |epoch| epoch == host.epoch))
        .cloned()
        .context("Rymu hosting is disabled")?;
    let challenge = URL_SAFE_NO_PAD.encode(randombytes(32));
    let mut response = Message::new();
    response.set_hash(Hash {
        salt: MARKER.to_owned(),
        challenge: challenge.clone(),
        ..Default::default()
    });
    timeout(API_TIMEOUT, stream.send(&response)).await??;
    let proof = match read_control(stream).await?.union {
        Some(message::Union::LoginRequest(lr))
            if lr.username == Config::get_id()
                && lr.password.len() <= 256
                && lr.union.is_none() =>
        {
            serde_json::from_slice::<Proof>(&lr.password)?
        }
        _ => bail!("Missing Rymu session grant"),
    };
    secret::<32>(&proof.grant)?;
    secret::<64>(&proof.controller_proof)?;
    let started = Instant::now();
    let redeemed: Redeemed = post(&host.api, &host.access_token, "/sessions/redeem", json!({
        "grant": proof.grant, "controllerProof": proof.controller_proof, "transportChallenge": challenge,
        "displayPolicyVersion": DISPLAY_POLICY_VERSION,
        "audioPolicyVersion": 1,
    })).await.map_err(|_| hbb_common::anyhow::anyhow!("Rymu authorization denied"))?;
    if redeemed.host_id != host.id
        || !uuid_valid(&redeemed.id)
        || !uuid_valid(&redeemed.controller_id)
        || redeemed.lease_duration_ms == 0
        || active_host(host.epoch).is_none()
    {
        bail!("Invalid Rymu lease");
    }
    Ok(HostLease {
        id: redeemed.id,
        controller_id: redeemed.controller_id,
        permissions: redeemed.permissions,
        epoch: host.epoch,
        expires: started + LEASE.min(Duration::from_millis(redeemed.lease_duration_ms)),
    })
}

fn active_host(epoch: uuid::Uuid) -> Option<Host> {
    HOST.lock()
        .unwrap()
        .as_ref()
        .filter(|h| h.epoch == epoch)
        .cloned()
}

impl HostLease {
    pub(crate) fn valid_at_start(&self) -> bool {
        Instant::now() < self.expires && active_host(self.epoch).is_some()
    }

    pub(crate) async fn wait_for_stop(&self) {
        let mut until = self.expires;
        let mut next = Instant::now() + RENEW;
        loop {
            let changed = HOST_CHANGED.notified();
            if active_host(self.epoch).is_none() || Instant::now() >= until {
                return;
            }
            hbb_common::tokio::select! {
                _ = changed => continue,
                _ = sleep_until(until) => return,
                _ = sleep_until(next) => {}
            }
            let changed = HOST_CHANGED.notified();
            let Some(host) = active_host(self.epoch) else {
                return;
            };
            let start = Instant::now();
            let path = format!("/sessions/{}/lease", self.id);
            let result: Result<Renewed, ApiError> = hbb_common::tokio::select! {
                _ = changed => continue,
                _ = sleep_until(until) => return,
                result = post(&host.api, &host.access_token, &path, json!({
                    "displayPolicyVersion": DISPLAY_POLICY_VERSION,
                })) => result,
            };
            match result {
                Ok(r) if r.id == self.id && r.lease_duration_ms > 0 => {
                    until = start + LEASE.min(Duration::from_millis(r.lease_duration_ms));
                    next = start + RENEW;
                }
                Err(ApiError::Unavailable) => next = Instant::now() + Duration::from_secs(3),
                _ => return,
            }
        }
    }
}

fn value<'a>(input: &'a Value, key: &str) -> ResultType<&'a str> {
    input
        .get(key)
        .and_then(Value::as_str)
        .context("Missing native request parameter")
}

#[cfg(target_os = "windows")]
pub(crate) fn windows_displays() -> Vec<Value> {
    use sha2::{Digest, Sha256};
    use std::mem::{size_of, zeroed};
    use winapi::{
        shared::windef::POINT,
        um::{
            shellscalingapi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI},
            wingdi::{DEVMODEW, DISPLAY_DEVICEW, DISPLAY_DEVICE_ACTIVE},
            winuser::{
                EnumDisplayDevicesW, EnumDisplaySettingsW, GetMonitorInfoW, MonitorFromPoint,
                EDD_GET_DEVICE_INTERFACE_NAME, ENUM_CURRENT_SETTINGS, MONITORINFO,
                MONITORINFOF_PRIMARY, MONITOR_DEFAULTTONULL,
            },
        },
    };
    fn wide(input: &[u16]) -> String {
        String::from_utf16_lossy(
            &input[..input.iter().position(|x| *x == 0).unwrap_or(input.len())],
        )
    }
    let Ok(displays) = scrap::Display::all() else {
        return Vec::new();
    };
    displays
        .iter()
        .enumerate()
        .map(|(i, display)| {
            let name = display.name();
            let gdi: Vec<u16> = name.encode_utf16().chain([0]).collect();
            let (x, y) = display.origin();
            let (w, h) = (display.width(), display.height());
            let mut identifiers = Vec::new();
            let mut dpi = None;
            let mut primary = false;
            let mut rotation = None;
            unsafe {
                for index in 0..32 {
                    let mut monitor: DISPLAY_DEVICEW = zeroed();
                    monitor.cb = size_of::<DISPLAY_DEVICEW>() as _;
                    if EnumDisplayDevicesW(
                        gdi.as_ptr(),
                        index,
                        &mut monitor,
                        EDD_GET_DEVICE_INTERFACE_NAME,
                    ) == 0
                    {
                        break;
                    }
                    let path = wide(&monitor.DeviceID);
                    if !path.is_empty() && monitor.StateFlags & DISPLAY_DEVICE_ACTIVE != 0 {
                        identifiers.push(
                            URL_SAFE_NO_PAD.encode(Sha256::digest(path.to_lowercase().as_bytes())),
                        );
                    }
                }
                let m = MonitorFromPoint(
                    POINT {
                        x: x + (w as i32 / 2),
                        y: y + (h as i32 / 2),
                    },
                    MONITOR_DEFAULTTONULL,
                );
                if !m.is_null() {
                    let (mut dx, mut dy) = (0, 0);
                    if GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy) >= 0 && dx > 0 {
                        dpi = Some(dx);
                    }
                    let mut info: MONITORINFO = zeroed();
                    info.cbSize = size_of::<MONITORINFO>() as _;
                    if GetMonitorInfoW(m, &mut info) != 0 {
                        primary = info.dwFlags & MONITORINFOF_PRIMARY != 0;
                    }
                }
                let mut mode: DEVMODEW = zeroed();
                mode.dmSize = size_of::<DEVMODEW>() as _;
                if EnumDisplaySettingsW(gdi.as_ptr(), ENUM_CURRENT_SETTINGS, &mut mode) != 0 {
                    // DEVMODE's display union holds the orientation of the actual output.
                    let display_mode = mode.u1.s2();
                    let turns = display_mode.dmDisplayOrientation;
                    if turns <= 3 {
                        rotation = Some(turns * 90);
                    }
                }
            }
            let stable = if identifiers.len() == 1 {
                identifiers.pop()
            } else {
                None
            };
            json!({"index":i, "id":stable, "x":x, "y":y, "width":w, "height":h,
               "dpi":dpi, "rotation":rotation, "primary":primary})
        })
        .collect()
}

#[cfg(target_os = "windows")]
pub(crate) fn windows_locale() -> Option<&'static str> {
    use winapi::um::winnls::GetUserDefaultUILanguage;
    match unsafe { GetUserDefaultUILanguage() } & 0x3ff {
        1 => Some("ar"),
        9 => Some("en"),
        _ => None,
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn windows_keyboard_layout() -> Option<String> {
    use winapi::um::winuser::{GetForegroundWindow, GetKeyboardLayout, GetWindowThreadProcessId};
    let active = unsafe { GetForegroundWindow() };
    if active.is_null() {
        return None;
    }
    let thread = unsafe { GetWindowThreadProcessId(active, std::ptr::null_mut()) };
    if thread == 0 {
        return None;
    }
    let id = (unsafe { GetKeyboardLayout(thread) } as usize) & 0xffff;
    (id != 0).then(|| format!("{id:04X}"))
}

fn call(input: Value) -> ResultType<Value> {
    match value(&input, "op")? {
        "configureTransport" => configure_request(&input).map(|_| json!(true)),
        "clearTransport" => {
            replace_transport(None);
            Ok(json!(true))
        }
        "stageSession" => {
            let mut ticket: Ticket = serde_json::from_value(input.clone())?;
            if !peer_valid(&ticket.peer_id)
                || !uuid_valid(&ticket.host_id)
                || !token_valid(&ticket.access_token)
            {
                bail!("Invalid device authorization");
            }
            secret::<32>(&ticket.peer_public_key)?;
            secret::<32>(&ticket.signing_seed)?;
            ticket.api_base = api_base(&ticket.api_base)?;
            ticket.managed = configure_request(&input)?;
            if let Some(controller) = ticket.controller_id.as_ref().filter(|id| uuid_valid(id)) {
                let mut pairs = PAIRS.lock().unwrap();
                if pairs.len() >= 256 {
                    pairs.clear();
                }
                pairs.insert(
                    ticket.peer_id.clone(),
                    vec![
                        controller.clone(),
                        ticket.host_id.clone(),
                        ticket.peer_public_key.clone(),
                    ],
                );
            }
            let mut tickets = TICKETS.lock().unwrap();
            tickets.retain(|_, (until, _)| *until > Instant::now());
            if tickets.len() >= 16 {
                bail!("Too many pending connections");
            }
            tickets.insert(
                (ticket.peer_id.clone(), ticket.files),
                (Instant::now() + Duration::from_secs(30), ticket),
            );
            Ok(json!(true))
        }
        "identity" => Ok(json!({
            "peerId": Config::get_id(),
            "peerPublicKey": URL_SAFE_NO_PAD.encode(Config::get_key_pair().1),
        })),
        "transferRoot" => Ok(json!(files::transfer_path("", true)?.to_string_lossy())),
        "restageConnection" => Ok(json!(retry_ticket(value(&input, "peerId")?))),
        "forgetConnection" => {
            forget_connection(value(&input, "peerId")?);
            Ok(json!(true))
        }
        "hostOnline" => {
            let online = if managed_transport() {
                let active = HOST.lock().unwrap().as_ref().map(|host| host.epoch);
                active.is_some() && active == *MANAGED_LISTENER.lock().unwrap()
            } else {
                hosting() && hbb_common::config::get_online_state() > 0
            };
            Ok(json!(online))
        }
        "pairIdentity" => Ok(json!(PAIRS.lock().unwrap().get(value(&input, "peerId")?))),
        "displays" => {
            #[cfg(target_os = "windows")]
            return Ok(json!(windows_displays()));
            #[cfg(not(target_os = "windows"))]
            Ok(json!([]))
        }
        "devicePublicKey" => {
            let (key, _) = device_keys(value(&input, "signingSeed")?)?;
            Ok(json!(URL_SAFE_NO_PAD.encode(key.0)))
        }
        "signEnrollment" => {
            let (_, key) = device_keys(value(&input, "signingSeed")?)?;
            let proof = value(&input, "proof")?;
            if !proof.starts_with("RYMU-ENROLL-V1\n") || proof.len() > 1024 {
                bail!("Invalid enrollment proof");
            }
            Ok(json!(URL_SAFE_NO_PAD.encode(
                sign::sign_detached(proof.as_bytes(), &key).to_bytes()
            )))
        }
        "enableHost" | "updateHostBearer" => {
            if !cfg!(target_os = "windows") || TRANSPORT.lock().unwrap().is_none() {
                bail!("Windows hosting is unavailable");
            }
            let id = value(&input, "hostId")?.to_owned();
            let api = api_base(value(&input, "apiBase")?)?;
            let access_token = value(&input, "accessToken")?.to_owned();
            if !uuid_valid(&id) || !token_valid(&access_token) {
                bail!("Invalid host authorization");
            }
            let mut active = HOST.lock().unwrap();
            let same_host = active.as_ref().is_some_and(|h| h.id == id && h.api == api);
            if value(&input, "op")? == "updateHostBearer" && !same_host {
                bail!("Hosting is disabled");
            }
            let epoch = active
                .as_ref()
                .filter(|h| h.id == id && h.api == api)
                .map(|h| h.epoch)
                .unwrap_or_else(uuid::Uuid::new_v4);
            let restart = active.is_none();
            *active = Some(Host {
                id,
                api,
                access_token,
                epoch,
            });
            drop(active);
            if restart {
                crate::rendezvous_mediator::RendezvousMediator::restart();
            }
            Ok(json!(true))
        }
        "disableHost" => {
            stop_host();
            crate::rendezvous_mediator::RendezvousMediator::restart();
            Ok(json!(true))
        }
        "vaultRead" | "vaultWrite" | "vaultClear" => {
            #[cfg(target_os = "windows")]
            return vault::call(&input);
            #[cfg(not(target_os = "windows"))]
            bail!("Use the device's secure credential store");
        }
        _ => bail!("Unsupported native request"),
    }
}

/// FFI arguments point to caller-owned, non-overlapping buffers of the stated sizes.
/// The Flutter caller owns allocation and deallocation. No C string scanning or secret logging.
#[no_mangle]
pub unsafe extern "C" fn rymu_control(
    input: *const u8,
    len: usize,
    output: *mut u8,
    capacity: usize,
) -> isize {
    if input.is_null() || output.is_null() || len == 0 || len > MAX_CONTROL_MESSAGE {
        return -1;
    }
    let request = std::slice::from_raw_parts(input, len);
    let answer = serde_json::from_slice::<Value>(request)
        .map_err(Into::into)
        .and_then(call);
    let value = match answer {
        Ok(v) => json!({"value":v}),
        Err(e) => json!({"error":e.to_string()}),
    };
    let Ok(bytes) = serde_json::to_vec(&value) else {
        return -1;
    };
    if bytes.len() > capacity {
        return -1;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
    bytes.len() as isize
}

#[cfg(target_os = "windows")]
mod vault {
    use super::*;
    use std::{fs, io::Write, os::windows::ffi::OsStrExt, path::PathBuf, ptr::null_mut};
    use winapi::um::{
        dpapi::{CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN},
        winbase::{LocalFree, MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH},
        wincrypt::DATA_BLOB,
    };

    fn transform(bytes: &[u8], protect: bool) -> ResultType<Vec<u8>> {
        let mut data = DATA_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr() as *mut u8,
        };
        let mut output = DATA_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };
        let ok = unsafe {
            if protect {
                CryptProtectData(
                    &mut data,
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            } else {
                CryptUnprotectData(
                    &mut data,
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            }
        };
        if ok == 0 || output.pbData.is_null() {
            bail!("Windows could not access Rymu credentials");
        }
        let result = unsafe {
            let out = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
            std::ptr::write_bytes(output.pbData, 0, output.cbData as usize);
            LocalFree(output.pbData as _);
            out
        };
        Ok(result)
    }

    fn path() -> ResultType<PathBuf> {
        Ok(
            PathBuf::from(std::env::var_os("LOCALAPPDATA").context("No Windows user profile")?)
                .join("Rymu")
                .join("Control")
                .join("account.dat"),
        )
    }

    pub(super) fn call(input: &Value) -> ResultType<Value> {
        let file = path()?;
        match value(input, "op")? {
            "vaultRead" => {
                let data = match fs::read(&file) {
                    Ok(bytes) if bytes.len() <= MAX_CONTROL_MESSAGE => bytes,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Value::Null),
                    _ => bail!("Could not read Rymu credentials"),
                };
                Ok(serde_json::from_slice(&transform(&data, false)?)?)
            }
            "vaultWrite" => {
                let data = serde_json::to_vec(input.get("data").context("Missing credentials")?)?;
                if data.len() > 12_288 {
                    bail!("Invalid credential data");
                }
                let encrypted = transform(&data, true)?;
                fs::create_dir_all(file.parent().context("Missing vault directory")?)?;
                let temporary = file.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
                let publish = || -> ResultType<()> {
                    let mut f = fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&temporary)?;
                    f.write_all(&encrypted)?;
                    f.sync_all()?;
                    drop(f);
                    let from: Vec<u16> = temporary.as_os_str().encode_wide().chain([0]).collect();
                    let to: Vec<u16> = file.as_os_str().encode_wide().chain([0]).collect();
                    if unsafe {
                        MoveFileExW(
                            from.as_ptr(),
                            to.as_ptr(),
                            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                        )
                    } == 0
                    {
                        bail!("Could not save Rymu credentials");
                    }
                    Ok(())
                };
                let result = publish();
                if result.is_err() {
                    let _ = fs::remove_file(&temporary);
                }
                result.map(|_| json!(true))
            }
            "vaultClear" => {
                stop_host();
                TICKETS.lock().unwrap().clear();
                RECONNECT.lock().unwrap().clear();
                PAIRS.lock().unwrap().clear();
                *VIEWER_CLIPBOARD.lock().unwrap() = None;
                match fs::remove_file(&file) {
                    Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                        bail!("Could not clear Rymu credentials")
                    }
                    _ => Ok(json!(true)),
                }
            }
            _ => bail!("Unsupported credential operation"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{DisplayInfo, Misc, SwitchDisplay, VideoFrame};

    #[test]
    fn clipboard_accepts_utf8_text_and_rejects_invalid_or_oversized_content() {
        let mut clip = Clipboard {
            format: ClipboardFormat::Text.into(),
            content: "Rymu مرحبا".as_bytes().to_vec().into(),
            ..Default::default()
        };
        let mut message = Message::new();
        message.set_clipboard(clip.clone());
        assert!(filter_clipboard(&mut message));
        clip.content = vec![0xff].into();
        message.set_clipboard(clip.clone());
        assert!(!filter_clipboard(&mut message));
        clip.content = vec![b'a'; 1024 * 1024 + 1].into();
        message.set_clipboard(clip);
        assert!(!filter_clipboard(&mut message));
    }

    #[test]
    fn compressed_content_cannot_expand_beyond_its_limit() {
        let bounded = zstd::encode_all(&b"text"[..], 1).unwrap();
        assert_eq!(decompress_bounded(&bounded, 64), Some(b"text".to_vec()));
        let expanded = zstd::encode_all(&vec![b'a'; 4096][..], 1).unwrap();
        assert!(expanded.len() < 64);
        assert!(decompress_bounded(&expanded, 64).is_none());
    }

    #[test]
    fn transfer_names_reject_windows_path_and_device_aliases() {
        for name in ["report.pdf", "تقرير.txt", "photo 1.png"] {
            assert!(files::safe_file_name(name), "{name}");
        }
        for name in ["", ".", "..", "../escape", "a\\b", "x:stream", "NUL.txt",
            "COM1", "LPT².txt", "CONOUT$", "trailing.", "trailing ", "bad\0name"] {
            assert!(!files::safe_file_name(name), "{name}");
        }
    }

    #[test]
    fn display_scope_defaults_to_one_and_only_pro_resolves_other_display_indices() {
        let old = json!({"input":true,"clipboard":true,"files":false});
        let free: Scope = serde_json::from_value(old).unwrap();
        assert!(!free.multi_display);
        assert_eq!(free.host_display_index(0, 2), Some(2));
        assert_eq!(free.host_display_index(1, 2), None);
        assert_eq!(free.host_display_index(-1, 2), None);

        let pro: Scope = serde_json::from_value(
            json!({"input":true,"clipboard":true,"files":false,"multiDisplay":true}),
        )
        .unwrap();
        assert_eq!(pro.host_display_index(0, 2), Some(0));
        assert_eq!(pro.host_display_index(1, 2), Some(1));
        assert_eq!(pro.host_display_index(-1, 2), None);
    }

    #[test]
    fn screen_privacy_requires_a_control_grant_and_excludes_file_sessions() {
        for (input, files, allowed) in [
            (true, false, true),
            (false, false, false),
            (false, true, false),
            (true, true, false),
        ] {
            let scope: Scope = serde_json::from_value(
                json!({"input":input,"clipboard":false,"files":files}),
            ).unwrap();
            assert_eq!(scope.allows_screen_privacy(), allowed);
        }
    }

    #[test]
    fn computer_audio_defaults_off_and_revocation_requires_a_new_opt_in() {
        let old: Scope = serde_json::from_value(
            json!({"input":true,"clipboard":false,"files":false}),
        )
        .unwrap();
        assert!(!old.audio);

        let mut viewer = crate::client::LoginConfigHandler::default();
        assert!(viewer.get_toggle_option("disable-audio"));
        assert!(viewer.toggle_option("disable-audio".into()).is_none());
        viewer.set_computer_audio_permission(true);
        assert!(viewer.get_toggle_option("disable-audio"));
        assert!(viewer.toggle_option("disable-audio".into()).is_some());
        assert!(!viewer.get_toggle_option("disable-audio"));
        viewer.set_computer_audio_permission(false);
        viewer.set_computer_audio_permission(true);
        assert!(viewer.get_toggle_option("disable-audio"));
    }

    #[test]
    fn primary_media_drops_other_displays_and_preserves_origin_for_index_zero() {
        let mut peer = PeerInfo {
            displays: vec![
                DisplayInfo::new(),
                DisplayInfo { x: -1920, width: 1920, ..Default::default() },
            ],
            current_display: 1,
            ..Default::default()
        };
        show_primary_display(&mut peer, 1);
        assert_eq!(peer.displays.len(), 1);
        assert_eq!(peer.displays[0].x, -1920);
        assert_eq!(peer.current_display, 0);

        let mut frame = Message::new();
        frame.set_video_frame(VideoFrame { display: 1, ..Default::default() });
        let original = Arc::new(frame);
        let mut session = original.clone();
        assert!(!show_primary_video(&mut session, 0));
        assert!(show_primary_video(&mut session, 1));
        assert_eq!(session.video_frame().display, 0);
        assert_eq!(original.video_frame().display, 1);

        let mut change = Misc::new();
        change.set_switch_display(SwitchDisplay { display: 1, x: -1920, ..Default::default() });
        let mut message = Message::new();
        message.set_misc(change);
        let mut message = Arc::new(message);
        assert!(show_primary_video(&mut message, 1));
        assert_eq!(message.misc().switch_display().display, 0);
        assert_eq!(message.misc().switch_display().x, -1920);
    }

    #[test]
    fn validates_routes_and_rejects_credential_redirect_shapes() {
        assert!(endpoint("127.0.0.1:21116"));
        assert!(!endpoint("rs.rustdesk.com"));
        assert!(!endpoint("rymu.invalid:21116@other.invalid"));
        assert!(api_base("https://control.invalid/api/v1").is_ok());
        assert!(api_base("https://control.invalid/api/v1?token=1").is_err());
        assert!(api_base("https://user@control.invalid/api/v1").is_err());
        assert!(api_base("http://192.0.2.1/api/v1").is_err());
    }

    #[test]
    fn proof_binds_host_challenge_and_grant() {
        let seed = URL_SAFE_NO_PAD.encode([5u8; 32]);
        let (public, key) = device_keys(&seed).unwrap();
        let proof = signature_payload("a", "b", "c");
        let signature = sign::sign_detached(proof.as_bytes(), &key);
        assert!(sign::verify_detached(&signature, proof.as_bytes(), &public));
        for alternate in [
            signature_payload("x", "b", "c"),
            signature_payload("a", "x", "c"),
            signature_payload("a", "b", "x"),
        ] {
            assert!(!sign::verify_detached(
                &signature,
                alternate.as_bytes(),
                &public
            ));
        }
    }
}
