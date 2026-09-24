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
use sync::{
    send_call_offer_inner, send_call_answer_inner, send_call_ice_inner, send_call_hangup_inner,
};

mod groups;

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
    SendAttachment {
        thread: String,
        path: String,
        caption: String,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    SendReply {
        thread: String,
        body: String,
        quote_ts: u64,
        quote_author: String,
        quote_body: String,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    SendDelete {
        thread: String,
        target_ts: u64,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    SendReaction {
        thread: String,
        target_sts: u64,
        target_author: String,
        emoji: String,
        remove: bool,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    ThreadPage {
        thread_id: String,
        limit: usize,
        before_ts: u64,
        reply: oneshot::Sender<Result<String, String>>,
    },
    FetchAttachment {
        thread_id: String,
        ts: u64,
        index: usize,
        reply: oneshot::Sender<Result<String, String>>,
    },
    Profile {
        uuid: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    DeleteLocal {
        thread_id: String,
        sts: u64,
        reply: oneshot::Sender<Result<bool, String>>,
    },
    SendReceipt {
        thread: String,
        timestamps: Vec<u64>,
        kind: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    // M2: Group management commands
    GetGroupInfo {
        master_key_hex: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    UpdateGroupTitle {
        master_key_hex: String,
        title: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    UpdateGroupAvatar {
        master_key_hex: String,
        avatar_data: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    AddGroupMembers {
        master_key_hex: String,
        member_acis: Vec<String>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    RemoveGroupMembers {
        master_key_hex: String,
        member_acis: Vec<String>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    PromoteGroupMember {
        master_key_hex: String,
        member_aci: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    DemoteGroupMember {
        master_key_hex: String,
        member_aci: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    GetGroupInviteLink {
        master_key_hex: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    RevokeGroupInviteLink {
        master_key_hex: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    LeaveGroup {
        master_key_hex: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    // M4: Call signaling commands
    SendCallOffer {
        call_id: String,
        to: String,
        media_type: String,
        sdp: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    SendCallAnswer {
        call_id: String,
        sdp: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    SendCallIceCandidate {
        call_id: String,
        candidate: String,
        sdp_mid: String,
        sdp_m_line_index: u32,
        reply: oneshot::Sender<Result<(), String>>,
    },
    SendCallHangup {
        call_id: String,
        reason: String,
        reply: oneshot::Sender<Result<(), String>>,
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
    SendAttachment {
        thread: String,
        path: String,
        caption: String,
        reply: tokio::sync::oneshot::Sender<Result<u64, String>>,
    },
    SendReply {
        thread: String,
        body: String,
        quote_ts: u64,
        quote_author: String,
        quote_body: String,
        reply: tokio::sync::oneshot::Sender<Result<u64, String>>,
    },
    SendDelete {
        thread: String,
        target_ts: u64,
        reply: tokio::sync::oneshot::Sender<Result<u64, String>>,
    },
    SendReaction {
        thread: String,
        target_sts: u64,
        target_author: String,
        emoji: String,
        remove: bool,
        reply: tokio::sync::oneshot::Sender<Result<u64, String>>,
    },
    SendReceipt {
        thread: String,
        timestamps: Vec<u64>,
        kind: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    // M2: Group management
    GetGroupInfo {
        master_key_hex: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    UpdateGroupTitle {
        master_key_hex: String,
        title: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    UpdateGroupAvatar {
        master_key_hex: String,
        avatar_data: Vec<u8>,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    AddGroupMembers {
        master_key_hex: String,
        member_acis: Vec<String>,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    RemoveGroupMembers {
        master_key_hex: String,
        member_acis: Vec<String>,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    PromoteGroupMember {
        master_key_hex: String,
        member_aci: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    DemoteGroupMember {
        master_key_hex: String,
        member_aci: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    GetGroupInviteLink {
        master_key_hex: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    RevokeGroupInviteLink {
        master_key_hex: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    LeaveGroup {
        master_key_hex: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    // M4: Call signaling
    SendCallOffer {
        call_id: String,
        to: String,
        media_type: String,
        sdp: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    SendCallAnswer {
        call_id: String,
        sdp: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    SendCallIceCandidate {
        call_id: String,
        candidate: String,
        sdp_mid: String,
        sdp_m_line_index: u32,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    SendCallHangup {
        call_id: String,
        reason: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    FetchAttachment {
        thread_id: String,
        ts: u64,
        index: usize,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    Profile {
        uuid: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
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
        // presage's `receive_messages` future (websockets, ciphers, caches)
        // is enormous: the default 2 MiB spawned-thread stack overflows.
        // presage-cli never hits this — it runs on the 8 MiB main thread.
        .stack_size(64 * 1024 * 1024)
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
                        Command::SendAttachment { thread, path, caption, reply } => {
                            let result = cmd_send_attachment(&mut state, &thread, &path, &caption).await;
                            let _ = reply.send(result);
                        }
                        Command::SendReply { thread, body, quote_ts, quote_author, quote_body, reply } => {
                            let result = cmd_send_reply(&mut state, &thread, &body, quote_ts, &quote_author, &quote_body).await;
                            let _ = reply.send(result);
                        }
                        Command::SendDelete { thread, target_ts, reply } => {
                            let result = cmd_send_delete(&mut state, &thread, target_ts).await;
                            let _ = reply.send(result);
                        }
                        Command::SendReaction { thread, target_sts, target_author, emoji, remove, reply } => {
                            let result = cmd_send_reaction(&mut state, &thread, target_sts, &target_author, &emoji, remove).await;
                            let _ = reply.send(result);
                        }
                        Command::Profile { uuid, reply } => {
                            let result = cmd_profile(&mut state, &uuid).await;
                            let _ = reply.send(result);
                        }
                        Command::ThreadPage { thread_id, limit, before_ts, reply } => {
                            let result = cmd_thread_page(&state, &thread_id, limit, before_ts).await;
                            let _ = reply.send(result);
                        }
                        Command::FetchAttachment { thread_id, ts, index, reply } => {
                            let result = cmd_fetch_attachment(&mut state, &thread_id, ts, index).await;
                            let _ = reply.send(result);
                        }
                        Command::DeleteLocal { thread_id, sts, reply } => {
                            let result = cmd_delete_local(&state, &thread_id, sts).await;
                            let _ = reply.send(result);
                        }
                        Command::SendReceipt { thread, timestamps, kind, reply } => {
                            let result = cmd_send_receipt(&mut state, &thread, timestamps, &kind).await;
                            let _ = reply.send(result);
                        }
                        // M2: Group management
                        Command::GetGroupInfo { master_key_hex, reply } => {
                            let result = cmd_get_group_info(&mut state, &master_key_hex).await;
                            let _ = reply.send(result);
                        }
                        Command::UpdateGroupTitle { master_key_hex, title, reply } => {
                            let result = cmd_update_group_title(&mut state, &master_key_hex, &title).await;
                            let _ = reply.send(result);
                        }
                        Command::UpdateGroupAvatar { master_key_hex, avatar_data, reply } => {
                            let result = cmd_update_group_avatar(&mut state, &master_key_hex, &avatar_data).await;
                            let _ = reply.send(result);
                        }
                        Command::AddGroupMembers { master_key_hex, member_acis, reply } => {
                            let result = cmd_add_group_members(&mut state, &master_key_hex, &member_acis).await;
                            let _ = reply.send(result);
                        }
                        Command::RemoveGroupMembers { master_key_hex, member_acis, reply } => {
                            let result = cmd_remove_group_members(&mut state, &master_key_hex, &member_acis).await;
                            let _ = reply.send(result);
                        }
                        Command::PromoteGroupMember { master_key_hex, member_aci, reply } => {
                            let result = cmd_promote_group_member(&mut state, &master_key_hex, &member_aci).await;
                            let _ = reply.send(result);
                        }
                        Command::DemoteGroupMember { master_key_hex, member_aci, reply } => {
                            let result = cmd_demote_group_member(&mut state, &master_key_hex, &member_aci).await;
                            let _ = reply.send(result);
                        }
                        Command::GetGroupInviteLink { master_key_hex, reply } => {
                            let result = cmd_get_group_invite_link(&mut state, &master_key_hex).await;
                            let _ = reply.send(result);
                        }
                        Command::RevokeGroupInviteLink { master_key_hex, reply } => {
                            let result = cmd_revoke_group_invite_link(&mut state, &master_key_hex).await;
                            let _ = reply.send(result);
                        }
                        Command::LeaveGroup { master_key_hex, reply } => {
                            let result = cmd_leave_group(&mut state, &master_key_hex).await;
                            let _ = reply.send(result);
                        }
                        // M4: Call signaling
                        Command::SendCallOffer { call_id, to, media_type, sdp, reply } => {
                            let result = cmd_send_call_offer(&mut state, &call_id, &to, &media_type, &sdp).await;
                            let _ = reply.send(result);
                        }
                        Command::SendCallAnswer { call_id, sdp, reply } => {
                            let result = cmd_send_call_answer(&mut state, &call_id, &sdp).await;
                            let _ = reply.send(result);
                        }
                        Command::SendCallIceCandidate { call_id, candidate, sdp_mid, sdp_m_line_index, reply } => {
                            let result = cmd_send_call_ice(&mut state, &call_id, &candidate, &sdp_mid, sdp_m_line_index).await;
                            let _ = reply.send(result);
                        }
                        Command::SendCallHangup { call_id, reason, reply } => {
                            let result = cmd_send_call_hangup(&mut state, &call_id, &reason).await;
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
                                Some(LoopCtrl::SendAttachment { thread, path, caption, reply }) => {
                                    let r = cmd_send_attachment_inner(&mut manager, &thread, &path, &caption).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendReply { thread, body, quote_ts, quote_author, quote_body, reply }) => {
                                    let quote = sync::make_quote(quote_ts, &quote_author, &quote_body);
                                    let r = sync::do_send_full(
                                        &mut manager,
                                        &thread,
                                        &body,
                                        Vec::new(),
                                        sync::SendExtras { quote: Some(quote), delete_ts: None },
                                    )
                                    .await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendDelete { thread, target_ts, reply }) => {
                                    let r = sync::do_send_full(
                                        &mut manager,
                                        &thread,
                                        "",
                                        Vec::new(),
                                        sync::SendExtras { quote: None, delete_ts: Some(target_ts) },
                                    )
                                    .await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendReaction { thread, target_sts, target_author, emoji, remove, reply }) => {
                                    let r = send_reaction_inner(&mut manager, &thread, target_sts, &target_author, &emoji, remove).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendReceipt { thread, timestamps, kind, reply }) => {
                                    let r = sync::send_receipt(&mut manager, &thread, &timestamps, &kind).await;
                                    let _ = reply.send(r);
                                }
                                // M2: Group management
                                Some(LoopCtrl::GetGroupInfo { master_key_hex, reply }) => {
                                    let r = groups::get_group_info(&mut manager, &master_key_hex).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::UpdateGroupTitle { master_key_hex, title, reply }) => {
                                    let r = groups::update_group_title(&mut manager, &master_key_hex, &title).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::UpdateGroupAvatar { master_key_hex, avatar_data, reply }) => {
                                    let r = groups::update_group_avatar(&mut manager, &master_key_hex, &avatar_data).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::AddGroupMembers { master_key_hex, member_acis, reply }) => {
                                    let r = groups::add_group_members(&mut manager, &master_key_hex, &member_acis).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::RemoveGroupMembers { master_key_hex, member_acis, reply }) => {
                                    let r = groups::remove_group_members(&mut manager, &master_key_hex, &member_acis).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::PromoteGroupMember { master_key_hex, member_aci, reply }) => {
                                    let r = groups::promote_group_member(&mut manager, &master_key_hex, &member_aci).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::DemoteGroupMember { master_key_hex, member_aci, reply }) => {
                                    let r = groups::demote_group_member(&mut manager, &master_key_hex, &member_aci).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::GetGroupInviteLink { master_key_hex, reply }) => {
                                    let r = groups::get_group_invite_link(&mut manager, &master_key_hex).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::RevokeGroupInviteLink { master_key_hex, reply }) => {
                                    let r = groups::revoke_group_invite_link(&mut manager, &master_key_hex).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::LeaveGroup { master_key_hex, reply }) => {
                                    let r = groups::leave_group(&mut manager, &master_key_hex).await;
                                    let _ = reply.send(r);
                                }
                                // M4: Call signaling
                                Some(LoopCtrl::SendCallOffer { call_id, to, media_type, sdp, reply }) => {
                                    let r = send_call_offer_inner(&mut manager, &call_id, &to, &media_type, &sdp).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendCallAnswer { call_id, sdp, reply }) => {
                                    let r = send_call_answer_inner(&mut manager, &call_id, &sdp).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendCallIceCandidate { call_id, candidate, sdp_mid, sdp_m_line_index, reply }) => {
                                    let r = send_call_ice_inner(&mut manager, &call_id, &candidate, &sdp_mid, sdp_m_line_index).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::SendCallHangup { call_id, reason, reply }) => {
                                    let r = send_call_hangup_inner(&mut manager, &call_id, &reason).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::FetchAttachment { thread_id, ts, index, reply }) => {
                                    let r = sync::fetch_attachment(&mut manager, &thread_id, ts, index).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::Profile { uuid, reply }) => {
                                    let r = sync::profile_name(&mut manager, &uuid).await;
                                    let _ = reply.send(r);
                                }
                                None => break,
                            },
                            next = stream.next() => match next {
                                Some(Received::Content(c)) => {
                                    // Reactions + receipts travel as message
                                    // envelopes; emit them as events, never rows.
                                    if let Some(rv) = sync::receipt_part(&c, &names) {
                                        let _ = event_tx.send(rv.to_string());
                                    } else {
                                        if let Some(rv) = sync::reaction_part(&c, &names) {
                                            let _ = event_tx.send(rv.to_string());
                                        }
                                        if let Some((mut v, pointers)) =
                                            sync::content_parts(&c, &self_aci, &names)
                                        {
                                            let body_empty = v
                                                .get("body")
                                                .and_then(|b| b.as_str())
                                                .map(|b| b.is_empty())
                                                .unwrap_or(true);
                                            let reaction_only =
                                                body_empty && pointers.is_empty();
                                            if !reaction_only {
                                        // Eagerly fetch small media so the UI can
                                        // render inline. Other file types stay
                                        // metadata-only (manual Download).
                                        let thread = v.get("thread")
                                            .and_then(|t| t.as_str())
                                            .unwrap_or("")
                                            .to_string();
                                        let ts = v.get("ts").and_then(|t| t.as_u64()).unwrap_or(0);
                                        for (i, ptr) in pointers.iter().enumerate() {
                                            let is_media = ptr
                                                .content_type
                                                .as_deref()
                                                .map(|m| {
                                                    m.starts_with("image/") || m.starts_with("video/")
                                                })
                                                .unwrap_or(false);
                                            if !is_media {
                                                continue;
                                            }
                                            match sync::download_attachment(
                                                &mut manager, ptr, &thread, ts, i,
                                            )
                                            .await
                                            {
                                                Ok(Some(path)) => {
                                                    v["attachments"][i]["path"] =
                                                        serde_json::Value::String(path);
                                                }
                                                Ok(None) => {}
                                                Err(e) => {
                                                    let _ = event_tx.send(format!(
                                                        r#"{{"type":"attachment_error","error":{}}}"#,
                                                        serde_json::json!(e)
                                                    ));
                                                }
                                            }
                                        }
                                        let _ = event_tx.send(
                                            serde_json::json!({"type": "message", "message": v})
                                                .to_string(),
                                        );
                                        }
                                    }
                                }
                                }
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
    store
        .clear_registration()
        .await
        .map_err(|e| format!("clear: {e}"))?;
    *state = WorkerState::Ready { store, db_path };
    Ok(())
}

async fn cmd_send(state: &mut WorkerState, thread: &str, body: &str) -> Result<u64, String> {
    // Auto-start the loop: sends are routed through it.
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

/// Older history page for one thread (see `sync::thread_page`).
async fn cmd_thread_page(
    state: &WorkerState,
    thread_id: &str,
    limit: usize,
    before_ts: u64,
) -> Result<String, String> {
    match state {
        WorkerState::Linked(linked) => {
            let store = linked.open_store().await?;
            sync::thread_page(&store, thread_id, limit, before_ts).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Upload + send a local file. `caption` becomes the message body.
async fn cmd_send_attachment_inner(
    manager: &mut StoredManager,
    thread: &str,
    path: &str,
    caption: &str,
) -> Result<u64, String> {
    let ptr = sync::upload_file(manager, std::path::Path::new(path)).await?;
    sync::do_send_full(manager, thread, caption, vec![ptr], sync::SendExtras::default()).await
}

async fn cmd_send_attachment(
    state: &mut WorkerState,
    thread: &str,
    path: &str,
    caption: &str,
) -> Result<u64, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendAttachment {
                thread: thread.to_string(),
                path: path.to_string(),
                caption: caption.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

async fn cmd_send_reply(
    state: &mut WorkerState,
    thread: &str,
    body: &str,
    quote_ts: u64,
    quote_author: &str,
    quote_body: &str,
) -> Result<u64, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendReply {
                thread: thread.to_string(),
                body: body.to_string(),
                quote_ts,
                quote_author: quote_author.to_string(),
                quote_body: quote_body.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

async fn cmd_send_delete(state: &mut WorkerState, thread: &str, target_ts: u64) -> Result<u64, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendDelete { thread: thread.to_string(), target_ts, reply: tx })
                .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

async fn cmd_send_reaction(
    state: &mut WorkerState,
    thread: &str,
    target_sts: u64,
    target_author: &str,
    emoji: &str,
    remove: bool,
) -> Result<u64, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendReaction {
                thread: thread.to_string(),
                target_sts,
                target_author: target_author.to_string(),
                emoji: emoji.to_string(),
                remove,
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

async fn send_reaction_inner(
    manager: &mut StoredManager,
    thread: &str,
    target_sts: u64,
    target_author: &str,
    emoji: &str,
    remove: bool,
) -> Result<u64, String> {
    use presage::libsignal_service::content::Reaction;
    let reaction = Reaction {
        emoji: Some(emoji.to_string()),
        remove: Some(remove),
        target_author_aci: Some(target_author.to_string()),
        target_sent_timestamp: Some(target_sts),
        ..Default::default()
    };
    let ts = {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
    };
    let msg = presage::libsignal_service::content::DataMessage {
        reaction: Some(reaction),
        timestamp: Some(ts),
        ..Default::default()
    };
    let content_body: presage::libsignal_service::content::ContentBody = msg.into();
    if let Some(hexkey) = thread.strip_prefix("group:") {
        let bytes = hex::decode(hexkey).map_err(|_| "bad group id".to_string())?;
        manager
            .send_message_to_group(&bytes, content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else if let Some(uuid) = thread.strip_prefix("contact:") {
        let bare = uuid.strip_prefix("PNI:").unwrap_or(uuid);
        let parsed: uuid::Uuid = bare.parse().map_err(|_| "bad contact id".to_string())?;
        manager
            .send_message(
                presage::libsignal_service::protocol::ServiceId::Aci(
                    presage::libsignal_service::protocol::Aci::from(parsed),
                ),
                content_body,
                ts,
            )
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else {
        Err("bad thread id".to_string())
    }
}

/// Profile display-name lookup (network). Errors when no profile key exists.
async fn cmd_profile(state: &mut WorkerState, uuid: &str) -> Result<String, String> {
    match state {
        WorkerState::Linked(linked) => {
            if let Some(manager) = linked.manager.as_mut() {
                sync::profile_name(manager, uuid).await
            } else if let Some(ctrl) = linked.ctrl.as_ref() {
                let (tx, rx) = tokio::sync::oneshot::channel();
                ctrl.send(LoopCtrl::Profile { uuid: uuid.to_string(), reply: tx })
                    .map_err(|_| "sync loop is gone".to_string())?;
                rx.await.map_err(|_| "sync loop dropped reply".to_string())?
            } else {
                Err("sync loop not running".to_string())
            }
        }
        _ => Err("not linked".to_string()),
    }
}

/// Local-only delete of one message (store tombstone, no network).
async fn cmd_delete_local(state: &WorkerState, thread_id: &str, sts: u64) -> Result<bool, String> {
    match state {
        WorkerState::Linked(linked) => {
            let mut store = linked.open_store().await?;
            let thread = sync::parse_thread(thread_id)?;
            {
                use presage::store::ContentsStore;
                store
                    .delete_message(&thread, sts)
                    .await
                    .map_err(|e| format!("delete: {e}"))
            }
        }
        _ => Err("not linked".to_string()),
    }
}

/// Send a read/delivery receipt for the given message timestamps.
async fn cmd_send_receipt(
    state: &mut WorkerState,
    thread: &str,
    timestamps: Vec<u64>,
    kind: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendReceipt {
                thread: thread.to_string(),
                timestamps,
                kind: kind.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

/// M2: Group management handlers
/// Get group info by master key hex
async fn cmd_get_group_info(
    state: &mut WorkerState,
    master_key_hex: &str,
) -> Result<String, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::get_group_info(manager, master_key_hex).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Update group title
async fn cmd_update_group_title(
    state: &mut WorkerState,
    master_key_hex: &str,
    title: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::update_group_title(manager, master_key_hex, title).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Update group avatar
async fn cmd_update_group_avatar(
    state: &mut WorkerState,
    master_key_hex: &str,
    avatar_data: &[u8],
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::update_group_avatar(manager, master_key_hex, avatar_data).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Add members to group
async fn cmd_add_group_members(
    state: &mut WorkerState,
    master_key_hex: &str,
    member_acis: &[String],
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::add_group_members(manager, master_key_hex, member_acis).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Remove members from group
async fn cmd_remove_group_members(
    state: &mut WorkerState,
    master_key_hex: &str,
    member_acis: &[String],
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::remove_group_members(manager, master_key_hex, member_acis).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Promote member to admin
async fn cmd_promote_group_member(
    state: &mut WorkerState,
    master_key_hex: &str,
    member_aci: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::promote_group_member(manager, master_key_hex, member_aci).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Demote member from admin
async fn cmd_demote_group_member(
    state: &mut WorkerState,
    master_key_hex: &str,
    member_aci: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::demote_group_member(manager, master_key_hex, member_aci).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Get group invite link
async fn cmd_get_group_invite_link(
    state: &mut WorkerState,
    master_key_hex: &str,
) -> Result<String, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::get_group_invite_link(manager, master_key_hex).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Revoke group invite link
async fn cmd_revoke_group_invite_link(
    state: &mut WorkerState,
    master_key_hex: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::revoke_group_invite_link(manager, master_key_hex).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Leave group
async fn cmd_leave_group(
    state: &mut WorkerState,
    master_key_hex: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let manager = linked.manager.as_mut().ok_or_else(|| "manager not available".to_string())?;
            groups::leave_group(manager, master_key_hex).await
        }
        _ => Err("not linked".to_string()),
    }
}

/// Send a call offer (SDP) via the sync loop.
async fn cmd_send_call_offer(
    state: &mut WorkerState,
    call_id: &str,
    to: &str,
    media_type: &str,
    sdp: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendCallOffer {
                call_id: call_id.to_string(),
                to: to.to_string(),
                media_type: media_type.to_string(),
                sdp: sdp.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

/// Send a call answer (SDP) via the sync loop.
async fn cmd_send_call_answer(
    state: &mut WorkerState,
    call_id: &str,
    sdp: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendCallAnswer {
                call_id: call_id.to_string(),
                sdp: sdp.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

/// Send a call ICE candidate via the sync loop.
async fn cmd_send_call_ice(
    state: &mut WorkerState,
    call_id: &str,
    candidate: &str,
    sdp_mid: &str,
    sdp_m_line_index: u32,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendCallIceCandidate {
                call_id: call_id.to_string(),
                candidate: candidate.to_string(),
                sdp_mid: sdp_mid.to_string(),
                sdp_m_line_index,
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

/// Send a call hangup via the sync loop.
async fn cmd_send_call_hangup(
    state: &mut WorkerState,
    call_id: &str,
    reason: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::SendCallHangup {
                call_id: call_id.to_string(),
                reason: reason.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

/// On-demand attachment fetch (metadata-only roster rows).
async fn cmd_fetch_attachment(
    state: &mut WorkerState,
    thread_id: &str,
    ts: u64,
    index: usize,
) -> Result<String, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            ctrl.send(LoopCtrl::FetchAttachment {
                thread_id: thread_id.to_string(),
                ts,
                index,
                reply: tx,
            })
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

/// Older history page: newest `limit` messages in `thread` before
/// `before_ts` (`u64::MAX` = latest). JSON `{"messages":[…]}`, or null.
#[no_mangle]
pub extern "C" fn core_cmd_thread(thread: *const c_char, limit: u64, before_ts: u64) -> *mut c_char {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => {
            set_last_error(e);
            return std::ptr::null_mut();
        }
    };
    let limit = (limit.max(1).min(500)) as usize;
    match roundtrip(|reply| Command::ThreadPage { thread_id: t, limit, before_ts, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Download attachment `index` of the message at `ts` (ms) in `thread`.
/// Returns the local file path, or null (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_fetch_attachment(thread: *const c_char, ts: u64, index: u64) -> *mut c_char {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => {
            set_last_error(e);
            return std::ptr::null_mut();
        }
    };
    match roundtrip(|reply| Command::FetchAttachment { thread_id: t, ts, index: index as usize, reply }) {
        Ok(Ok(path)) => ok_string(path),
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

fn roundtrip_ts<F>(build: F) -> i64
where
    F: FnOnce(tokio::sync::oneshot::Sender<Result<u64, String>>) -> Command,
{
    match roundtrip(build) {
        Ok(Ok(ts)) => ts as i64,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Send a local file as attachment (`caption` = message body). Returns sent
/// ts, or -1 (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_send_attachment(
    thread: *const c_char,
    path: *const c_char,
    caption: *const c_char,
) -> i64 {
    let (t, p, c) = match (c_str_arg(thread, "thread"), c_str_arg(path, "path"), c_str_arg(caption, "caption")) {
        (Ok(t), Ok(p), Ok(c)) => (t, p, c),
        _ => {
            set_last_error("thread/path/caption: null or invalid UTF-8".to_string());
            return -1;
        }
    };
    roundtrip_ts(|reply| Command::SendAttachment { thread: t, path: p, caption: c, reply })
}

/// Reply with `body`, quoting (`q_ts`, `q_author`, `q_body`). Returns sent ts.
#[no_mangle]
pub extern "C" fn core_cmd_send_reply(
    thread: *const c_char,
    body: *const c_char,
    q_ts: u64,
    q_author: *const c_char,
    q_body: *const c_char,
) -> i64 {
    let parts = (
        c_str_arg(thread, "thread"),
        c_str_arg(body, "body"),
        c_str_arg(q_author, "q_author"),
        c_str_arg(q_body, "q_body"),
    );
    match parts {
        (Ok(t), Ok(b), Ok(qa), Ok(qb)) => roundtrip_ts(|reply| Command::SendReply {
            thread: t, body: b, quote_ts: q_ts, quote_author: qa, quote_body: qb, reply,
        }),
        _ => {
            set_last_error("reply args: null or invalid UTF-8".to_string());
            -1
        }
    }
}

/// Delete-for-everyone tombstone for our message at `target_ts`.
/// Returns tombstone ts, or -1. Local removal is separate (`delete_local`).
#[no_mangle]
pub extern "C" fn core_cmd_send_delete(thread: *const c_char, target_ts: u64) -> i64 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    roundtrip_ts(|reply| Command::SendDelete { thread: t, target_ts, reply })
}

/// Toggle/add reaction `emoji` on the message at `target_sts` by
/// `target_author`. `remove` = 1 un-reacts. Returns sent ts, or -1.
#[no_mangle]
pub extern "C" fn core_cmd_send_reaction(
    thread: *const c_char,
    target_sts: u64,
    target_author: *const c_char,
    emoji: *const c_char,
    remove: i32,
) -> i64 {
    let parts = (c_str_arg(thread, "thread"), c_str_arg(target_author, "author"), c_str_arg(emoji, "emoji"));
    match parts {
        (Ok(t), Ok(a), Ok(e)) if !e.is_empty() => roundtrip_ts(|reply| Command::SendReaction {
            thread: t, target_sts, target_author: a, emoji: e, remove: remove != 0, reply,
        }),
        _ => {
            set_last_error("reaction args: null/empty".to_string());
            -1
        }
    }
}

/// Local-only delete of the message at store-clock `sts`. 1 deleted,
/// 0 absent, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_delete_local(thread: *const c_char, sts: u64) -> i32 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    match roundtrip(|reply| Command::DeleteLocal { thread_id: t, sts, reply }) {
        Ok(Ok(true)) => 1,
        Ok(Ok(false)) => 0,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Send a read/delivery receipt for the given timestamps (store clocks).
/// `kind` = "read" | "delivered". 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_receipt(
    thread: *const c_char,
    timestamps_ptr: *const u64,
    timestamps_len: usize,
    kind: *const c_char,
) -> i32 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    let k = match c_str_arg(kind, "kind") {
        Ok(k) => k,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    let timestamps = if timestamps_ptr.is_null() || timestamps_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(timestamps_ptr, timestamps_len).to_vec() }
    };
    match roundtrip(|reply| Command::SendReceipt { thread: t, timestamps, kind: k, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// M2: Group management FFI
/// Get group info by master key hex. Returns JSON string or null.
#[no_mangle]
pub extern "C" fn core_cmd_group_get_info(
    master_key_hex: *const c_char,
) -> *mut c_char {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };
    match roundtrip(|reply| Command::GetGroupInfo { master_key_hex: mk, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Update group title. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_update_title(
    master_key_hex: *const c_char,
    title: *const c_char,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let t = match c_str_arg(title, "title") {
        Ok(t) => t,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::UpdateGroupTitle { master_key_hex: mk, title: t, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Update group avatar. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_update_avatar(
    master_key_hex: *const c_char,
    avatar_data: *const u8,
    avatar_len: usize,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let avatar = if avatar_data.is_null() || avatar_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(avatar_data, avatar_len).to_vec() }
    };
    match roundtrip(|reply| Command::UpdateGroupAvatar { master_key_hex: mk, avatar_data: avatar, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Add members to group. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_add_members(
    master_key_hex: *const c_char,
    member_acis_ptr: *const *const c_char,
    member_acis_len: usize,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let mut member_acis = Vec::with_capacity(member_acis_len);
    if member_acis_ptr.is_null() || member_acis_len == 0 {
        set_last_error("member_acis: null or empty".to_string());
        return -1;
    }
    let slice = unsafe { std::slice::from_raw_parts(member_acis_ptr, member_acis_len) };
    for ptr in slice {
        let aci = match c_str_arg(*ptr, "member_aci") {
            Ok(a) => a,
            Err(e) => { set_last_error(e); return -1; }
        };
        member_acis.push(aci);
    }
    match roundtrip(|reply| Command::AddGroupMembers { master_key_hex: mk, member_acis, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Remove members from group. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_remove_members(
    master_key_hex: *const c_char,
    member_acis_ptr: *const *const c_char,
    member_acis_len: usize,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let mut member_acis = Vec::with_capacity(member_acis_len);
    if member_acis_ptr.is_null() || member_acis_len == 0 {
        set_last_error("member_acis: null or empty".to_string());
        return -1;
    }
    let slice = unsafe { std::slice::from_raw_parts(member_acis_ptr, member_acis_len) };
    for ptr in slice {
        let aci = match c_str_arg(*ptr, "member_aci") {
            Ok(a) => a,
            Err(e) => { set_last_error(e); return -1; }
        };
        member_acis.push(aci);
    }
    match roundtrip(|reply| Command::RemoveGroupMembers { master_key_hex: mk, member_acis, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Promote member to admin. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_promote_member(
    master_key_hex: *const c_char,
    member_aci: *const c_char,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let aci = match c_str_arg(member_aci, "member_aci") {
        Ok(a) => a,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::PromoteGroupMember { master_key_hex: mk, member_aci: aci, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Demote member from admin. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_demote_member(
    master_key_hex: *const c_char,
    member_aci: *const c_char,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let aci = match c_str_arg(member_aci, "member_aci") {
        Ok(a) => a,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::DemoteGroupMember { master_key_hex: mk, member_aci: aci, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Get group invite link. Returns JSON string or null.
#[no_mangle]
pub extern "C" fn core_cmd_group_get_invite_link(
    master_key_hex: *const c_char,
) -> *mut c_char {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };
    match roundtrip(|reply| Command::GetGroupInviteLink { master_key_hex: mk, reply }) {
        Ok(Ok(link)) => ok_string(link),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Revoke group invite link. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_revoke_invite_link(
    master_key_hex: *const c_char,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::RevokeGroupInviteLink { master_key_hex: mk, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Leave group. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_leave(
    master_key_hex: *const c_char,
) -> i32 {
    let mk = match c_str_arg(master_key_hex, "master_key_hex") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::LeaveGroup { master_key_hex: mk, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Send a call offer (SDP). 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_call_offer(
    call_id: *const c_char,
    to: *const c_char,
    media_type: *const c_char,
    sdp: *const c_char,
) -> i32 {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return -1; }
    };
    let t = match c_str_arg(to, "to") {
        Ok(t) => t,
        Err(e) => { set_last_error(e); return -1; }
    };
    let mt = match c_str_arg(media_type, "media_type") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    let s = match c_str_arg(sdp, "sdp") {
        Ok(s) => s,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendCallOffer { call_id: cid, to: t, media_type: mt, sdp: s, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Send a call answer (SDP). 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_call_answer(
    call_id: *const c_char,
    sdp: *const c_char,
) -> i32 {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return -1; }
    };
    let s = match c_str_arg(sdp, "sdp") {
        Ok(s) => s,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendCallAnswer { call_id: cid, sdp: s, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Send an ICE candidate. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_call_ice(
    call_id: *const c_char,
    candidate: *const c_char,
    sdp_mid: *const c_char,
    sdp_m_line_index: u32,
) -> i32 {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return -1; }
    };
    let cand = match c_str_arg(candidate, "candidate") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return -1; }
    };
    let mid = match c_str_arg(sdp_mid, "sdp_mid") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendCallIceCandidate { call_id: cid, candidate: cand, sdp_mid: mid, sdp_m_line_index, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Send a call hangup. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_call_hangup(
    call_id: *const c_char,
    reason: *const c_char,
) -> i32 {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return -1; }
    };
    let r = match c_str_arg(reason, "reason") {
        Ok(r) => r,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendCallHangup { call_id: cid, reason: r, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Profile display name for a contact uuid, or null (no key / no name).
#[no_mangle]
pub extern "C" fn core_cmd_profile(uuid: *const c_char) -> *mut c_char {
    let u = match c_str_arg(uuid, "uuid") {
        Ok(u) => u,
        Err(e) => {
            set_last_error(e);
            return std::ptr::null_mut();
        }
    };
    match roundtrip(|reply| Command::Profile { uuid: u, reply }) {
        Ok(Ok(name)) => ok_string(name),
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
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
