//! These ignored component tests briefly cover this workstation's displays.
//! Run in a dedicated, bounded native test process with one test thread.
use super::*;
use scrap::{Capturer, Display, TraitCapturer};
use std::{process::{Command, Stdio}, time::Instant};

#[path = "../../rymu-release/scripts/qa/privacy-capture.rs"]
#[allow(dead_code)]
mod probe;

struct OwnedWindows { pid: u32, windows: Vec<HWND> }
unsafe extern "system" fn own_cover(hwnd: HWND, parameter: LPARAM) -> BOOL {
    let state = &mut *(parameter as *mut OwnedWindows);
    let mut pid = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    if pid == state.pid {
        let mut name = [0u16; 128];
        let count = GetClassNameW(hwnd, name.as_mut_ptr(), name.len() as i32);
        if count > 0 && String::from_utf16_lossy(&name[..count as usize]) == CLASS {
            state.windows.push(hwnd);
        }
    }
    TRUE
}
fn covers(pid: u32) -> Vec<HWND> {
    let mut state = OwnedWindows { pid, windows: Vec::new() };
    assert_ne!(unsafe { EnumWindows(Some(own_cover), &mut state as *mut _ as LPARAM) }, 0);
    state.windows
}
fn absent(pid: u32) {
    let started = Instant::now();
    while !covers(pid).is_empty() && started.elapsed() < Duration::from_secs(3) {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(covers(pid).is_empty(), "process still has screen cover HWNDs");
}
fn prepare() -> Vec<u16> {
    assert!(!unsafe { SetThreadDpiAwarenessContext(-4isize as _) }.is_null());
    assert!(active_desktop(), "physical component test needs active Windows desktop");
    let class = wide("RymuPrivacyProductionMarkerTest");
    unsafe {
        let mut wc: WNDCLASSW = std::mem::zeroed();
        wc.lpfnWndProc = Some(probe::wndproc);
        wc.lpszClassName = class.as_ptr();
        wc.hInstance = GetModuleHandleW(ptr::null());
        assert!(RegisterClassW(&wc) != 0 || Error::last_os_error().raw_os_error() == Some(1410));
    }
    class
}

#[test]
fn privacy_invalid_session_does_not_cover_screens() {
    let mut mode = PrivacyModeImpl::new(IMPL_KEY);
    assert!(mode.turn_on_privacy(0).is_err());
    assert!(mode.turn_on_privacy(-1).is_err());
    assert_eq!(mode.pre_conn_id(), 0);
}

#[test]
#[ignore = "briefly covers all physical displays; explicit bounded desktop qualification only"]
fn privacy_physical_capture_and_restore() {
    let class = prepare();
    let initial_foreground = unsafe { GetForegroundWindow() };
    let displays = Display::all().unwrap();
    let mut targets = Vec::new();
    for display in displays {
        let (x, y) = display.origin();
        let marker = probe::TestWindow::new(&class, x+32, y+32, probe::MARKER, false).unwrap();
        let mut capture = Capturer::new(display).unwrap();
        assert!(!capture.is_gdi(), "test requires DXGI, not fallback");
        probe::marker_frame(&mut capture, probe::MARKER).unwrap();
        targets.push((marker, capture, x, y));
    }
    let mut mode = PrivacyModeImpl::new(IMPL_KEY);
    assert!(mode.turn_on_privacy(42).unwrap());
    let windows = covers(std::process::id());
    assert_eq!(windows.len(), monitors().unwrap().len());
    let mut physical = Vec::new();
    for hwnd in &windows {
        unsafe {
            assert_ne!(IsWindowVisible(*hwnd), 0);
            let mut rect: RECT = std::mem::zeroed();
            assert_ne!(GetWindowRect(*hwnd, &mut rect), 0);
            physical.push(Bounds { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom });
            let mut affinity = 0;
            assert_ne!(GetWindowDisplayAffinity(*hwnd, &mut affinity), 0);
            assert_eq!(affinity, AFFINITY);
            let flags = GetWindowLongW(*hwnd, GWL_EXSTYLE) as DWORD;
            assert_eq!(flags & (WS_EX_TOPMOST|WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE), WS_EX_TOPMOST|WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE);
            let dc = GetDC(*hwnd);
            assert_eq!(GetPixel(dc, 10, 10), 0, "owned physical cover paint must be opaque black");
            ReleaseDC(*hwnd, dc);
        }
    }
    physical.sort_by_key(|b| (b.left,b.top,b.right,b.bottom));
    assert_eq!(physical, monitors().unwrap(), "cover rectangles must match full monitor rectangles");
    for (marker, capture, x, y) in &mut targets {
        marker.color(probe::CHANGED_MARKER);
        probe::marker_frame(capture, probe::CHANGED_MARKER).unwrap();
        assert_eq!(unsafe { WindowFromPoint(POINT{x:*x+108,y:*y+92}) }, marker.0, "cover must not capture target hit testing");
    }
    println!("PASS exact production covers: {} monitors, DXGI changing markers, physical opaque HWND coverage and hit testing", windows.len());
    assert!(mode.turn_off_privacy(43, None).is_err());
    assert_eq!(mode.pre_conn_id(),42);
    mode.turn_off_privacy(42,None).unwrap();
    absent(std::process::id());
    for (marker,capture,_,_) in &mut targets {
        marker.color(probe::MARKER);
        probe::marker_frame(capture,probe::MARKER).unwrap();
    }
    assert!(mode.turn_on_privacy(42).unwrap());
    drop(mode);
    absent(std::process::id());
    drop(targets);
    unsafe { if IsWindow(initial_foreground) != 0 { SetForegroundWindow(initial_foreground); } }
    println!("PASS correct-owner off, wrong-owner denial, capture restoration and Drop cleanup");
}

#[test]
#[ignore = "briefly covers all physical displays; explicit bounded desktop qualification only"]
fn privacy_local_stop_message_restores() {
    prepare();
    let mut mode=PrivacyModeImpl::new(IMPL_KEY);
    assert!(mode.turn_on_privacy(42).unwrap());
    let windows=covers(std::process::id());
    assert!(!windows.is_empty());
    unsafe {
        let duplicate=RegisterHotKey(ptr::null_mut(),0x527a,(MOD_CONTROL|MOD_ALT|MOD_SHIFT|MOD_NOREPEAT) as _,VK_F10 as _);
        if duplicate != 0 { UnregisterHotKey(ptr::null_mut(),0x527a); }
        assert_eq!(duplicate,0,"production emergency hotkey must already be registered");
        assert_ne!(PostMessageW(windows[0],WM_HOTKEY,STOP_HOTKEY as _,0),0);
    }
    absent(std::process::id());
    assert_eq!(mode.pre_conn_id(),42);
    mode.clear();
    assert_eq!(mode.pre_conn_id(),0);
    println!("PASS registered local Stop dispatch restores covers; no authenticated connection fixture present; physical key delivery is separate");
}

#[test]
#[ignore = "helper only; started and forcibly terminated by privacy_process_crash_restores"]
fn privacy_crash_child() {
    if std::env::var_os("RYMU_PRIVACY_CRASH_CHILD").is_none() { return; }
    prepare();
    let mut mode=PrivacyModeImpl::new(IMPL_KEY);
    assert!(mode.turn_on_privacy(42).unwrap());
    thread::sleep(Duration::from_secs(20));
    drop(mode);
    panic!("crash parent did not terminate the bounded helper");
}

#[test]
#[ignore = "briefly covers all physical displays in a process that is forcibly terminated"]
fn privacy_process_crash_restores() {
    struct ChildGuard(std::process::Child);
    impl Drop for ChildGuard { fn drop(&mut self) { let _=self.0.kill(); let _=self.0.wait(); } }
    let mut child=ChildGuard(Command::new(std::env::current_exe().unwrap())
        .args(["--exact","rymu::privacy::tests::privacy_crash_child","--ignored","--nocapture"])
        .env("RYMU_PRIVACY_CRASH_CHILD","1").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap());
    let pid=child.0.id();
    let started=Instant::now();
    let mut windows=Vec::new();
    while started.elapsed()<Duration::from_secs(6) {
        windows=covers(pid);
        if windows.len()==monitors().unwrap().len() && windows.iter().all(|h| unsafe{IsWindowVisible(*h)!=0}) { break; }
        if child.0.try_wait().unwrap().is_some() { break; }
        thread::sleep(Duration::from_millis(30));
    }
    assert_eq!(windows.len(),monitors().unwrap().len(),"crash child did not cover every screen");
    assert!(windows.iter().all(|h|unsafe{IsWindowVisible(*h)!=0}));
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    absent(pid);
    println!("PASS exact production screen cover HWNDs removed by Windows when their owning test process terminates");
}
