use hbb_common::{
    anyhow::{bail, Context},
    bytes::Bytes,
    futures::{SinkExt, StreamExt},
    tcp::FramedStream,
    tokio::{
        self,
        io::{self, AsyncReadExt, AsyncWriteExt},
        net::TcpStream,
        time::{interval_at, timeout, Duration, Instant},
    },
    ResultType, Stream,
};
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
};
use tokio_tungstenite::{
    connect_async_tls_with_config,
    tungstenite::{
        client::IntoClientRequest,
        http::{header::AUTHORIZATION, HeaderValue},
        protocol::{Message, WebSocketConfig},
    },
    Connector, MaybeTlsStream, WebSocketStream,
};
use url::Url;

const CHUNK: usize = 64 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const KEEPALIVE: Duration = Duration::from_secs(25);
pub(super) const IDLE_RENEWAL: Duration = Duration::from_secs(360);
const READY: &str = "RYMU-READY-1";
pub(super) const PEER_ADDR: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0);

pub(super) type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

fn relay_url(base: &str, session: Option<&str>) -> ResultType<Url> {
    let base = super::api_base(base)?;
    let mut url = Url::parse(&base)?;
    let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    url.set_scheme(scheme)
        .map_err(|_| hbb_common::anyhow::anyhow!("Invalid relay URL"))?;
    let path = match session {
        Some(id) if super::uuid_valid(id) => format!("/api/v1/relay/connect/{id}"),
        Some(_) => bail!("Invalid Rymu session identifier"),
        None => "/api/v1/relay/host".to_owned(),
    };
    url.set_path(&path);
    Ok(url)
}

pub(super) async fn open(base: &str, bearer: &str, session: Option<&str>) -> ResultType<Socket> {
    let url = relay_url(base, session)?;
    let mut request = url.as_str().into_client_request()?;
    let mut authorization = HeaderValue::from_str(&format!("Bearer {bearer}"))?;
    authorization.set_sensitive(true);
    request.headers_mut().insert(AUTHORIZATION, authorization);
    let connector = if url.scheme() == "wss" {
        Some(Connector::Rustls(Arc::new(
            hbb_common::verifier::client_config(false)?,
        )))
    } else {
        None
    };
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(CHUNK);
    config.max_frame_size = Some(CHUNK);
    let (socket, _) = timeout(
        CONNECT_TIMEOUT,
        connect_async_tls_with_config(request, Some(config), true, connector),
    )
    .await
    .context("Rymu relay did not respond")?
    .map_err(|_| hbb_common::anyhow::anyhow!("Rymu relay could not open a connection"))?;
    Ok(socket)
}

pub(super) async fn wait_for_pair(socket: &mut Socket) -> ResultType<()> {
    let mut heartbeat = interval_at(Instant::now() + KEEPALIVE, KEEPALIVE);
    let mut waiting_for_pong = false;
    loop {
        tokio::select! {
            frame = socket.next() => match frame {
                Some(Ok(Message::Text(text))) if text.as_str() == READY => return Ok(()),
                Some(Ok(Message::Pong(_))) => waiting_for_pong = false,
                Some(Ok(Message::Ping(_))) => {},
                _ => bail!("Rymu relay listener closed"),
            },
            _ = heartbeat.tick() => {
                if waiting_for_pong {
                    bail!("Rymu relay listener timed out");
                }
                timeout(CONNECT_TIMEOUT, socket.send(Message::Ping(Bytes::new()))).await??;
                waiting_for_pong = true;
            }
        }
    }
}

pub(super) fn stream(socket: Socket) -> Stream {
    let (app, relay) = io::duplex(CHUNK * 2);
    let (mut relay_read, mut relay_write) = io::split(relay);
    let (mut ws_write, mut ws_read) = socket.split();
    tokio::spawn(async move {
        let receive = async {
            while let Some(frame) = ws_read.next().await {
                match frame? {
                    Message::Binary(data) if !data.is_empty() => {
                        relay_write.write_all(&data).await?
                    }
                    Message::Ping(_) | Message::Pong(_) => {}
                    Message::Close(_) => break,
                    _ => bail!("Invalid Rymu relay frame"),
                }
            }
            ResultType::<()>::Ok(())
        };
        let send = async {
            let mut chunk = vec![0; CHUNK];
            loop {
                let count = relay_read.read(&mut chunk).await?;
                if count == 0 {
                    break;
                }
                ws_write
                    .send(Message::Binary(Bytes::copy_from_slice(&chunk[..count])))
                    .await?;
            }
            ResultType::<()>::Ok(())
        };
        tokio::select! {
            _ = receive => {},
            _ = send => {},
        }
    });
    Stream::Tcp(FramedStream::from(app, PEER_ADDR))
}

#[cfg(test)]
mod tests {
    use super::{relay_url, stream, Bytes, Duration, Message, SinkExt, StreamExt, CHUNK};
    use hbb_common::tokio::{self, time::timeout};

    #[test]
    fn relay_urls_are_exactly_scoped_to_the_account_origin() {
        let api = "https://accounts.example:8443/api/v1";
        let session = "123e4567-e89b-12d3-a456-426614174000";
        assert_eq!(
            relay_url(api, None).unwrap().as_str(),
            "wss://accounts.example:8443/api/v1/relay/host"
        );
        assert_eq!(
            relay_url(api, Some(session)).unwrap().path(),
            format!("/api/v1/relay/connect/{session}")
        );
        assert!(relay_url(api, Some("../../not-a-session")).is_err());
        assert!(relay_url("https://user@accounts.example/api/v1", None).is_err());
        assert!(relay_url("http://accounts.example/api/v1", None).is_err());
        assert!(relay_url("https://accounts.example/api/v1?key=unexpected", None).is_err());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn opaque_chunks_round_trip_as_a_single_native_frame() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let size = CHUNK * 2 + 11;
        let echo = tokio::spawn(async move {
            let mut socket = tokio_tungstenite::accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            let mut bytes = 0;
            while bytes <= size {
                let frame = socket.next().await.unwrap().unwrap();
                let Message::Binary(chunk) = frame else {
                    panic!("nonbinary peer data");
                };
                assert!(chunk.len() <= CHUNK);
                bytes += chunk.len();
                socket.send(Message::Binary(chunk)).await.unwrap();
            }
        });
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://{address}"))
            .await
            .unwrap();
        let mut native = stream(socket);
        let payload = Bytes::from(vec![0x5a; size]);
        native.send_bytes(payload.clone()).await.unwrap();
        let returned = timeout(Duration::from_secs(5), native.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(returned.as_ref(), payload.as_ref());
        echo.await.unwrap();
    }
}
