//! Cuztom Signal Rust core — M1: linked-device provisioning + persistence.
//!
//! Threading model: presage futures use `tokio::spawn_local`, so they are
//! `!Send`. All presage work runs on ONE dedicated worker thread driving a
//! `current_thread` runtime + `LocalSet`. Swift talks to it via a C ABI that
//! posts commands over a channel and blocks on the reply.
//!
//! C ABI (Swift `RustCoreService` resolves these with `dlsym`):
//!   `core_cmd_init(db_path) -> i32`      1 linked, 0 fresh, -1 error
//!   `core_cmd_begin_link(name) -> *mut c_char`  provisioning URL (free with
//!                                        `core_free_string`), null on error
//!   `core_cmd_poll_link() -> i32`        1 linked, 0 pending, -1 failed
//!   `core_cmd_is_linked() -> i32`        1 / 0
//!   `core_last_error() -> *const c_char` copy immediately, valid until next call
//!   `core_free_string(*mut c_char)`
//!
//! M1b (next): receive loop + send + contacts/groups sync over the same pipe.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use presage::libsignal_service::configuration::SignalServers;
use presage::manager::Registered;
use presage::model::identity::OnNewIdentity;
use presage::Manager;
use presage_store_sqlite::SqliteStore;
use tokio::sync::{mpsc as tmpsc, oneshot};

type StoredManager = Manager<SqliteStore, Registered>;

/// Replies back to the (blocking) C caller.
enum Command {
    Init {
        db_path: String,
        reply: oneshot::Sender<Result<bool, String>>,
    },
    BeginLink {
        device_name: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    PollLink {
        reply: oneshot::Sender<PollLink>,
    },
    IsLinked {
        reply: oneshot::Sender<bool>,
    },
}

enum PollLink {
    Linked,
    Pending,
    Failed(String),
}

enum WorkerState {
    Fresh,
    Ready { store: SqliteStore },
    Linking { task: tokio::task::JoinHandle<Result<StoredManager, String>> },
    Linked { manager: StoredManager },
}

struct Core {
    cmd_tx: tmpsc::UnboundedSender<Command>,
}

static CORE: OnceLock<Core> = OnceLock::new();
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());

fn set_last_error(msg: String) {
    if let Ok(mut slot) = LAST_ERROR.lock() {
        *slot = msg;
    }
}

fn core_handle() -> Result<&'static Core, String> {
    CORE.get()
        .ok_or_else(|| "core not initialized (call core_cmd_init first)".to_string())
}

/// Blocking request/response round-trip from any (non-Tokio) thread.
fn roundtrip<T, F>(build: F) -> Result<T, String>
where
    F: FnOnce(oneshot::Sender<T>) -> Command,
{
    let core = core_handle()?;
    let (tx, rx) = oneshot::channel();
    core.cmd_tx
        .send(build(tx))
        .map_err(|_| "core worker is gone".to_string())?;
    rx.blocking_recv()
        .map_err(|_| "core worker dropped the reply".to_string())
}

fn spawn_worker() -> tmpsc::UnboundedSender<Command> {
    let (tx, mut cmd_rx) = tmpsc::unbounded_channel::<Command>();
    std::thread::Builder::new()
        .name("cuztom-signal-core".to_string())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("core runtime");
            let local = tokio::task::LocalSet::new();
            local.block_on(&rt, async move {
                let mut state = WorkerState::Fresh;
                while let Some(cmd) = cmd_rx.recv().await {
                    match cmd {
                        Command::Init { db_path, reply } => {
                            let result = init_state(&mut state, &db_path).await;
                            let _ = reply.send(result);
                        }
                        Command::BeginLink { device_name, reply } => {
                            let result = begin_link(&mut state, &device_name).await;
                            let _ = reply.send(result);
                        }
                        Command::PollLink { reply } => {
                            let result = poll_link(&mut state).await;
                            let _ = reply.send(result);
                        }
                        Command::IsLinked { reply } => {
                            let _ = reply.send(matches!(state, WorkerState::Linked { .. }));
                        }
                    }
                }
            });
        })
        .expect("core worker thread");
    tx
}

async fn init_state(state: &mut WorkerState, db_path: &str) -> Result<bool, String> {
    if matches!(state, WorkerState::Linked { .. }) {
        return Ok(true);
    }
    if let Some(parent) = std::path::Path::new(db_path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| format!("db dir: {e}"))?;
        }
    }
    // No passphrase in M1 (Keychain-backed passphrase lands with M2 storage
    // hardening); same trust policy as `presage-cli`.
    let store = SqliteStore::open(db_path, OnNewIdentity::Trust)
        .await
        .map_err(|e| format!("open store: {e}"))?;
    match Manager::load_registered(store).await {
        Ok(manager) => {
            *state = WorkerState::Linked { manager };
            Ok(true)
        }
        Err(presage::Error::NotYetRegisteredError) => {
            let store = SqliteStore::open(db_path, OnNewIdentity::Trust)
                .await
                .map_err(|e| format!("reopen store: {e}"))?;
            *state = WorkerState::Ready { store };
            Ok(false)
        }
        Err(e) => Err(format!("load session: {e}")),
    }
}

async fn begin_link(state: &mut WorkerState, device_name: &str) -> Result<String, String> {
    // NOTE: `link_secondary_device` clears registration, so refuse when a
    // live session exists — re-linking must be explicit (unlink first, M1b).
    let store = match std::mem::replace(state, WorkerState::Fresh) {
        WorkerState::Ready { store } => store,
        WorkerState::Fresh => {
            return Err("no store: call core_cmd_init first".to_string());
        }
        WorkerState::Linking { task } => {
            *state = WorkerState::Linking { task };
            return Err("link already in progress".to_string());
        }
        WorkerState::Linked { manager } => {
            *state = WorkerState::Linked { manager };
            return Err("already linked".to_string());
        }
    };

    let (url_tx, url_rx) = futures::channel::oneshot::channel();
    let name = device_name.to_string();
    let task = tokio::task::spawn_local(async move {
        Manager::link_secondary_device(store, SignalServers::Production, name, url_tx)
            .await
            .map_err(|e| format!("link: {e}"))
    });
    *state = WorkerState::Linking { task };

    // The provisioning URL arrives as soon as the server side is ready —
    // well before the user scans. 90s covers slow networks; the phone scan
    // itself is tracked via `core_cmd_poll_link`.
    match tokio::time::timeout(std::time::Duration::from_secs(90), url_rx).await {
        Ok(Ok(url)) => Ok(url.to_string()),
        Ok(Err(_)) => Err("link task ended before issuing a QR URL".to_string()),
        Err(_) => Err("timed out waiting for QR URL (link still pending — poll)".to_string()),
    }
}

async fn poll_link(state: &mut WorkerState) -> PollLink {
    let task = match std::mem::replace(state, WorkerState::Fresh) {
        WorkerState::Linking { task } => task,
        other => {
            let linked = matches!(other, WorkerState::Linked { .. });
            *state = other;
            return if linked { PollLink::Linked } else { PollLink::Pending };
        }
    };
    if !task.is_finished() {
        *state = WorkerState::Linking { task };
        return PollLink::Pending;
    }
    match task.await {
        Ok(Ok(manager)) => {
            *state = WorkerState::Linked { manager };
            PollLink::Linked
        }
        Ok(Err(e)) => {
            // Registration was cleared when linking started; go back to Ready
            // would need the store (moved into the task). Fresh forces re-init.
            *state = WorkerState::Fresh;
            PollLink::Failed(e)
        }
        Err(join) => {
            *state = WorkerState::Fresh;
            PollLink::Failed(format!("link task panicked: {join}"))
        }
    }
}

// ---- C ABI ----

fn c_str_arg(ptr: *const c_char, what: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!("{what}: null pointer"));
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(|s| s.to_string())
        .map_err(|_| format!("{what}: not valid UTF-8"))
}

/// 1 linked, 0 fresh, -1 error (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_init(db_path: *const c_char) -> i32 {
    let path = match c_str_arg(db_path, "db_path") {
        Ok(p) => p,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    let core = CORE.get_or_init(|| Core { cmd_tx: spawn_worker() });
    let _ = core;
    match roundtrip(|reply| Command::Init { db_path: path, reply }) {
        Ok(Ok(true)) => 1,
        Ok(Ok(false)) => 0,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Provisioning `sgnl://linkdevice?...` URL (free with `core_free_string`),
/// or null on error (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_begin_link(device_name: *const c_char) -> *mut c_char {
    let name = match c_str_arg(device_name, "device_name") {
        Ok(n) if !n.is_empty() => n,
        Ok(_) => {
            set_last_error("device_name: empty".to_string());
            return std::ptr::null_mut();
        }
        Err(e) => {
            set_last_error(e);
            return std::ptr::null_mut();
        }
    };
    match roundtrip(|reply| Command::BeginLink { device_name: name, reply }) {
        Ok(Ok(url)) => match CString::new(url) {
            Ok(s) => s.into_raw(),
            Err(_) => {
                set_last_error("URL contained NUL".to_string());
                std::ptr::null_mut()
            }
        },
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// 1 linked, 0 still pending, -1 failed (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_poll_link() -> i32 {
    match roundtrip(|reply| Command::PollLink { reply }) {
        Ok(PollLink::Linked) => 1,
        Ok(PollLink::Pending) => 0,
        Ok(PollLink::Failed(e)) => {
            set_last_error(e);
            -1
        }
        Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// 1 if a live linked session exists, else 0.
#[no_mangle]
pub extern "C" fn core_cmd_is_linked() -> i32 {
    match roundtrip(|reply| Command::IsLinked { reply }) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Latest error text. Copy it immediately; valid until the next core call.
#[no_mangle]
pub extern "C" fn core_last_error() -> *const c_char {
    static EMPTY: std::sync::LazyLock<CString> =
        std::sync::LazyLock::new(|| CString::new("").unwrap());
    match LAST_ERROR.lock() {
        Ok(slot) => {
            if slot.is_empty() {
                return EMPTY.as_ptr();
            }
            // Leak one CString per error — bounded by call count, keeps the
            // ABI trivial (no caller-side buffer management).
            Box::leak(Box::new(CString::new(slot.as_str()).unwrap_or_else(|_| EMPTY.clone()))).as_ptr()
        }
        Err(_) => EMPTY.as_ptr(),
    }
}

/// Free a string returned by this library (`core_cmd_begin_link`).
#[no_mangle]
pub extern "C" fn core_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_args_fail_loudly() {
        assert_eq!(core_cmd_init(std::ptr::null()), -1);
        assert!(!core_last_error().is_null());
        assert!(core_cmd_begin_link(std::ptr::null()).is_null());
        // Without init there is no worker: transport-level error, no panic.
        assert_eq!(core_cmd_is_linked(), -1);
        assert_eq!(core_cmd_poll_link(), -1);
        core_free_string(std::ptr::null_mut());
    }

    #[test]
    fn init_rejects_bad_db_dir() {
        // /proc is not writable: open must fail instead of hanging.
        let raw = CString::new("/proc/nope/signal.db").unwrap().into_raw();
        assert_eq!(core_cmd_init(raw), -1);
        core_free_string(raw);
    }

    #[test]
    fn init_creates_temp_store_unlinked() {
        let dir = std::env::temp_dir().join(format!("cuztom-test-{}", std::process::id()));
        let db = dir.join("signal.db");
        let raw = CString::new(db.to_string_lossy().into_owned()).unwrap().into_raw();
        assert_eq!(core_cmd_init(raw), 0);
        core_free_string(raw);
        assert_eq!(core_cmd_is_linked(), 1 - 1); // 0: fresh store, not linked
        assert_eq!(core_cmd_poll_link(), 0); // nothing in flight -> pending/idle
        let _ = std::fs::remove_dir_all(&dir);
    }
}
