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
use presage::model::identity::OnNewIdentity;
use presage::model::messages::Received;
use presage::store::StateStore;
use presage::Manager;
use presage_store_sqlite::SqliteStore;
use tokio::sync::{mpsc as tmpsc, oneshot};

mod sync;
use sync::StoredManager;

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
    Whoami {
        reply: oneshot::Sender<Result<String, String>>,
    },
    RequestContacts {
        reply: oneshot::Sender<Result<(), String>>,
    },
    StartSync {
        reply: oneshot::Sender<Result<(), String>>,
    },
    PollEvent {
        reply: oneshot::Sender<Option<String>>,
    },
    Roster {
        reply: oneshot::Sender<Result<String, String>>,
    },
    Send {
        thread: String,
        body: String,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    Logout {
        reply: oneshot::Sender<Result<(), String>>,
    },
}

/// Control plane into the running sync loop (which owns `&mut Manager`).
enum LoopCtrl {
    Shutdown,
    RequestContacts {
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    Send {
        thread: String,
        body: String,
        reply: tokio::sync::oneshot::Sender<Result<u64, String>>,
    },
}

enum PollLink {
    Linked,
    Pending,
    Failed(String),
}

enum WorkerState {
    Fresh,
    Ready { store: SqliteStore, db_path: String },
    Linking { task: tokio::task::JoinHandle<Result<StoredManager, String>>, db_path: String },
    Linked(Box<LinkedState>),
}

struct LinkedState {
    db_path: String,
    /// Live manager handle. `None` once the sync loop owns it.
    manager: Option<StoredManager>,
    /// Control plane into the sync loop, if running.
    ctrl: Option<tmpsc::UnboundedSender<LoopCtrl>>,
    /// Drained by `core_cmd_poll_event` (null = empty, not an error).
    events: Option<std::sync::mpsc::Receiver<String>>,
}

impl LinkedState {
    fn new(db_path: String, manager: StoredManager) -> Self {
        Self { db_path, manager: Some(manager), ctrl: None, events: None }
    }

    async fn open_store(&self) -> Result<SqliteStore, String> {
        SqliteStore::open(&self.db_path, OnNewIdentity::Trust)
            .await
            .map_err(|e| format!("open store: {e}"))
    }
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
                            let _ = reply.send(matches!(state, WorkerState::Linked(_)));
                        }
                        Command::Whoami { reply } => {
                            let result = cmd_whoami(&state).await;
                            let _ = reply.send(result);
                        }
                        Command::RequestContacts { reply } => {
                            let result = cmd_request_contacts(&mut state).await;
                            let _ = reply.send(result);
                        }
                        Command::StartSync { reply } => {
                            let result = cmd_start_sync(&mut state).await;
                            let _ = reply.send(result);
                        }
                        Command::PollEvent { reply } => {
                            let event = match &state {
                                WorkerState::Linked(linked) => linked
                                    .events
                                    .as_ref()
                                    .and_then(|rx| rx.try_recv().ok()),
                                _ => None,
                            };
                            let _ = reply.send(event);
                        }
                        Command::Roster { reply } => {
                            let result = cmd_roster(&state).await;
                            let _ = reply.send(result);
                        }
                        Command::Send { thread, body, reply } => {
                            let result = cmd_send(&mut state, &thread, &body).await;
                            let _ = reply.send(result);
                        }
                        Command::Logout { reply } => {
                            let result = cmd_logout(&mut state).await;
                            let _ = reply.send(result);
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
            *state = WorkerState::Linked(Box::new(LinkedState::new(db_path.to_string(), manager)));
            Ok(true)
        }
        Err(presage::Error::NotYetRegisteredError) => {
            let store = SqliteStore::open(db_path, OnNewIdentity::Trust)
                .await
                .map_err(|e| format!("reopen store: {e}"))?;
            *state = WorkerState::Ready { store, db_path: db_path.to_string() };
            Ok(false)
        }
        Err(e) => Err(format!("load session: {e}")),
    }
}

async fn begin_link(state: &mut WorkerState, device_name: &str) -> Result<String, String> {
    // NOTE: `link_secondary_device` clears registration, so refuse when a
    // live session exists — re-linking must be explicit (unlink first, M1b).
    let (store, db_path) = match std::mem::replace(state, WorkerState::Fresh) {
        WorkerState::Ready { store, db_path } => (store, db_path),
        WorkerState::Fresh => {
            return Err("no store: call core_cmd_init first".to_string());
        }
        WorkerState::Linking { task, db_path } => {
            *state = WorkerState::Linking { task, db_path };
            return Err("link already in progress".to_string());
        }
        WorkerState::Linked(linked) => {
            *state = WorkerState::Linked(linked);
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
    *state = WorkerState::Linking { task, db_path };

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
    let (task, db_path) = match std::mem::replace(state, WorkerState::Fresh) {
        WorkerState::Linking { task, db_path } => (task, db_path),
        other => {
            let linked = matches!(other, WorkerState::Linked(_));
            *state = other;
            return if linked { PollLink::Linked } else { PollLink::Pending };
        }
    };
    if !task.is_finished() {
        *state = WorkerState::Linking { task, db_path };
        return PollLink::Pending;
    }
    match task.await {
        Ok(Ok(manager)) => {
            *state = WorkerState::Linked(Box::new(LinkedState::new(db_path, manager)));
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

/// Offline identity probe (who am I).
async fn cmd_whoami(state: &WorkerState) -> Result<String, String> {
    match state {
        WorkerState::Linked(linked) => {
            let store = linked.open_store().await?;
            sync::whoami(&store).await
        }
        WorkerState::Ready { store, .. } => sync::whoami(store).await,
        _ => Err("not initialized".to_string()),
    }
}

/// Offline roster snapshot (contacts + groups + recent messages).
async fn cmd_roster(state: &WorkerState) -> Result<String, String> {
    match state {
        WorkerState::Linked(linked) => {
            let store = linked.open_store().await?;
            sync::build_roster(&store).await
        }
        WorkerState::Ready { store, .. } => sync::build_roster(store).await,
        _ => Err("not initialized".to_string()),
    }
}

/// Ask the primary device to (re-)send contacts/groups sync.
async fn cmd_request_contacts(state: &mut WorkerState) -> Result<(), String> {
    match state {
        WorkerState::Linked(linked) => {
            if let Some(manager) = linked.manager.as_mut() {
                manager
                    .request_contacts()
                    .await
                    .map_err(|e| format!("request contacts: {e}"))
            } else if let Some(ctrl) = linked.ctrl.as_ref() {
                let (tx, rx) = tokio::sync::oneshot::channel();
                ctrl.send(LoopCtrl::RequestContacts { reply: tx })
                    .map_err(|_| "sync loop is gone".to_string())?;
                rx.await.map_err(|_| "sync loop dropped reply".to_string())?
            } else {
                Err("sync loop not running".to_string())
            }
        }
        _ => Err("not linked".to_string()),
    }
}

/// Start the background receive loop (idempotent). Moves the manager into
/// the loop task; sends/controls go through the loop channel afterwards.
async fn cmd_start_sync(state: &mut WorkerState) -> Result<(), String> {
    let linked = match state {
        WorkerState::Linked(linked) => linked,
        _ => return Err("not linked".to_string()),
    };
    if linked.ctrl.is_some() {
        return Ok(());
    }
    let mut manager = linked
        .manager
        .take()
        .ok_or_else(|| "manager already owned by sync loop".to_string())?;
    let db_path = linked.db_path.clone();

    let store = SqliteStore::open(&db_path, OnNewIdentity::Trust)
        .await
        .map_err(|e| format!("open store: {e}"))?;
    let reg = store
        .load_registration_data()
        .await
        .map_err(|e| format!("registration: {e}"))?
        .ok_or_else(|| "not linked".to_string())?;
    let self_aci = reg.service_ids.aci.to_string();

    let (event_tx, event_rx) = std::sync::mpsc::channel::<String>();
    let (ctrl_tx, mut ctrl_rx) = tmpsc::unbounded_channel::<LoopCtrl>();
    tokio::task::spawn_local(async move {
        use futures::StreamExt;
        let mut names = sync::load_names(&store).await;
        let send_listen = async {
            match manager.receive_messages().await {
                Ok(stream) => {
                    let mut stream = Box::pin(stream);
                    loop {
                        tokio::select! {
                            biased;
                            ctrl = ctrl_rx.recv() => match ctrl {
                                Some(LoopCtrl::Shutdown) => break,
                                Some(LoopCtrl::RequestContacts { reply }) => {
                                    let r = manager.request_contacts().await
                                        .map_err(|e| format!("request contacts: {e}"));
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::Send { thread, body, reply }) => {
                                    let r = sync::do_send(&mut manager, &thread, &body).await;
                                    let _ = reply.send(r);
                                }
                                None => break,
                            },
                            next = stream.next() => match next {
                                Some(received) => {
                                    if matches!(received, Received::Contacts) {
                                        names = sync::load_names(&store).await;
                                    }
                                    if let Some(ev) = sync::received_event(&received, &self_aci, &names) {
                                        let _ = event_tx.send(ev);
                                    }
                                }
                                None => {
                                    let _ = event_tx.send(r#"{"type":"sync_ended"}"#.to_string());
                                    break;
                                }
                            },
                        }
                    }
                }
                Err(e) => {
                    let _ = event_tx.send(format!(
                        r#"{{"type":"sync_error","error":{}}}"#,
                        serde_json::json!(format!("receive: {e}"))
                    ));
                }
            }
        };
        send_listen.await;
    });
    linked.ctrl = Some(ctrl_tx);
    linked.events = Some(event_rx);
    Ok(())
}

/// Log out: stop the sync loop, wipe registration/keys, return to Ready
/// (fresh QR on next `begin_link`). Messages/contacts/groups stay on disk.
async fn cmd_logout(state: &mut WorkerState) -> Result<(), String> {
    let db_path = match state {
        WorkerState::Linked(linked) => {
            if let Some(ctrl) = linked.ctrl.take() {
                let _ = ctrl.send(LoopCtrl::Shutdown);
            }
            linked.manager.take();
            linked.events.take();
            linked.db_path.clone()
        }
        _ => return Err("not linked".to_string()),
    };
    let mut store = SqliteStore::open(&db_path, OnNewIdentity::Trust)
        .await
        .map_err(|e| format!("open store: {e}"))?;
    {
        use presage::store::Store;
        store
            .clear_registration()
            .await
            .map_err(|e| format!("clear: {e}"))?;
    }
    *state = WorkerState::Ready { store, db_path };
    Ok(())
}

async fn cmd_send(state: &mut WorkerState, thread: &str, body: &str) -> Result<u64, String> {    // Auto-start the loop: sends are routed through it.
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::Send { thread: thread.to_string(), body: body.to_string(), reply: tx })
                .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
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

fn ok_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(s) => s.into_raw(),
        Err(_) => {
            set_last_error("response contained NUL".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Offline identity JSON `{"aci","number"}`, or null (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_whoami() -> *mut c_char {
    match roundtrip(|reply| Command::Whoami { reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Ask the primary device to (re-)send contacts/groups sync. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_request_contacts() -> i32 {
    match roundtrip(|reply| Command::RequestContacts { reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Start the background receive loop (idempotent). 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_start_sync() -> i32 {
    match roundtrip(|reply| Command::StartSync { reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Next queued sync event JSON, or null when the queue is empty (not an error).
#[no_mangle]
pub extern "C" fn core_cmd_poll_event() -> *mut c_char {
    match roundtrip(|reply| Command::PollEvent { reply }) {
        Ok(Some(json)) => ok_string(json),
        Ok(None) | Err(_) => std::ptr::null_mut(),
    }
}

/// Offline roster snapshot JSON (contacts + groups + recent messages),
/// or null (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_roster() -> *mut c_char {
    match roundtrip(|reply| Command::Roster { reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Send a text to "contact:<uuid>" / "group:<hex>". Returns sent timestamp
/// (ms), or -1 on error (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_send(thread: *const c_char, body: *const c_char) -> i64 {    let (t, b) = match (c_str_arg(thread, "thread"), c_str_arg(body, "body")) {
        (Ok(t), Ok(b)) if !b.is_empty() => (t, b),
        _ => {
            set_last_error("thread/body: null, invalid, or empty body".to_string());
            return -1;
        }
    };
    match roundtrip(|reply| Command::Send { thread: t, body: b, reply }) {
        Ok(Ok(ts)) => ts as i64,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Log out (wipe session, back to QR). 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_logout() -> i32 {
    match roundtrip(|reply| Command::Logout { reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => {
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
        // Roster + whoami on a fresh store fail loudly (not linked).
        assert!(core_cmd_roster().is_null());
        assert!(core_cmd_whoami().is_null());
        assert!(!core_last_error().is_null());
        // Logout with no session is an error, not a crash.
        assert_eq!(core_cmd_logout(), -1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
