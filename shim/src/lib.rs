#![deny(unsafe_op_in_unsafe_fn)]
#![allow(clippy::missing_safety_doc)]

#[cfg(not(target_os = "macos"))]
compile_error!("This shim currently targets macOS (dyld __interpose).");

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::cell::{Cell, RefCell};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::ffi::{CStr, OsStr};
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::os::unix::prelude::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[cfg(target_os = "macos")]
const F_GETPATH: c_int = libc::F_GETPATH;

#[cfg(target_os = "macos")]
mod darwin_sys {
    use libc::c_int;

    pub const SYS_WRITE: c_int = 4;
    pub const SYS_PWRITE: c_int = 154;
    pub const SYS_WRITEV: c_int = 121;
    pub const SYS_CLOSE: c_int = 6;
    pub const SYS_UNLINK: c_int = 10;
    pub const SYS_RENAME: c_int = 128;
    pub const SYS_TRUNCATE: c_int = 200;
    pub const SYS_FTRUNCATE: c_int = 201;
}

//
// -------- Execution context / recursion guard --------
//

#[derive(Debug)]
struct Guard {
    primary: bool,
    enabled: bool,
}

static SHIM_READY: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn shim_library_init() {
    SHIM_READY.store(true, Ordering::SeqCst);
}

#[cfg_attr(target_os = "macos", link_section = "__DATA,__mod_init_func")]
#[used]
static SHIM_INIT_HOOK: unsafe extern "C" fn() = shim_library_init;

thread_local! {
    static IN_SHIM: Cell<u32> = Cell::new(0);
}

impl Guard {
    fn enter() -> Guard {
        if !SHIM_READY.load(Ordering::Relaxed) {
            return Guard {
                primary: false,
                enabled: false,
            };
        }
        let mut primary = false;
        IN_SHIM.with(|cell| {
            let depth = cell.get();
            if depth == 0 {
                primary = true;
            }
            cell.set(depth.saturating_add(1));
        });
        Guard {
            primary,
            enabled: true,
        }
    }
    fn is_primary(&self) -> bool {
        self.primary
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        if !self.enabled {
            return;
        }
        IN_SHIM.with(|cell| {
            let depth = cell.get();
            cell.set(depth.saturating_sub(1));
        });
    }
}

#[inline]
fn in_shim() -> bool {
    if !SHIM_READY.load(Ordering::Relaxed) {
        return false;
    }
    IN_SHIM.with(|cell| cell.get() > 0)
}

#[inline]
unsafe fn syscall_write(fd: c_int, buf: *const c_void, count: libc::size_t) -> libc::ssize_t {
    unsafe {
        libc::syscall(
        darwin_sys::SYS_WRITE,
        fd as libc::intptr_t,
        buf as libc::intptr_t,
        count as libc::intptr_t,
    ) as libc::ssize_t
    }
}

#[inline]
unsafe fn syscall_pwrite(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
    offset: libc::off_t,
) -> libc::ssize_t {
    unsafe {
        libc::syscall(
            darwin_sys::SYS_PWRITE,
            fd as libc::intptr_t,
            buf as libc::intptr_t,
            count as libc::intptr_t,
            offset as libc::intptr_t,
        ) as libc::ssize_t
    }
}

#[inline]
unsafe fn syscall_writev(
    fd: c_int,
    iov: *const libc::iovec,
    iovcnt: c_int,
) -> libc::ssize_t {
    unsafe {
        libc::syscall(
            darwin_sys::SYS_WRITEV,
            fd as libc::intptr_t,
            iov as libc::intptr_t,
            iovcnt as libc::intptr_t,
        ) as libc::ssize_t
    }
}

#[inline]
unsafe fn syscall_close(fd: c_int) -> c_int {
    unsafe { libc::syscall(darwin_sys::SYS_CLOSE, fd as libc::intptr_t) as c_int }
}

#[inline]
unsafe fn syscall_unlink(path: *const c_char) -> c_int {
    unsafe { libc::syscall(darwin_sys::SYS_UNLINK, path as libc::intptr_t) as c_int }
}

#[inline]
unsafe fn syscall_rename(old: *const c_char, new: *const c_char) -> c_int {
    unsafe {
        libc::syscall(
            darwin_sys::SYS_RENAME,
            old as libc::intptr_t,
            new as libc::intptr_t,
        ) as c_int
    }
}

#[inline]
unsafe fn syscall_truncate_path(path: *const c_char, len: libc::off_t) -> c_int {
    unsafe {
        libc::syscall(
            darwin_sys::SYS_TRUNCATE,
            path as libc::intptr_t,
            len as libc::intptr_t,
        ) as c_int
    }
}

#[inline]
unsafe fn syscall_ftruncate_fd(fd: c_int, len: libc::off_t) -> c_int {
    unsafe {
        libc::syscall(
            darwin_sys::SYS_FTRUNCATE,
            fd as libc::intptr_t,
            len as libc::intptr_t,
        ) as c_int
    }
}

//
// -------- File descriptor tracking --------
//

#[derive(Debug, Clone)]
struct FdState {
    path: Option<PathBuf>,
    dev: u64,
    ino: u64,
    dirty: bool,
    pre_sent: bool, // did we already block on the first write/truncate for this FD?
}

static FD_TABLE: Lazy<Mutex<HashMap<RawFd, FdState>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn fd_path(fd: RawFd) -> Option<PathBuf> {
    unsafe {
        let mut buf = [0u8; libc::PATH_MAX as usize];
        let rc = libc::fcntl(fd, F_GETPATH, buf.as_mut_ptr() as *mut c_void);
        if rc == -1 {
            return None;
        }
        let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        let slice = &buf[..len];
        Some(PathBuf::from(OsStr::from_bytes(slice)))
    }
}

fn fd_dev_ino(fd: RawFd) -> Option<(u64, u64)> {
    unsafe {
        let mut st: libc::stat = std::mem::zeroed();
        if libc::fstat(fd, &mut st as *mut _) != 0 {
            return None;
        }
        Some((st.st_dev as u64, st.st_ino as u64))
    }
}

fn is_regular_file(fd: RawFd) -> bool {
    unsafe {
        let mut st: libc::stat = std::mem::zeroed();
        if libc::fstat(fd, &mut st as *mut _) != 0 {
            return false;
        }
        (st.st_mode & libc::S_IFMT) == libc::S_IFREG
    }
}

fn tracked_path(fd: RawFd) -> Option<String> {
    FD_TABLE
        .lock()
        .get(&fd)
        .and_then(|s| s.path.as_ref())
        .map(|p| p.to_string_lossy().to_string())
}

fn mark_fd_dirty(fd: RawFd) {
    let mut t = FD_TABLE.lock();
    let e = t.entry(fd).or_insert_with(|| FdState {
        path: fd_path(fd),
        dev: 0,
        ino: 0,
        dirty: false,
        pre_sent: false,
    });
    if e.path.is_none() {
        e.path = fd_path(fd);
    }
    if (e.dev, e.ino) == (0, 0) {
        if let Some((d, i)) = fd_dev_ino(fd) {
            e.dev = d;
            e.ino = i;
        }
    }
    e.dirty = true;
}

fn take_fd(fd: RawFd) -> Option<FdState> {
    FD_TABLE.lock().remove(&fd)
}

//
// -------- Environment + destination --------
//

#[derive(Debug)]
enum Destination {
    Unix(PathBuf),
    Tcp(String),
    Disabled,
}
static DESTINATION: Lazy<Destination> = Lazy::new(|| {
    if let Some(p) = std::env::var_os("NVIM_CLAUDE_SHIM_SOCK") {
        return Destination::Unix(PathBuf::from(p));
    }
    if let Some(addr) = std::env::var_os("NVIM_CLAUDE_SHIM_TCP") {
        return Destination::Tcp(addr.to_string_lossy().to_string());
    }
    Destination::Disabled
});

static DEBUG: Lazy<bool> = Lazy::new(|| {
    std::env::var("NVIM_CLAUDE_SHIM_DEBUG")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
});

static FAIL_CLOSED: Lazy<bool> = Lazy::new(|| {
    std::env::var("FS_SHIM_FAIL_CLOSED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
});

static PRE_TIMEOUT_MS: Lazy<u64> = Lazy::new(|| {
    std::env::var("FS_SHIM_PRE_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1500)
});

fn log_debug(msg: &str) {
    if !*DEBUG {
        return;
    }
    unsafe {
        let _ = libc::syscall(
            darwin_sys::SYS_WRITE,
            libc::STDERR_FILENO as libc::intptr_t,
            msg.as_ptr() as libc::intptr_t,
            msg.len() as libc::intptr_t,
        );
    }
}

//
// -------- Thread-local control connection --------
//

thread_local! {
    static CTRL_UNIX: RefCell<Option<UnixStream>> = RefCell::new(None);
    static CTRL_TCP: RefCell<Option<std::net::TcpStream>> = RefCell::new(None);
}

// Use the real write/read on socket fds so we never recurse.
fn write_unhooked(fd: RawFd, mut buf: &[u8]) -> std::io::Result<()> {
    unsafe {
        let real = real_write();
        while !buf.is_empty() {
            let n = real(fd, buf.as_ptr() as *const c_void, buf.len());
            if n < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if n == 0 {
                break;
            }
            buf = &buf[n as usize..];
        }
    }
    Ok(())
}

fn read_line_unhooked(fd: RawFd, deadline: Instant) -> std::io::Result<Vec<u8>> {
    unsafe {
        let real = real_read();
        let mut out = Vec::with_capacity(256);
        let mut tmp = [0u8; 512];
        loop {
            if Instant::now() >= deadline {
                return Err(std::io::Error::from(std::io::ErrorKind::TimedOut));
            }
            let n = real(fd, tmp.as_mut_ptr() as *mut c_void, tmp.len());
            if n < 0 {
                let e = std::io::Error::last_os_error();
                if e.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            if n == 0 {
                return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof));
            }
            let n = n as usize;
            if let Some(pos) = tmp[..n].iter().position(|&b| b == b'\n') {
                out.extend_from_slice(&tmp[..pos]);
                return Ok(out);
            } else {
                out.extend_from_slice(&tmp[..n]);
            }
        }
    }
}

fn with_thread_stream<T>(f: impl FnOnce(RawFd) -> T) -> Option<T> {
    match &*DESTINATION {
        Destination::Unix(path) => CTRL_UNIX.with(|cell| {
            if cell.borrow().is_none() {
                match UnixStream::connect(path) {
                    Ok(stream) => {
                        log_debug("shim: connected unix socket\n");
                        stream.set_nonblocking(false).ok();
                        *cell.borrow_mut() = Some(stream);
                    }
                    Err(_) => {
                        log_debug("shim: unix connect failed\n");
                    }
                }
            }
            cell.borrow().as_ref().map(|s| f(s.as_raw_fd()))
        }),
        Destination::Tcp(addr) => CTRL_TCP.with(|cell| {
            if cell.borrow().is_none() {
                if let Ok(stream) = std::net::TcpStream::connect(addr) {
                    stream.set_nonblocking(false).ok();
                    *cell.borrow_mut() = Some(stream);
                }
            }
            cell.borrow().as_ref().map(|s| f(s.as_raw_fd()))
        }),
        Destination::Disabled => None,
    }
}

//
// -------- Minimal JSON-RPC helpers --------
//

#[derive(Serialize)]
struct RpcCall<'a, T: Serialize> {
    jsonrpc: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<u64>,
    method: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<T>,
}

#[derive(Deserialize)]
struct RpcAck {
    #[allow(dead_code)]
    jsonrpc: Option<String>,
    #[allow(dead_code)]
    id: Option<u64>,
    result: Option<AckRes>,
}
#[derive(Deserialize)]
struct AckRes {
    allow: bool,
}

fn debug_event(method: &str, params: serde_json::Value) {
    if !*DEBUG || in_shim() {
        return;
    }
    let call = RpcCall {
        jsonrpc: "2.0",
        id: None,
        method,
        params: Some(params),
    };
    let mut line = match serde_json::to_vec(&call) {
        Ok(v) => v,
        Err(_) => return,
    };
    line.push(b'\n');
    let _ = with_thread_stream(|fd| write_unhooked(fd, &line));
}

// Blocking pre-flight; returns true to allow, false to deny.
fn preflight_block(op: &str, path: &Path) -> bool {
    if matches!(&*DESTINATION, Destination::Disabled) {
        return true;
    }
    // Serialize the request.
    let call = RpcCall {
        jsonrpc: "2.0",
        id: Some(1), // per-thread stream is strictly request->response
        method: op,
        params: Some(json!({
            "pid": unsafe { libc::getpid() },
            "path": path.to_string_lossy()
        })),
    };
    let mut line = match serde_json::to_vec(&call) {
        Ok(v) => v,
        Err(_) => return !*FAIL_CLOSED,
    };
    line.push(b'\n');

    let deadline = Instant::now() + Duration::from_millis(*PRE_TIMEOUT_MS);

    match with_thread_stream(|fd| {
        let _ = write_unhooked(fd, &line);
        read_line_unhooked(fd, deadline)
    }) {
        Some(Ok(bytes)) => {
            if let Ok(ack) = serde_json::from_slice::<RpcAck>(&bytes) {
                if let Some(res) = ack.result {
                    return res.allow;
                }
            }
            !*FAIL_CLOSED
        }
        Some(Err(_)) => !*FAIL_CLOSED,
        None => !*FAIL_CLOSED,
    }
}

fn post_notify(method: &str, params: serde_json::Value) {
    if in_shim() {
        return;
    }
    let call = RpcCall {
        jsonrpc: "2.0",
        id: None, // notification
        method,
        params: Some(params),
    };
    let mut line = match serde_json::to_vec(&call) {
        Ok(v) => v,
        Err(_) => return,
    };
    line.push(b'\n');
    let _ = with_thread_stream(|fd| write_unhooked(fd, &line));
}

//
// -------- C helpers --------
//

fn c_path(ptr: *const c_char) -> Option<PathBuf> {
    if ptr.is_null() {
        return None;
    }
    unsafe {
        let bytes = CStr::from_ptr(ptr).to_bytes();
        if bytes.is_empty() {
            None
        } else {
            Some(PathBuf::from(OsStr::from_bytes(bytes)))
        }
    }
}

#[inline]
fn set_errno(e: c_int) {
    // macOS: __error() -> *mut c_int
    unsafe {
        *libc::__error() = e;
    }
}

//
// -------- dlsym lookup for originals (RTLD_NEXT) --------
//

use std::sync::OnceLock;
macro_rules! declare_symbol {
    ($fn_name:ident, $sym_name:literal, $ty:ty) => {
        fn $fn_name() -> $ty {
            static SLOT: OnceLock<$ty> = OnceLock::new();
            *SLOT.get_or_init(|| unsafe {
                const NAME_BYTES: &[u8] = concat!($sym_name, "\0").as_bytes();
                let cname = CStr::from_bytes_with_nul_unchecked(NAME_BYTES);
                let sym = libc::dlsym(libc::RTLD_NEXT, cname.as_ptr());
                if sym.is_null() {
                    panic!("shim: dlsym failed for {}", $sym_name);
                }
                std::mem::transmute::<*mut c_void, $ty>(sym)
            })
        }
    };
}

type WriteFn = unsafe extern "C" fn(c_int, *const c_void, libc::size_t) -> libc::ssize_t;
type PwriteFn =
    unsafe extern "C" fn(c_int, *const c_void, libc::size_t, libc::off_t) -> libc::ssize_t;
type WritevFn = unsafe extern "C" fn(c_int, *const libc::iovec, c_int) -> libc::ssize_t;
type CloseFn = unsafe extern "C" fn(c_int) -> c_int;
type UnlinkFn = unsafe extern "C" fn(*const c_char) -> c_int;
type RenameFn = unsafe extern "C" fn(*const c_char, *const c_char) -> c_int;
type ReadFn = unsafe extern "C" fn(c_int, *mut c_void, libc::size_t) -> libc::ssize_t;
type FtruncateFn = unsafe extern "C" fn(c_int, libc::off_t) -> c_int;
type TruncateFn = unsafe extern "C" fn(*const c_char, libc::off_t) -> c_int;

declare_symbol!(real_write, "write", WriteFn);
declare_symbol!(real_read, "read", ReadFn);

//
// -------- dyld interpose glue --------
//

#[repr(C)]
struct InterposePair<T> {
    replacement: T,
    original: T,
}
macro_rules! register_interpose {
    ($name:ident, $replacement:expr, $original:expr, $ty:ty) => {
        #[used]
        #[link_section = "__DATA,__interpose"]
        static $name: InterposePair<$ty> = InterposePair {
            replacement: $replacement,
            original: $original,
        };
    };
}

extern "C" {
    fn write(fd: c_int, buf: *const c_void, count: libc::size_t) -> libc::ssize_t;
    #[link_name = "write$NOCANCEL"]
    fn write_nocancel_symbol(fd: c_int, buf: *const c_void, count: libc::size_t) -> libc::ssize_t;
    fn pwrite(
        fd: c_int,
        buf: *const c_void,
        count: libc::size_t,
        offset: libc::off_t,
    ) -> libc::ssize_t;
    #[link_name = "pwrite$NOCANCEL"]
    fn pwrite_nocancel_symbol(
        fd: c_int,
        buf: *const c_void,
        count: libc::size_t,
        offset: libc::off_t,
    ) -> libc::ssize_t;
    fn writev(fd: c_int, iov: *const libc::iovec, iovcnt: c_int) -> libc::ssize_t;
    #[link_name = "writev$NOCANCEL"]
    fn writev_nocancel_symbol(fd: c_int, iov: *const libc::iovec, iovcnt: c_int) -> libc::ssize_t;

    fn close(fd: c_int) -> c_int;
    #[link_name = "close$NOCANCEL"]
    fn close_nocancel_symbol(fd: c_int) -> c_int;

    fn unlink(path: *const c_char) -> c_int;

    fn rename(old: *const c_char, new: *const c_char) -> c_int;
    #[cfg(not(target_arch = "aarch64"))]
    #[link_name = "rename$UNIX2003"]
    fn rename_unix2003_symbol(old: *const c_char, new: *const c_char) -> c_int;

    #[cfg(not(target_arch = "aarch64"))]
    #[link_name = "unlink$NOCANCEL"]
    fn unlink_nocancel_symbol(path: *const c_char) -> c_int;

    fn ftruncate(fd: c_int, length: libc::off_t) -> c_int;
    fn truncate(path: *const c_char, length: libc::off_t) -> c_int;
}

//
// -------- Handlers --------
//

fn maybe_pre_on_first_write(fd: c_int) -> bool {
    if !is_regular_file(fd) {
        return true;
    }
    let (path_opt, send_pre) = {
        let mut t = FD_TABLE.lock();
        let e = t.entry(fd).or_insert_with(|| FdState {
            path: fd_path(fd),
            dev: 0,
            ino: 0,
            dirty: false,
            pre_sent: false,
        });
        if e.path.is_none() {
            e.path = fd_path(fd);
        }
        if (e.dev, e.ino) == (0, 0) {
            if let Some((d, i)) = fd_dev_ino(fd) {
                e.dev = d;
                e.ino = i;
            }
        }
        if !e.pre_sent {
            e.pre_sent = true;
            (e.path.clone(), true)
        } else {
            (e.path.clone(), false)
        }
    };

    if send_pre {
        if let Some(ref p) = path_opt {
            return preflight_block("pre_modify", p);
        }
    }
    true
}

unsafe fn handle_write(fd: c_int, buf: *const c_void, count: libc::size_t) -> libc::ssize_t {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_write(fd, buf, count) };
    }

    if guard.is_primary() && count > 0 {
        if !maybe_pre_on_first_write(fd) {
            set_errno(libc::EPERM);
            return -1;
        }
    }

    let res = unsafe { syscall_write(fd, buf, count) };

    if guard.is_primary() && res > 0 && count > 0 {
        mark_fd_dirty(fd);
        debug_event(
            "shim/write_call",
            json!({ "fd": fd, "count": count, "res": res, "tracked_path": tracked_path(fd)}),
        );
    }
    res
}

unsafe fn handle_pwrite(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
    offset: libc::off_t,
) -> libc::ssize_t {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_pwrite(fd, buf, count, offset) };
    }

    if guard.is_primary() && count > 0 {
        if !maybe_pre_on_first_write(fd) {
            set_errno(libc::EPERM);
            return -1;
        }
    }

    let res = unsafe { syscall_pwrite(fd, buf, count, offset) };

    if guard.is_primary() && res > 0 && count > 0 {
        mark_fd_dirty(fd);
        debug_event(
            "shim/pwrite_call",
            json!({ "fd": fd, "count": count, "res": res, "tracked_path": tracked_path(fd)}),
        );
    }
    res
}

unsafe fn handle_writev(
    fd: c_int,
    iov: *const libc::iovec,
    iovcnt: c_int,
) -> libc::ssize_t {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_writev(fd, iov, iovcnt) };
    }

    if guard.is_primary() && iovcnt > 0 {
        if !maybe_pre_on_first_write(fd) {
            set_errno(libc::EPERM);
            return -1;
        }
    }

    let res = unsafe { syscall_writev(fd, iov, iovcnt) };

    if guard.is_primary() && res >= 0 {
        mark_fd_dirty(fd);
        debug_event(
            "shim/writev_call",
            json!({ "fd": fd, "iovcnt": iovcnt, "res": res, "tracked_path": tracked_path(fd)}),
        );
    }
    res
}

unsafe fn handle_close(fd: c_int) -> c_int {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_close(fd) };
    }

    let state = if guard.is_primary() {
        // Peek state before close; we remove after.
        FD_TABLE.lock().get(&fd).cloned()
    } else {
        None
    };

    let rc = unsafe { syscall_close(fd) };

    if guard.is_primary() {
        let info = take_fd(fd).or(state);
        if rc == 0 {
            if let Some(info) = info {
                if let Some(p) = info.path {
                    if info.dirty {
                        post_notify("post_modify", json!({ "path": p.to_string_lossy() }));
                    }
                }
            }
        }
        debug_event(
            "shim/close_call",
            json!({ "fd": fd, "rc": rc, "tracked_path": tracked_path(fd)}),
        );
    }

    rc
}

unsafe fn handle_unlink(path: *const c_char) -> c_int {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_unlink(path) };
    }

    let pbuf = c_path(path);
    if guard.is_primary() {
        if let Some(ref p) = pbuf {
            if !preflight_block("pre_delete", p) {
                set_errno(libc::EPERM);
                return -1;
            }
        }
    }

    let rc = unsafe { syscall_unlink(path) };

    if guard.is_primary() && rc == 0 {
        if let Some(p) = pbuf {
            post_notify("post_delete", json!({ "path": p.to_string_lossy() }));
        }
        debug_event(
            "shim/unlink_call",
            json!({ "rc": rc, "path": c_path(path).map(|p| p.to_string_lossy().to_string()) }),
        );
    }

    rc
}

unsafe fn handle_rename(old: *const c_char, new: *const c_char) -> c_int {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_rename(old, new) };
    }

    let oldp = c_path(old);
    let newp = c_path(new);

    if guard.is_primary() {
        if let Some(ref to) = newp {
            if !preflight_block("pre_rename", to) {
                set_errno(libc::EPERM);
                return -1;
            }
        }
    }

    let rc = unsafe { syscall_rename(old, new) };

    if guard.is_primary() && rc == 0 {
        if let Some(ref to) = newp {
            post_notify("post_modify", json!({ "path": to.to_string_lossy() }));
        }
        debug_event(
            "shim/rename_call",
            json!({
                "rc": rc,
                "oldPath": oldp.as_ref().map(|p| p.to_string_lossy().to_string()),
                "newPath": newp.as_ref().map(|p| p.to_string_lossy().to_string())
            }),
        );
    }

    rc
}

unsafe fn handle_ftruncate(fd: c_int, len: libc::off_t) -> c_int {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_ftruncate_fd(fd, len) };
    }

    if guard.is_primary() {
        if let Some(p) = tracked_path(fd).map(PathBuf::from) {
            if !preflight_block("pre_truncate", &p) {
                set_errno(libc::EPERM);
                return -1;
            }
        }
    }

    let rc = unsafe { syscall_ftruncate_fd(fd, len) };

    if guard.is_primary() && rc == 0 {
        mark_fd_dirty(fd);
        debug_event(
            "shim/ftruncate_call",
            json!({ "fd": fd, "len": len, "rc": rc, "tracked_path": tracked_path(fd)}),
        );
    }
    rc
}

unsafe fn handle_truncate(path: *const c_char, len: libc::off_t) -> c_int {
    let guard = Guard::enter();

    if !guard.enabled {
        return unsafe { syscall_truncate_path(path, len) };
    }

    let pbuf = c_path(path);
    if guard.is_primary() {
        if let Some(ref p) = pbuf {
            if !preflight_block("pre_truncate", p) {
                set_errno(libc::EPERM);
                return -1;
            }
        }
    }

    let rc = unsafe { syscall_truncate_path(path, len) };

    if guard.is_primary() && rc == 0 {
        if let Some(p) = pbuf {
            post_notify("post_modify", json!({ "path": p.to_string_lossy() }));
        }
        debug_event(
            "shim/truncate_call",
            json!({ "len": len, "rc": rc, "path": c_path(path).map(|p| p.to_string_lossy().to_string()) }),
        );
    }

    rc
}

//
// -------- Shims + interpose registration --------
//

unsafe extern "C" fn shim_write(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
) -> libc::ssize_t {
    unsafe { handle_write(fd, buf, count) }
}
register_interpose!(INTERPOSE_WRITE, shim_write, write as WriteFn, WriteFn);

unsafe extern "C" fn shim_write_nocancel(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
) -> libc::ssize_t {
    unsafe { handle_write(fd, buf, count) }
}
register_interpose!(
    INTERPOSE_WRITE_NC,
    shim_write_nocancel,
    write_nocancel_symbol as WriteFn,
    WriteFn
);

unsafe extern "C" fn shim_pwrite(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
    offset: libc::off_t,
) -> libc::ssize_t {
    unsafe { handle_pwrite(fd, buf, count, offset) }
}
register_interpose!(INTERPOSE_PWRITE, shim_pwrite, pwrite as PwriteFn, PwriteFn);

unsafe extern "C" fn shim_pwrite_nocancel(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
    offset: libc::off_t,
) -> libc::ssize_t {
    unsafe { handle_pwrite(fd, buf, count, offset) }
}
register_interpose!(
    INTERPOSE_PWRITE_NC,
    shim_pwrite_nocancel,
    pwrite_nocancel_symbol as PwriteFn,
    PwriteFn
);

unsafe extern "C" fn shim_writev(
    fd: c_int,
    iov: *const libc::iovec,
    iovcnt: c_int,
) -> libc::ssize_t {
    unsafe { handle_writev(fd, iov, iovcnt) }
}
register_interpose!(INTERPOSE_WRITEV, shim_writev, writev as WritevFn, WritevFn);

unsafe extern "C" fn shim_writev_nocancel(
    fd: c_int,
    iov: *const libc::iovec,
    iovcnt: c_int,
) -> libc::ssize_t {
    unsafe { handle_writev(fd, iov, iovcnt) }
}
register_interpose!(
    INTERPOSE_WRITEV_NC,
    shim_writev_nocancel,
    writev_nocancel_symbol as WritevFn,
    WritevFn
);

unsafe extern "C" fn shim_close(fd: c_int) -> c_int {
    unsafe { handle_close(fd) }
}
register_interpose!(INTERPOSE_CLOSE, shim_close, close as CloseFn, CloseFn);

unsafe extern "C" fn shim_close_nocancel(fd: c_int) -> c_int {
    unsafe { handle_close(fd) }
}
register_interpose!(
    INTERPOSE_CLOSE_NC,
    shim_close_nocancel,
    close_nocancel_symbol as CloseFn,
    CloseFn
);

unsafe extern "C" fn shim_unlink(path: *const c_char) -> c_int {
    unsafe { handle_unlink(path) }
}
register_interpose!(INTERPOSE_UNLINK, shim_unlink, unlink as UnlinkFn, UnlinkFn);

#[cfg(not(target_arch = "aarch64"))]
unsafe extern "C" fn shim_unlink_nocancel(path: *const c_char) -> c_int {
    unsafe { handle_unlink(path) }
}
#[cfg(not(target_arch = "aarch64"))]
register_interpose!(
    INTERPOSE_UNLINK_NC,
    shim_unlink_nocancel,
    unlink_nocancel_symbol as UnlinkFn,
    UnlinkFn
);

unsafe extern "C" fn shim_rename(old: *const c_char, new: *const c_char) -> c_int {
    unsafe { handle_rename(old, new) }
}
register_interpose!(INTERPOSE_RENAME, shim_rename, rename as RenameFn, RenameFn);

#[cfg(not(target_arch = "aarch64"))]
unsafe extern "C" fn shim_rename_unix2003(old: *const c_char, new: *const c_char) -> c_int {
    unsafe { handle_rename(old, new) }
}
#[cfg(not(target_arch = "aarch64"))]
register_interpose!(
    INTERPOSE_RENAME_U2003,
    shim_rename_unix2003,
    rename_unix2003_symbol as RenameFn,
    RenameFn
);

unsafe extern "C" fn shim_ftruncate(fd: c_int, length: libc::off_t) -> c_int {
    unsafe { handle_ftruncate(fd, length) }
}
register_interpose!(
    INTERPOSE_FTRUNCATE,
    shim_ftruncate,
    ftruncate as FtruncateFn,
    FtruncateFn
);

unsafe extern "C" fn shim_truncate(path: *const c_char, length: libc::off_t) -> c_int {
    unsafe { handle_truncate(path, length) }
}
register_interpose!(
    INTERPOSE_TRUNCATE,
    shim_truncate,
    truncate as TruncateFn,
    TruncateFn
);
