//! Bounded synthetic-window check against the same scrap crate as the Windows host.
//! Captured desktop frames remain in memory; only test-patch verdicts are printed.
use scrap::{Capturer, Display, Frame, TraitCapturer, TraitPixelBuffer};
use std::{io::ErrorKind, ptr, thread, sync::atomic::{AtomicUsize, Ordering}, time::{Duration, Instant}};
use winapi::{
    shared::{minwindef::*, windef::*},
    um::{libloaderapi::GetModuleHandleW, processthreadsapi::GetCurrentThreadId, wingdi::*, winuser::*},
};

pub(crate) const MARKER: COLORREF = 0x0047c125;
pub(crate) const CHANGED_MARKER: COLORREF = 0x00db5a9c;
const BLACK: COLORREF = 0x00101010;
const EXCLUDED: DWORD = 0x11;
static TARGET_LEFT: AtomicUsize = AtomicUsize::new(0);
static TARGET_RIGHT: AtomicUsize = AtomicUsize::new(0);
static MOUSE_MESSAGES: AtomicUsize = AtomicUsize::new(0);

pub(crate) fn wide(text: &str) -> Vec<u16> { text.encode_utf16().chain(Some(0)).collect() }

pub(crate) unsafe extern "system" fn wndproc(hwnd: HWND, message: UINT, w: WPARAM, l: LPARAM) -> LRESULT {
    if (WM_MOUSEFIRST..=WM_MOUSELAST).contains(&message) { MOUSE_MESSAGES.fetch_add(1, Ordering::SeqCst); }
    if message == WM_NCHITTEST && GetWindowLongPtrW(hwnd, GWLP_USERDATA) as COLORREF == BLACK {
        return HTTRANSPARENT as _;
    }
    if message == WM_MOUSEACTIVATE && GetWindowLongPtrW(hwnd, GWLP_USERDATA) as COLORREF == BLACK { return MA_NOACTIVATE as _; }
    if message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN {
        if GetWindowLongPtrW(hwnd, GWLP_USERDATA) as COLORREF != BLACK {
            if message == WM_LBUTTONDOWN { TARGET_LEFT.fetch_add(1, Ordering::SeqCst); }
            else { TARGET_RIGHT.fetch_add(1, Ordering::SeqCst); }
        }
        return 0;
    }
    if message == WM_PAINT {
        let mut paint: PAINTSTRUCT = std::mem::zeroed();
        let dc = BeginPaint(hwnd, &mut paint);
        let brush = CreateSolidBrush(GetWindowLongPtrW(hwnd, GWLP_USERDATA) as COLORREF);
        FillRect(dc, &paint.rcPaint, brush);
        DeleteObject(brush as _);
        EndPaint(hwnd, &paint);
        return 0;
    }
    DefWindowProcW(hwnd, message, w, l)
}

pub(crate) struct TestWindow(pub(crate) HWND);
impl TestWindow {
    pub(crate) fn new(class: &[u16], x: i32, y: i32, color: COLORREF, excluded: bool) -> Result<Self, String> {
        unsafe {
            let overlay_flags = if excluded { WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW } else { 0 };
            let style = if excluded { WS_POPUP } else { WS_OVERLAPPEDWINDOW };
            let hwnd = CreateWindowExW(WS_EX_TOPMOST | overlay_flags,
                class.as_ptr(), wide("Rymu synthetic privacy capture probe").as_ptr(), style,
                x, y, 160, 120, ptr::null_mut(), ptr::null_mut(), GetModuleHandleW(ptr::null()), ptr::null_mut());
            if hwnd.is_null() { return Err("CreateWindowExW failed".into()); }
            let window = Self(hwnd);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, color as isize);
            if excluded && SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA) == 0 {
                return Err("SetLayeredWindowAttributes alpha255 failed".into());
            }
            if excluded && SetWindowDisplayAffinity(hwnd, EXCLUDED) == 0 {
                return Err(format!("SetWindowDisplayAffinity failed: {}", std::io::Error::last_os_error()));
            }
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            UpdateWindow(hwnd);
            if !excluded { SetForegroundWindow(hwnd); SetFocus(hwnd); }
            Ok(window)
        }
    }
    pub(crate) fn color(&self, color: COLORREF) {
        unsafe {
            SetWindowLongPtrW(self.0, GWLP_USERDATA, color as isize);
            InvalidateRect(self.0, ptr::null(), 1);
            UpdateWindow(self.0);
        }
    }
    fn verify_overlay(&self) -> Result<(), String> {
        unsafe {
            let mut affinity = 0;
            if GetWindowDisplayAffinity(self.0, &mut affinity) == 0 || affinity != EXCLUDED {
                return Err("overlay exclusion affinity not retained".into());
            }
            if IsWindowVisible(self.0) == 0 || GetWindowLongW(self.0, GWL_EXSTYLE) as DWORD & WS_EX_TOPMOST == 0 {
                return Err("overlay not visible/topmost".into());
            }
            // GetDC on the owned HWND inspects its painted surface, not the desktop.
            let dc = GetDC(self.0);
            let pixel = GetPixel(dc, 80, 60);
            ReleaseDC(self.0, dc);
            if pixel != BLACK { return Err(format!("owned overlay surface differs from opaque test shade: {pixel:x}")); }
            Ok(())
        }
    }
}
impl Drop for TestWindow { fn drop(&mut self) { unsafe { DestroyWindow(self.0); } } }

fn click_through(_x: i32, _y: i32, target: HWND, overlay: HWND) -> Result<(), String> {
    struct Cursor(POINT);
    impl Drop for Cursor { fn drop(&mut self) { unsafe { SetCursorPos(self.0.x, self.0.y); } } }
    struct AttachedInput { current: DWORD, foreground_thread: DWORD, foreground: HWND, attached: bool }
    impl Drop for AttachedInput { fn drop(&mut self) { unsafe {
        if self.attached {
            if IsWindow(self.foreground)!=0 { SetForegroundWindow(self.foreground); }
            AttachThreadInput(self.current,self.foreground_thread,FALSE);
        }
    } } }
    unsafe {
        let mut original: POINT = std::mem::zeroed();
        if GetCursorPos(&mut original) == 0 { return Err("GetCursorPos failed".into()); }
        let _restore = Cursor(original);
        let foreground=GetForegroundWindow();
        let foreground_thread=GetWindowThreadProcessId(foreground,ptr::null_mut());
        let current=GetCurrentThreadId();
        let attached=foreground_thread!=0 && foreground_thread!=current && AttachThreadInput(current,foreground_thread,TRUE)!=0;
        let _input=AttachedInput{current,foreground_thread,foreground,attached};
        SetForegroundWindow(target);
        SetFocus(target);
        let before_control = TARGET_LEFT.load(Ordering::SeqCst);
        SendMessageW(target, WM_LBUTTONDOWN, MK_LBUTTON as _, 0);
        SendMessageW(target, WM_LBUTTONUP, 0, 0);
        println!("owned_direct_callback_control={}", TARGET_LEFT.load(Ordering::SeqCst)==before_control+1);
        let left = TARGET_LEFT.load(Ordering::SeqCst);
        let right = TARGET_RIGHT.load(Ordering::SeqCst);
        let mut client: RECT = std::mem::zeroed();
        GetClientRect(target, &mut client);
        let mut center = POINT { x: (client.right-client.left)/2, y: (client.bottom-client.top)/2 };
        if ClientToScreen(target,&mut center)==0 { return Err("client center transform failed".into()); }
        let (x,y)=(center.x,center.y);
        if SetCursorPos(x, y) == 0 { return Err("SetCursorPos test target failed".into()); }
        pump();
        thread::sleep(Duration::from_millis(30));
        let hit = WindowFromPoint(POINT { x, y });
        let hit_type=SendMessageW(target,WM_NCHITTEST,0,(((y as u32&0xffff)<<16)|(x as u32&0xffff)) as LPARAM);
        println!("synthetic_point_hit_target={} hit_overlay={} focus_target={} foreground_target={} client_hit={} enabled={}", hit == target, hit == overlay, GetFocus() == target, GetForegroundWindow() == target,hit_type==HTCLIENT as LRESULT,IsWindowEnabled(target)!=0);
        let mut events: [INPUT; 5] = std::mem::zeroed();
        events[0].type_ = INPUT_MOUSE;
        events[0].u.mi_mut().dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        events[0].u.mi_mut().dx = ((x - GetSystemMetrics(SM_XVIRTUALSCREEN)) * 65535) / (GetSystemMetrics(SM_CXVIRTUALSCREEN)-1);
        events[0].u.mi_mut().dy = ((y - GetSystemMetrics(SM_YVIRTUALSCREEN)) * 65535) / (GetSystemMetrics(SM_CYVIRTUALSCREEN)-1);
        for (input, flag) in events[1..].iter_mut().zip([MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP]) {
            input.type_ = INPUT_MOUSE;
            input.u.mi_mut().dwFlags = flag;
        }
        for input in &mut events { input.u.mi_mut().dwExtraInfo = 100; }
        for event in events.iter_mut() {
            if SendInput(1, event, std::mem::size_of::<INPUT>() as _) != 1 {
                return Err("SendInput to synthetic target failed".into());
            }
            for _ in 0..5 { pump(); thread::sleep(Duration::from_millis(10)); }
        }
        for _ in 0..25 {
            pump();
            if TARGET_LEFT.load(Ordering::SeqCst) == left + 1 && TARGET_RIGHT.load(Ordering::SeqCst) == right + 1 { return Ok(()); }
            thread::sleep(Duration::from_millis(10));
        }
        let mut now: POINT = std::mem::zeroed(); GetCursorPos(&mut now);
        Err(format!("left/right input did not reach the owned synthetic target beneath the overlay; left_delta={} right_delta={} mouse_messages={} cursor_near_target={}", TARGET_LEFT.load(Ordering::SeqCst)-left, TARGET_RIGHT.load(Ordering::SeqCst)-right, MOUSE_MESSAGES.load(Ordering::SeqCst), (now.x-x).abs()<3 && (now.y-y).abs()<3))
    }
}

pub(crate) fn pump() {
    unsafe {
        let mut message: MSG = std::mem::zeroed();
        while PeekMessageW(&mut message, ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
            TranslateMessage(&message); DispatchMessageW(&message);
        }
    }
}

pub(crate) fn marker_frame(capturer: &mut Capturer, color: COLORREF) -> Result<(), String> {
    let started = Instant::now();
    let expected = [(color >> 16) as u8, (color >> 8) as u8, color as u8];
    while started.elapsed() < Duration::from_secs(4) {
        pump();
        match capturer.frame(Duration::from_millis(100)) {
            Ok(Frame::PixelBuffer(frame)) => {
                let data = frame.data();
                let stride = frame.stride()[0];
                let mut matched = 0;
                for y in [88, 92, 96] {
                    for x in [104, 108, 112] {
                        let at = y * stride + x * 4;
                        if at + 3 < data.len() && data[at..at+3] == expected { matched += 1; }
                    }
                }
                if matched == 9 { return Ok(()); }
            }
            Ok(_) => return Err("Unexpected GPU texture rather than CPU pixel probe".into()),
            Err(error) if error.kind() == ErrorKind::WouldBlock => (),
            Err(error) => return Err(format!("capture failed: {error}")),
        }
        thread::sleep(Duration::from_millis(20));
    }
    Err("synthetic marker did not appear in captured frames within four seconds".into())
}

fn run() -> Result<(), String> {
    struct Foreground(HWND);
    impl Drop for Foreground { fn drop(&mut self) { unsafe { if IsWindow(self.0) != 0 { SetForegroundWindow(self.0); } } } }
    let _foreground = Foreground(unsafe { GetForegroundWindow() });
    let capture_only = std::env::args().any(|value| value == "--capture-only");
    let wait_for_click = std::env::args().any(|value| value == "--wait-for-click");
    unsafe { SetThreadDpiAwarenessContext(-4isize as _); }
    let class = wide("RymuPrivacySyntheticCaptureTest");
    unsafe {
        let mut wc: WNDCLASSW = std::mem::zeroed();
        wc.lpfnWndProc = Some(wndproc); wc.lpszClassName = class.as_ptr();
        wc.hInstance = GetModuleHandleW(ptr::null());
        if RegisterClassW(&wc) == 0 { return Err("RegisterClassW failed".into()); }
    }
    let displays = Display::all().map_err(|e| e.to_string())?;
    println!("display_count={}", displays.len());
    if displays.is_empty() { return Err("No active displays".into()); }
    for (index, display) in displays.into_iter().enumerate() {
        let (x, y) = display.origin();
        let marker = TestWindow::new(&class, x + 32, y + 32, MARKER, false)?;
        let mut capture = Capturer::new(display).map_err(|e| e.to_string())?;
        if capture.is_gdi() { return Err(format!("display {index} used GDI fallback; DXGI unqualified")); }
        marker_frame(&mut capture, MARKER)?;
        println!("display={index} baseline_marker=PASS capture=DXGI");
        if wait_for_click {
            println!("Waiting at most sixty seconds for a click on the owned synthetic marker");
            let started=Instant::now();
            while started.elapsed()<Duration::from_secs(60) {
                pump();
                if TARGET_LEFT.load(Ordering::SeqCst)>0 { println!("PASS observed genuine WM_LBUTTONDOWN on synthetic marker"); return Ok(()); }
                thread::sleep(Duration::from_millis(10));
            }
            return Err("No marker click observed during bounded GUI probe".into());
        }
        if !capture_only {
            click_through(x + 108, y + 92, marker.0, ptr::null_mut())?;
            println!("display={index} baseline_injected_click=PASS");
        }
        let overlay = TestWindow::new(&class, x + 32, y + 32, BLACK, true)?;
        overlay.verify_overlay()?;
        marker.color(CHANGED_MARKER);
        marker_frame(&mut capture, CHANGED_MARKER)?;
        println!("display={index} opaque_visible_topmost_overlay=PASS changed_underlying_marker=PASS affinity=0x11");
        if !capture_only {
            click_through(x + 108, y + 92, marker.0, overlay.0)?;
            println!("display={index} injected_left_and_right_click_through=PASS cursor_restored=PASS");
        }
        drop(overlay);
        marker.color(MARKER);
        marker_frame(&mut capture, MARKER)?;
        println!("display={index} after_overlay_destroy_marker=PASS");
    }
    println!("PASS synthetic small-window exclusion using the host scrap DXGI implementation; no screen images saved");
    Ok(())
}

fn main() {
    if let Err(error) = run() { eprintln!("FAIL {error}"); std::process::exit(1); }
}
