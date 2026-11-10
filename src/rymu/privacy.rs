//! Session-owned physical screen covers. No display topology or system input changes.
use crate::privacy_mode::{PrivacyMode, PrivacyModeState, INVALID_PRIVACY_MODE_CONN_ID};
use hbb_common::{bail, log, ResultType};
use std::{
    cell::Cell,
    io::Error,
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};
use winapi::{
    shared::{minwindef::*, windef::*},
    um::{
        libloaderapi::GetModuleHandleW, processthreadsapi::GetCurrentThreadId, wingdi::*,
        winuser::*,
    },
};

pub(crate) const IMPL_KEY: &str = "rymu_privacy_overlay";
const CLASS: &str = "RymuScreenPrivacyOverlay";
const AFFINITY: DWORD = 0x11;
const STOP_HOTKEY: i32 = 0x5279;

#[link(name = "dwmapi")]
extern "system" {
    fn DwmIsCompositionEnabled(enabled: *mut BOOL) -> i32;
    fn DwmFlush() -> i32;
}

thread_local! {
    static RAISE_COVERS: Cell<bool> = const { Cell::new(false) };
}

pub(crate) fn supported() -> bool {
    base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
}

/// Keep covers in place until connection cleanup has revoked input and media.
pub(crate) fn request_close(conn_id: i32) -> bool {
    let connections = crate::server::AUTHED_CONNS.lock().unwrap();
    connections
        .iter()
        .find(|connection| connection.conn_id == conn_id)
        .map_or(false, |connection| {
            connection.sender.send(crate::ipc::Data::Close).is_ok()
        })
}

pub(crate) struct PrivacyModeImpl {
    impl_key: String,
    conn_id: i32,
    worker: Option<CoverThread>,
}

struct CoverThread {
    stop: mpsc::Sender<()>,
    join: JoinHandle<()>,
    alive: Arc<AtomicBool>,
}

impl PrivacyModeImpl {
    pub(crate) fn new(impl_key: &str) -> Self {
        Self {
            impl_key: impl_key.to_owned(),
            conn_id: 0,
            worker: None,
        }
    }
}

impl PrivacyMode for PrivacyModeImpl {
    fn is_async_privacy_mode(&self) -> bool {
        true
    }
    fn init(&self) -> ResultType<()> {
        Ok(())
    }
    fn clear(&mut self) {
        if let Err(error) = self.turn_off_privacy(INVALID_PRIVACY_MODE_CONN_ID, None) {
            log::warn!("Rymu screen privacy cleanup failed: {error}");
        }
    }
    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        if conn_id <= 0 || !supported() {
            bail!("Screen privacy is not supported on this desktop");
        }
        if self.check_on_conn_id(conn_id)? {
            if self
                .worker
                .as_ref()
                .map_or(false, |worker| worker.alive.load(Ordering::Acquire))
            {
                return Ok(true);
            }
            bail!("Screen privacy is stopping");
        }
        self.clear();
        let (stop, stopped) = mpsc::channel();
        let (ready, result) = mpsc::sync_channel(1);
        let alive = Arc::new(AtomicBool::new(false));
        let thread_alive = alive.clone();
        let join = thread::Builder::new()
            .name("rymu-screen-privacy".into())
            .spawn(move || {
                if let Err(error) = run_covers(conn_id, stopped, &ready, &thread_alive) {
                    let _ = ready.send(Err(error.to_string()));
                    log::warn!("Rymu screen privacy stopped: {error}");
                }
                thread_alive.store(false, Ordering::Release);
            })?;
        match result.recv_timeout(Duration::from_secs(4)) {
            Ok(Ok(())) => {
                self.conn_id = conn_id;
                self.worker = Some(CoverThread { stop, join, alive });
                Ok(true)
            }
            outcome => {
                // Closing the ready receiver also prevents a late setup from staying visible.
                let _ = stop.send(());
                match outcome {
                    Ok(Err(message)) => bail!(message),
                    _ => bail!("Screen privacy could not be confirmed"),
                }
            }
        }
    }
    fn turn_off_privacy(
        &mut self,
        conn_id: i32,
        _state: Option<PrivacyModeState>,
    ) -> ResultType<()> {
        self.check_off_conn_id(conn_id)?;
        if let Some(worker) = self.worker.take() {
            let _ = worker.stop.send(());
            if worker.join.join().is_err() {
                self.conn_id = 0;
                bail!("Screen privacy thread ended unexpectedly");
            }
        }
        self.conn_id = 0;
        Ok(())
    }
    fn pre_conn_id(&self) -> i32 {
        self.worker.as_ref().map_or(0, |_| self.conn_id)
    }
    fn get_impl_key(&self) -> &str {
        &self.impl_key
    }
}

impl Drop for PrivacyModeImpl {
    fn drop(&mut self) {
        self.clear();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Bounds {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

unsafe extern "system" fn monitor_rect(
    _monitor: HMONITOR,
    _dc: HDC,
    rect: *mut RECT,
    data: LPARAM,
) -> BOOL {
    let bounds = &mut *(data as *mut Vec<Bounds>);
    let rect = *rect;
    let item = Bounds {
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
    };
    if !bounds.contains(&item) {
        bounds.push(item);
    }
    TRUE
}

fn monitors() -> ResultType<Vec<Bounds>> {
    let mut bounds = Vec::new();
    if unsafe {
        EnumDisplayMonitors(
            ptr::null_mut(),
            ptr::null(),
            Some(monitor_rect),
            &mut bounds as *mut _ as LPARAM,
        )
    } == 0
    {
        bail!(
            "Cannot enumerate physical screens: {}",
            Error::last_os_error()
        );
    }
    if bounds.is_empty()
        || bounds
            .iter()
            .any(|b: &Bounds| b.right <= b.left || b.bottom <= b.top)
    {
        bail!("No usable physical screens");
    }
    bounds.sort_by_key(|b| (b.left, b.top, b.right, b.bottom));
    Ok(bounds)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

unsafe fn desktop_name(handle: HDESK) -> Option<Vec<u16>> {
    let mut name = vec![0u16; 256];
    let mut needed = 0;
    if handle.is_null()
        || GetUserObjectInformationW(
            handle as _,
            UOI_NAME as _,
            name.as_mut_ptr() as _,
            (name.len() * 2) as DWORD,
            &mut needed,
        ) == 0
    {
        return None;
    }
    name.truncate(name.iter().position(|ch| *ch == 0).unwrap_or(name.len()));
    Some(name)
}

fn active_desktop() -> bool {
    unsafe {
        let input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
        if input.is_null() {
            return false;
        }
        let input_name = desktop_name(input);
        CloseDesktop(input);
        let current_name = desktop_name(GetThreadDesktop(GetCurrentThreadId()));
        input_name.is_some() && input_name == current_name
    }
}

struct Window(HWND);
impl Drop for Window {
    fn drop(&mut self) {
        unsafe {
            if IsWindow(self.0) != 0 && DestroyWindow(self.0) == 0 {
                log::warn!(
                    "Cannot destroy Rymu privacy cover: {}",
                    Error::last_os_error()
                );
            }
        }
    }
}

struct WindowState {
    stopping: Cell<bool>,
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, message: UINT, w: WPARAM, l: LPARAM) -> LRESULT {
    if message == WM_NCCREATE {
        let create = &*(l as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
    }
    let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const WindowState;
    match message {
        WM_NCHITTEST => return HTTRANSPARENT as LRESULT,
        WM_MOUSEACTIVATE => return MA_NOACTIVATE as LRESULT,
        WM_CLOSE | WM_HOTKEY => {
            if !state.is_null() {
                (*state).stopping.set(true);
            }
            return 0;
        }
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = std::mem::zeroed();
            let dc = BeginPaint(hwnd, &mut paint);
            let mut rect: RECT = std::mem::zeroed();
            GetClientRect(hwnd, &mut rect);
            FillRect(dc, &rect, GetStockObject(BLACK_BRUSH as _) as _);
            SetBkMode(dc, TRANSPARENT as _);
            SetTextColor(dc, 0x00ffffff);
            let font = CreateFontW(
                -24,
                0,
                0,
                0,
                FW_NORMAL,
                0,
                0,
                0,
                DEFAULT_CHARSET as _,
                OUT_DEFAULT_PRECIS as _,
                CLIP_DEFAULT_PRECIS as _,
                ANTIALIASED_QUALITY as _,
                (DEFAULT_PITCH | FF_SWISS) as _,
                wide("Segoe UI").as_ptr(),
            );
            let old_font = SelectObject(dc, font as _);
            let center = (rect.bottom - rect.top) / 2;
            rect.top = center - 66;
            rect.bottom = center - 26;
            let title = wide("Rymu · خصوصية الشاشة");
            DrawTextW(
                dc,
                title.as_ptr(),
                -1,
                &mut rect,
                DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_RTLREADING,
            );
            rect.top = center - 14;
            rect.bottom = center + 26;
            let label = if !state.is_null() && (*state).stopping.get() {
                "جارٍ إيقاف الاتصال — Disconnecting"
            } else {
                "جلسة تحكم عن بُعد — Remote session active"
            };
            DrawTextW(
                dc,
                wide(label).as_ptr(),
                -1,
                &mut rect,
                DT_CENTER | DT_SINGLELINE | DT_VCENTER,
            );
            rect.top = center + 38;
            rect.bottom = center + 78;
            DrawTextW(
                dc,
                wide("Ctrl + Alt + Shift + F10  —  إيقاف / Stop").as_ptr(),
                -1,
                &mut rect,
                DT_CENTER | DT_SINGLELINE | DT_VCENTER,
            );
            SelectObject(dc, old_font);
            if !font.is_null() {
                DeleteObject(font as _);
            }
            EndPaint(hwnd, &paint);
            return 0;
        }
        _ => (),
    }
    DefWindowProcW(hwnd, message, w, l)
}

unsafe extern "system" fn window_event(
    _hook: HWINEVENTHOOK,
    _event: DWORD,
    hwnd: HWND,
    _object: i32,
    _child: i32,
    thread_id: DWORD,
    _time: DWORD,
) {
    if !hwnd.is_null() && thread_id != GetCurrentThreadId() {
        RAISE_COVERS.with(|raise| raise.set(true));
    }
}

struct EventHook(HWINEVENTHOOK);
impl Drop for EventHook {
    fn drop(&mut self) {
        unsafe {
            UnhookWinEvent(self.0);
        }
    }
}
struct Hotkey(HWND);
impl Drop for Hotkey {
    fn drop(&mut self) {
        unsafe {
            UnregisterHotKey(self.0, STOP_HOTKEY);
        }
    }
}

fn run_covers(
    conn_id: i32,
    stop: mpsc::Receiver<()>,
    ready: &mpsc::SyncSender<Result<(), String>>,
    alive: &AtomicBool,
) -> ResultType<()> {
    unsafe {
        let mut composing = 0;
        if DwmIsCompositionEnabled(&mut composing) < 0 || composing == 0 || !active_desktop() {
            bail!("Screen privacy needs the active unlocked Windows desktop");
        }
        if SetThreadDpiAwarenessContext(-4isize as _).is_null() {
            bail!("Cannot use physical screen coordinates");
        }
        let bounds = monitors()?;
        let class = wide(CLASS);
        let instance = GetModuleHandleW(ptr::null());
        let mut wc: WNDCLASSW = std::mem::zeroed();
        wc.lpfnWndProc = Some(wnd_proc);
        wc.hInstance = instance;
        wc.lpszClassName = class.as_ptr();
        wc.hbrBackground = GetStockObject(BLACK_BRUSH as _) as _;
        if RegisterClassW(&wc) == 0 && Error::last_os_error().raw_os_error() != Some(1410) {
            bail!(
                "Cannot register screen privacy window: {}",
                Error::last_os_error()
            );
        }
        let state = WindowState {
            stopping: Cell::new(false),
        };
        let mut windows = Vec::new();
        for b in &bounds {
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST
                    | WS_EX_TOOLWINDOW
                    | WS_EX_NOACTIVATE
                    | WS_EX_LAYERED
                    | WS_EX_TRANSPARENT,
                class.as_ptr(),
                wide("Rymu — خصوصية الشاشة").as_ptr(),
                WS_POPUP,
                b.left,
                b.top,
                b.right - b.left,
                b.bottom - b.top,
                ptr::null_mut(),
                ptr::null_mut(),
                instance,
                &state as *const _ as _,
            );
            if hwnd.is_null() {
                bail!(
                    "Cannot create screen privacy cover: {}",
                    Error::last_os_error()
                );
            }
            let window = Window(hwnd);
            if SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA) == 0
                || SetWindowDisplayAffinity(hwnd, AFFINITY) == 0
            {
                bail!(
                    "Cannot exclude screen privacy cover from capture: {}",
                    Error::last_os_error()
                );
            }
            windows.push(window);
        }
        if RegisterHotKey(
            windows[0].0,
            STOP_HOTKEY,
            (MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT) as _,
            VK_F10 as _,
        ) == 0
        {
            bail!("The local screen privacy Stop shortcut is unavailable");
        }
        let _hotkey = Hotkey(windows[0].0);
        let event_hook = SetWinEventHook(
            EVENT_OBJECT_SHOW,
            EVENT_OBJECT_REORDER,
            ptr::null_mut(),
            Some(window_event),
            0,
            0,
            WINEVENT_OUTOFCONTEXT,
        );
        if event_hook.is_null() {
            bail!("Cannot observe screen privacy window ordering");
        }
        let _event_hook = EventHook(event_hook);
        if !matches!(stop.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            return Ok(());
        }
        for window in &windows {
            if SetWindowPos(
                window.0,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
            ) == 0
            {
                bail!("Cannot show screen privacy cover");
            }
            UpdateWindow(window.0);
            let mut affinity = 0;
            if IsWindowVisible(window.0) == 0
                || GetWindowDisplayAffinity(window.0, &mut affinity) == 0
                || affinity != AFFINITY
            {
                bail!("Screen privacy cover was not confirmed");
            }
        }
        if DwmFlush() < 0 {
            bail!("Screen privacy compositor did not confirm coverage");
        }
        alive.store(true, Ordering::Release);
        if ready.send(Ok(())).is_err() {
            return Ok(());
        }
        let monitored = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut closing = false;
            loop {
                if !matches!(stop.try_recv(), Err(mpsc::TryRecvError::Empty)) {
                    break;
                }
                let mut message: MSG = std::mem::zeroed();
                while PeekMessageW(&mut message, ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                    if message.message == WM_QUIT {
                        state.stopping.set(true);
                    }
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
                if !closing && (!active_desktop() || monitors().ok().as_ref() != Some(&bounds)) {
                    state.stopping.set(true);
                }
                let raise = RAISE_COVERS.with(|raise| raise.replace(false));
                for window in &windows {
                    if IsWindowVisible(window.0) == 0 {
                        state.stopping.set(true);
                    }
                    if raise
                        && SetWindowPos(
                            window.0,
                            HWND_TOPMOST,
                            0,
                            0,
                            0,
                            0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                        ) == 0
                    {
                        state.stopping.set(true);
                    }
                }
                if state.stopping.get() && !closing {
                    closing = true;
                    for window in &windows {
                        InvalidateRect(window.0, ptr::null(), FALSE);
                    }
                    if !request_close(conn_id) {
                        break;
                    }
                }
                MsgWaitForMultipleObjects(0, ptr::null(), FALSE, 100, QS_ALLINPUT);
            }
        }));
        if monitored.is_err() {
            log::error!(
                "Screen privacy monitor failed; closing its session before restoring screens"
            );
            if request_close(conn_id) {
                let _ = stop.recv();
            }
        }
        alive.store(false, Ordering::Release);
        // Dropping these same-thread HWNDs restores the desktop even on unwind.
        drop(_event_hook);
        drop(_hotkey);
        drop(windows);
        DwmFlush();
    }
    Ok(())
}

#[cfg(test)]
#[path = "privacy_tests.rs"]
mod tests;
