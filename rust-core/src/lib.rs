//! Cuztom Signal Rust core — M1: linked-device provisioning + persistence.
//!
//! Threading model: presage futures use `tokio::spawn_local`, so they are
//! `!Send`. All presage work runs on ONE dedicated worker thread driving a
//! `current_thread` runtime + `LocalSet`. Swift talks to it via a C ABI that
//! posts commands over a channel and blocks on the reply.
//!
//! C ABI (Swift `RustCoreService` resolves these with `dlsym`):
//!   `core_abi_version() -> u32`          ABI gate before symbol use
//!   `core_cmd_init_encrypted(db_path, passphrase) -> i32`  1 linked, 0 fresh, -1 error
//!   `core_cmd_begin_link(name) -> *mut c_char`  provisioning URL (free with
//!                                        `core_free_string`), null on error
//!   `core_cmd_poll_link() -> i32`        1 linked, 0 pending, -1 failed
//!   `core_cmd_is_linked() -> i32`        1 / 0
//!   `core_last_error() -> *const c_char` copy immediately, valid until next call
//!   `core_free_string(*mut c_char)`
//!   `core_cmd_wipe() -> i32` acknowledged native session/database wipe
//!
//! M1b (next): receive loop + send + contacts/groups sync over the same pipe.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex, OnceLock};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use base64::Engine as _;

use presage::libsignal_service::configuration::SignalServers;
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

mod encrypted_store;

mod call;

pub mod group_calls;

use libsignal_service::proto::CallMessage as ProtoCallMessage;

enum Command {
    Init {
        db_path: String,
        passphrase: String,
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
    // Call signaling integration (new)
    SendCallSignal {
        thread: String,
        call_message_json: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    BuildCallOffer {
        call_id: String,
        media_type: String,
        opaque: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    BuildCallAnswer {
        call_id: String,
        opaque: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    BuildCallIce {
        call_id: String,
        opaque: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    BuildCallHangup {
        call_id: String,
        hangup_type: u32,
        device_id: u32,
        reply: oneshot::Sender<Result<String, String>>,
    },
    BuildCallBusy {
        call_id: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    ParseCallMessage {
        call_message_json: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    CallEndReasonToString {
        reason: i32,
        reply: oneshot::Sender<Result<String, String>>,
    },
    CallStart {
        thread: String,
        media_type: String,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    CallAccept {
        call_id: u64,
        reply: oneshot::Sender<Result<(), String>>,
    },
    CallHangup {
        reply: oneshot::Sender<Result<(), String>>,
    },
    CallSetMuted {
        muted: bool,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// Deliver an SFU HTTP response that the host performed on RingRTC's
    /// behalf. `status` of `None` reports a transport failure.
    HttpResponse {
        request_id: u32,
        status: Option<u16>,
        body: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// Fetch ZK group auth credentials for the current day, as raw JSON.
    GroupAuthCredentials {
        reply: oneshot::Sender<Result<String, String>>,
    },
    /// Build the CDN authorization for a group call membership proof.
    ///
    /// Takes the 32-byte ZK group identifier RingRTC asks about and returns the
    /// `hex(groupPublicParams):hex(presentation)` value the CDN redeems. The
    /// credential fetch and the presentation both happen in one step because the
    /// ZK server public params are only reachable from the live manager.
    GroupCallProofAuthorization {
        group_id: Vec<u8>,
        reply: oneshot::Sender<Result<String, String>>,
    },
    /// Hand a group-call membership proof to RingRTC, unblocking the SFU join.
    GroupCallSetMembershipProof {
        client_id: u32,
        token: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// Supply the member identities the SFU needs to attribute call traffic.
    /// Encrypted ids are variable length, so an explicit length per entry is
    /// sent rather than a fixed stride.
    GroupCallSetGroupMembers {
        client_id: u32,
        count: u32,
        user_ids: Vec<u8>,
        member_lens: Vec<u32>,
        member_ids: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// Create a group call client and connect it, returning its RingRTC id
    /// (offset by one, so zero means failure).
    GroupCallStart {
        group_id: Vec<u8>,
        sfu_url: Option<String>,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    GroupCallJoin {
        client_id: u32,
        reply: oneshot::Sender<Result<(), String>>,
    },
    GroupCallLeave {
        client_id: u32,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// Leave if needed, then delete the client and forget it.
    GroupCallEnd {
        client_id: u32,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Logout {
        reply: oneshot::Sender<Result<(), String>>,
    },
    Wipe {
        reply: oneshot::Sender<Result<(), String>>,
    },
    // M3: Message edits
    SendMessageEdit {
        thread: String,
        target_ts: u64,
        new_body: String,
        reply: oneshot::Sender<Result<u64, String>>,
    },
    // M3: Typing indicators
    SendTyping {
        thread: String,
        started: bool,
        reply: oneshot::Sender<Result<(), String>>,
    },
}

/// Control plane into the running sync loop (which owns `&mut Manager`).
enum LoopCtrl {
    Shutdown {
        reply: tokio::sync::oneshot::Sender<()>,
    },
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
    // M3: Message edits
    SendMessageEdit {
        thread: String,
        target_ts: u64,
        new_body: String,
        reply: tokio::sync::oneshot::Sender<Result<u64, String>>,
    },
    // M3: Typing indicators
    SendTyping {
        thread: String,
        started: bool,
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
    /// Fetch ZK group auth credentials, as raw JSON. Issued through the loop
    /// because it is the loop that owns the live manager.
    GroupAuthCredentials {
        start_day: u64,
        end_day: u64,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    /// Fetch and present a ZK group auth credential for one group.
    ///
    /// The loop is the only place that can do this: the credential request is
    /// authenticated, and the server public params the presentation verifies
    /// against come from the same live service configuration.
    GroupCallProofAuthorization {
        group_id: Vec<u8>,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    // Call signaling integration
    SendCallSignal {
        thread: String,
        call_message_json: String,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    // Legacy internal call-message helpers retained for binary/source
    // compatibility with older callers. Native calls use TransmitCallSignal.
    BuildCallOffer {
        call_id: String,
        media_type: String,
        opaque: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    BuildCallAnswer {
        call_id: String,
        opaque: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    BuildCallIce {
        call_id: String,
        opaque: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    BuildCallHangup {
        call_id: String,
        hangup_type: u32,
        device_id: u32,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    BuildCallBusy {
        call_id: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    ParseCallMessage {
        call_message_json: String,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    CallEndReasonToString {
        reason: i32,
        reply: tokio::sync::oneshot::Sender<Result<String, String>>,
    },
    /// Internal bridge messages produced by the native RingRTC platform.
    TransmitCallSignal {
        pending: call::PendingCallSignal,
    },
    CallAction {
        action: call::CallAction,
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
    Linking {
        task: tokio::task::JoinHandle<Result<StoredManager, String>>,
        store: SqliteStore,
        db_path: String,
    },
    Linked(Box<LinkedState>),
}

struct LinkedState {
    db_path: String,
    /// Keep the encrypted store alive so all later offline/reconnect paths do
    /// not retain or reopen the raw passphrase.
    store: SqliteStore,
    /// Live manager handle. `None` once the sync loop owns it.
    manager: Option<StoredManager>,
    /// Control plane into the sync loop, if running.
    ctrl: Option<tmpsc::Sender<LoopCtrl>>,
    /// Drained by `core_cmd_poll_event` (null = empty, not an error).
    events: Option<std::sync::mpsc::Receiver<String>>,
    /// False after the websocket receive task exits; allows a later
    /// `start_sync` to reload the manager instead of treating it as live.
    sync_alive: Arc<AtomicBool>,
}

impl LinkedState {
    fn new(db_path: String, store: SqliteStore, manager: StoredManager) -> Self {
        Self {
            db_path,
            store,
            manager: Some(manager),
            ctrl: None,
            events: None,
            sync_alive: Arc::new(AtomicBool::new(false)),
        }
    }

    async fn open_store(&self) -> Result<SqliteStore, String> {
        Ok(self.store.clone())
    }
}

struct Core {
    cmd_tx: tmpsc::Sender<Command>,
}

static CORE: OnceLock<Core> = OnceLock::new();
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
static ACTIVE_DB_PATH: Mutex<Option<String>> = Mutex::new(None);

/// The current sync-loop control sender. RingRTC's bridge is started once
/// and survives logout/re-login; it waits while this slot is empty.
const SYNC_CTRL_CAPACITY: usize = 128;
static SYNC_CTRL: OnceLock<Mutex<Option<tmpsc::Sender<LoopCtrl>>>> = OnceLock::new();
static CALL_BRIDGE_STARTED: OnceLock<()> = OnceLock::new();
static SYNC_GENERATION: AtomicU64 = AtomicU64::new(0);

fn send_sync_ctrl(sender: &tmpsc::Sender<LoopCtrl>, message: LoopCtrl) -> Result<(), String> {
    sender.try_send(message).map_err(|error| match error {
        tmpsc::error::TrySendError::Full(_) => "sync control queue is full".to_string(),
        tmpsc::error::TrySendError::Closed(_) => "sync loop is gone".to_string(),
    })
}

async fn send_sync_ctrl_wait(
    sender: &tmpsc::Sender<LoopCtrl>,
    message: LoopCtrl,
) -> Result<(), String> {
    let permit = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        sender.reserve(),
    )
    .await
    .map_err(|_| "sync control queue shutdown timed out".to_string())?
    .map_err(|_| "sync loop is gone".to_string())?;
    permit.send(message);
    Ok(())
}

fn set_sync_ctrl(sender: Option<tmpsc::Sender<LoopCtrl>>) {
    if let Ok(mut slot) = SYNC_CTRL
        .get_or_init(|| Mutex::new(None))
        .lock()
    {
        *slot = sender;
    }
}

fn current_sync_ctrl() -> Option<tmpsc::Sender<LoopCtrl>> {
    SYNC_CTRL
        .get()
        .and_then(|slot| slot.lock().ok().and_then(|value| value.clone()))
}

fn set_last_error(msg: String) {
    if let Ok(mut slot) = LAST_ERROR.lock() {
        *slot = msg;
    }
}

fn core_handle() -> Result<&'static Core, String> {
    CORE.get()
        .ok_or_else(|| "core not initialized (call core_cmd_init_encrypted first)".to_string())
}

/// Blocking request/response round-trip from any (non-Tokio) thread.
fn roundtrip<T, F>(build: F) -> Result<T, String>
where
    F: FnOnce(oneshot::Sender<T>) -> Command,
{
    let core = core_handle()?;
    let (tx, rx) = oneshot::channel();
    core.cmd_tx
        .try_send(build(tx))
        .map_err(|error| match error {
            tmpsc::error::TrySendError::Full(_) => "core command queue is full".to_string(),
            tmpsc::error::TrySendError::Closed(_) => "core worker is gone".to_string(),
        })?;
    rx.blocking_recv()
        .map_err(|_| "core worker dropped the reply".to_string())
}

fn spawn_worker() -> tmpsc::Sender<Command> {
    let (tx, mut cmd_rx) = tmpsc::channel::<Command>(256);
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
                        Command::Init { db_path, passphrase, reply } => {
                            let result = init_state(&mut state, &db_path, &passphrase).await;
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
                                    .and_then(|rx| rx.try_recv().ok())
                                    .or_else(call::try_event),
                                _ => call::try_event(),
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
                        // M3: Message edits
                        Command::SendMessageEdit { thread, target_ts, new_body, reply } => {
                            let result = cmd_send_message_edit(&mut state, &thread, target_ts, &new_body).await;
                            let _ = reply.send(result);
                        }
                        // M3: Typing indicators
                        Command::SendTyping { thread, started, reply } => {
                            let result = cmd_send_typing(&mut state, &thread, started).await;
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
                        // Call signaling integration
                        Command::SendCallSignal { thread, call_message_json, reply } => {
                            let result = cmd_send_call_signal(&mut state, &thread, &call_message_json).await;
                            let _ = reply.send(result);
                        }
                        Command::BuildCallOffer { call_id, media_type, opaque, reply } => {
                            let result = cmd_build_call_offer(&call_id, &media_type, &opaque).await;
                            let _ = reply.send(result);
                        }
                        Command::BuildCallAnswer { call_id, opaque, reply } => {
                            let result = cmd_build_call_answer(&call_id, &opaque).await;
                            let _ = reply.send(result);
                        }
                        Command::BuildCallIce { call_id, opaque, reply } => {
                            let result = cmd_build_call_ice(&call_id, &opaque).await;
                            let _ = reply.send(result);
                        }
                        Command::BuildCallHangup { call_id, hangup_type, device_id, reply } => {
                            let result = cmd_build_call_hangup(&call_id, hangup_type, device_id).await;
                            let _ = reply.send(result);
                        }
                        Command::BuildCallBusy { call_id, reply } => {
                            let result = cmd_build_call_busy(&call_id).await;
                            let _ = reply.send(result);
                        }
                        Command::ParseCallMessage { call_message_json, reply } => {
                            let result = cmd_parse_call_message(&call_message_json).await;
                            let _ = reply.send(result);
                        }
                        Command::CallEndReasonToString { reason, reply } => {
                            let result = cmd_call_end_reason_to_string(reason).await;
                            let _ = reply.send(result);
                        }
                        Command::CallStart { thread, media_type, reply } => {
                            let result = cmd_call_start(&mut state, &thread, &media_type).await;
                            let _ = reply.send(result);
                        }
                        Command::CallAccept { call_id, reply } => {
                            let result = cmd_call_accept(&mut state, call_id).await;
                            let _ = reply.send(result);
                        }
                        Command::CallHangup { reply } => {
                            let result = cmd_call_hangup(&mut state).await;
                            let _ = reply.send(result);
                        }
                        Command::CallSetMuted { muted, reply } => {
                            let result = cmd_call_set_muted(&mut state, muted);
                            let _ = reply.send(result);
                        }
                        Command::HttpResponse { request_id, status, body, reply } => {
                            let result = cmd_http_response(&state, request_id, status, body);
                            let _ = reply.send(result);
                        }
                        Command::GroupAuthCredentials { reply } => {
                            let result = cmd_group_auth_credentials(&state).await;
                            let _ = reply.send(result);
                        }
                        Command::GroupCallProofAuthorization { group_id, reply } => {
                            let result = cmd_group_call_proof_authorization(&state, &group_id).await;
                            let _ = reply.send(result);
                        }
                        Command::GroupCallSetMembershipProof { client_id, token, reply } => {
                            let result = call::set_group_membership_proof(client_id, token);
                            let _ = reply.send(result);
                        }
                        Command::GroupCallStart { group_id, sfu_url, reply } => {
                            let result = match call::start_group_call(group_id, sfu_url) {
                                Ok(client_id) => Ok(u64::from(client_id) + 1),
                                Err(e) => Err(e),
                            };
                            let _ = reply.send(result);
                        }
                        Command::GroupCallJoin { client_id, reply } => {
                            let result = call::join_group_call(client_id);
                            let _ = reply.send(result);
                        }
                        Command::GroupCallLeave { client_id, reply } => {
                            let result = call::leave_group_call(client_id);
                            let _ = reply.send(result);
                        }
                        Command::GroupCallEnd { client_id, reply } => {
                            let result = call::end_group_call(client_id);
                            let _ = reply.send(result);
                        }
                        Command::GroupCallSetGroupMembers {
                            client_id,
                            count,
                            user_ids,
                            member_lens,
                            member_ids,
                            reply,
                        } => {
                            let result = call::set_group_members(
                                client_id,
                                count,
                                user_ids,
                                member_lens,
                                member_ids,
                            );
                            let _ = reply.send(result);
                        }
                        Command::Logout { reply } => {
                            let result = cmd_logout(&mut state).await;
                            let _ = reply.send(result);
                        }
                        Command::Wipe { reply } => {
                            let result = cmd_wipe(&mut state).await;
                            let _ = reply.send(result);
                        }
                    }
                }
            });
        })
        .expect("core worker thread");
    tx
}

fn set_active_db_path(path: &str) {
    if let Ok(mut slot) = ACTIVE_DB_PATH.lock() {
        *slot = Some(path.to_string());
    }
}

fn same_db_path(left: &str, right: &str) -> bool {
    let normalize = |path: &str| {
        std::fs::canonicalize(path).unwrap_or_else(|_| std::path::PathBuf::from(path))
    };
    normalize(left) == normalize(right)
}

async fn init_state(
    state: &mut WorkerState,
    db_path: &str,
    passphrase: &str,
) -> Result<bool, String> {
    match state {
        WorkerState::Linked(linked) if same_db_path(&linked.db_path, db_path) => {
            return Ok(true);
        }
        WorkerState::Ready { db_path: existing, .. }
        | WorkerState::Linking { db_path: existing, .. }
            if same_db_path(existing, db_path) =>
        {
            return Ok(false);
        }
        WorkerState::Linked(linked) => {
            return Err(format!(
                "native core already owns database: {}",
                linked.db_path
            ));
        }
        WorkerState::Ready { db_path: existing, .. }
        | WorkerState::Linking { db_path: existing, .. } => {
            return Err(format!(
                "native core already owns database: {}",
                existing
            ));
        }
        WorkerState::Fresh => {}
    }
    if let Some(parent) = std::path::Path::new(db_path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| format!("db dir: {e}"))?;
        }
    }
    let store = encrypted_store::open_encrypted(db_path, passphrase).await?;
    match Manager::load_registered(store.clone()).await {
        Ok(manager) => {
            set_active_db_path(db_path);
            *state = WorkerState::Linked(Box::new(LinkedState::new(
                db_path.to_string(),
                store,
                manager,
            )));
            Ok(true)
        }
        Err(presage::Error::NotYetRegisteredError) => {
            set_active_db_path(db_path);
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
            return Err("no store: call core_cmd_init_encrypted first".to_string());
        }
        WorkerState::Linking { task, store, db_path } => {
            *state = WorkerState::Linking { task, store, db_path };
            return Err("link already in progress".to_string());
        }
        WorkerState::Linked(linked) => {
            *state = WorkerState::Linked(linked);
            return Err("already linked".to_string());
        }
    };

    let (url_tx, url_rx) = futures::channel::oneshot::channel();
    let name = device_name.to_string();
    let link_store = store.clone();
    let task = tokio::task::spawn_local(async move {
        Manager::link_secondary_device(link_store, SignalServers::Production, name, url_tx)
            .await
            .map_err(|e| format!("link: {e}"))
    });
    *state = WorkerState::Linking { task, store, db_path };

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
    let (task, store, db_path) = match std::mem::replace(state, WorkerState::Fresh) {
        WorkerState::Linking { task, store, db_path } => (task, store, db_path),
        other => {
            let linked = matches!(other, WorkerState::Linked(_));
            *state = other;
            return if linked { PollLink::Linked } else { PollLink::Pending };
        }
    };
    if !task.is_finished() {
        *state = WorkerState::Linking { task, store, db_path };
        return PollLink::Pending;
    }
    match task.await {
        Ok(Ok(manager)) => {
            *state = WorkerState::Linked(Box::new(LinkedState::new(db_path, store, manager)));
            PollLink::Linked
        }
        Ok(Err(e)) => {
            *state = WorkerState::Ready { store, db_path };
            PollLink::Failed(e)
        }
        Err(join) => {
            *state = WorkerState::Ready { store, db_path };
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
                send_sync_ctrl(ctrl, LoopCtrl::RequestContacts { reply: tx })
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
    if linked.ctrl.is_some() && linked.sync_alive.load(Ordering::Acquire) {
        return Ok(());
    }
    if let Some(old_ctrl) = linked.ctrl.take() {
        set_sync_ctrl(None);
        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
        match send_sync_ctrl_wait(
            &old_ctrl,
            LoopCtrl::Shutdown { reply: shutdown_tx },
        )
        .await
        {
            Ok(()) => {
                let _ = shutdown_rx.await;
            }
            Err(error) => {
                set_sync_ctrl(Some(old_ctrl.clone()));
                linked.ctrl = Some(old_ctrl);
                return Err(error);
            }
        }
    }
    linked.events = None;
    linked.sync_alive.store(false, Ordering::Release);
    let store = linked.store.clone();
    let reg = store
        .load_registration_data()
        .await
        .map_err(|e| format!("registration: {e}"))?
        .ok_or_else(|| "not linked".to_string())?;
    let mut manager = match linked.manager.take() {
        Some(manager) => manager,
        None => Manager::load_registered(store.clone())
            .await
            .map_err(|e| format!("reload manager: {e}"))?,
    };
    let names_store = manager.store().clone();
    let self_aci = reg.service_ids.aci.to_string();
    call::set_local_device_id(reg.device_id.unwrap_or(1));
    call::init_calls().map_err(|e| format!("initialize calls: {e}"))?;
    call::set_self_uuid(&self_aci);

    let sync_alive = Arc::clone(&linked.sync_alive);
    let sync_generation = SYNC_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
    sync_alive.store(true, Ordering::Release);
    let (event_tx, event_rx) = std::sync::mpsc::channel::<String>();
    let (ctrl_tx, mut ctrl_rx) = tmpsc::channel::<LoopCtrl>(SYNC_CTRL_CAPACITY);

    // RingRTC callbacks run on a separate native worker. Keep one bridge
    // task for the process lifetime; it drops work while logged out and
    // forwards to the current sync loop after re-linking.
    set_sync_ctrl(Some(ctrl_tx.clone()));
    CALL_BRIDGE_STARTED.get_or_init(|| {
        if let Some(mut signal_rx) = call::take_signal_rx() {
            tokio::task::spawn_local(async move {
                while let Some(pending) = signal_rx.recv().await {
                    // A message queued during logout belongs to the old
                    // account. Drop it while the current control loop is
                    // absent rather than forwarding it after re-linking.
                    if pending.session_generation() != call::session_generation() {
                        if let Some(call_id) = pending.call_id() {
                            call::call_message_send_failure(call_id);
                        }
                        continue;
                    }
                    if let Some(sender) = current_sync_ctrl() {
                        // Group signaling has no 1:1 call id to report a
                        // failure against, so only a contact signal can be
                        // failed back into RingRTC.
                        let call_id = pending.call_id();
                        if send_sync_ctrl(&sender, LoopCtrl::TransmitCallSignal { pending }).is_err()
                        {
                            if let Some(call_id) = call_id {
                                call::call_message_send_failure(call_id);
                            }
                        }
                    } else if let Some(call_id) = pending.call_id() {
                        call::call_message_send_failure(call_id);
                    }
                }
            });
        }
        if let Some(mut action_rx) = call::take_action_rx() {
            tokio::task::spawn_local(async move {
                while let Some(action) = action_rx.recv().await {
                    // Do not carry a deferred `proceed` into a new session.
                    let action_generation = match &action {
                        call::CallAction::Proceed {
                            session_generation,
                            ..
                        } => *session_generation,
                    };
                    if action_generation != call::session_generation() {
                        continue;
                    }
                    if let Some(sender) = current_sync_ctrl() {
                        if send_sync_ctrl(&sender, LoopCtrl::CallAction { action }).is_err() {
                            call::drop_active_call();
                        }
                    } else {
                        call::drop_active_call();
                    }
                }
            });
        }
    });

    tokio::task::spawn_local(async move {
        use futures::StreamExt;
        let mut names = sync::load_names(&names_store).await;
        let mut shutdown_reply = None;
        let send_listen = async {
            match manager.receive_messages().await {
                Ok(stream) => {
                    let mut stream = Box::pin(stream);
                    loop {
                        tokio::select! {
                            biased;
                            ctrl = ctrl_rx.recv() => match ctrl {
                                Some(LoopCtrl::Shutdown { reply }) => {
                                    shutdown_reply = Some(reply);
                                    break;
                                }
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
                                    let r = match sync::make_quote(quote_ts, &quote_author, &quote_body) {
                                        Ok(quote) => sync::do_send_full(
                                            &mut manager,
                                            &thread,
                                            &body,
                                            Vec::new(),
                                            sync::SendExtras { quote: Some(quote), delete_ts: None },
                                        )
                                        .await,
                                        Err(e) => Err(e),
                                    };
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
                                // M3: Message edits
                                Some(LoopCtrl::SendMessageEdit { thread, target_ts, new_body, reply }) => {
                                    let r = sync::send_message_edit(&mut manager, &thread, target_ts, &new_body).await;
                                    let _ = reply.send(r);
                                }
                                // M3: Typing indicators
                                Some(LoopCtrl::SendTyping { thread, started, reply }) => {
                                    let r = sync::send_typing(&mut manager, &thread, started).await;
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
                                Some(LoopCtrl::GroupAuthCredentials { start_day, end_day, reply }) => {
                                    // The loop owns the live manager, so the
                                    // authenticated credential request has to
                                    // happen here.
                                    let r = manager
                                        .group_auth_credentials_raw(start_day, end_day)
                                        .await
                                        .map(|(body, _server_params)| body)
                                        .map_err(|e| e.to_string());
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::GroupCallProofAuthorization { group_id, reply }) => {
                                    let r = call::prepare_group_call_proof(&mut manager, &group_id, &self_aci)
                                        .await
                                        .map_err(|e| e.to_string());
                                    let _ = reply.send(r);
                                }
                                // Call signaling integration
                                Some(LoopCtrl::SendCallSignal { thread, call_message_json, reply }) => {
                                    let r = crate::call::send_call_signal(&mut manager, &thread, &call_message_json).await;
                                    let _ = reply.send(r.map_err(|e| e.to_string()));
                                }
                                Some(LoopCtrl::BuildCallOffer { call_id, media_type, opaque, reply }) => {
                                    let r = cmd_build_call_offer(&call_id, &media_type, &opaque).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::BuildCallAnswer { call_id, opaque, reply }) => {
                                    let r = cmd_build_call_answer(&call_id, &opaque).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::BuildCallIce { call_id, opaque, reply }) => {
                                    let r = cmd_build_call_ice(&call_id, &opaque).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::BuildCallHangup { call_id, hangup_type, device_id, reply }) => {
                                    let r = cmd_build_call_hangup(&call_id, hangup_type, device_id).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::BuildCallBusy { call_id, reply }) => {
                                    let r = cmd_build_call_busy(&call_id).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::ParseCallMessage { call_message_json, reply }) => {
                                    let r = cmd_parse_call_message(&call_message_json).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::CallEndReasonToString { reason, reply }) => {
                                    let r = cmd_call_end_reason_to_string(reason).await;
                                    let _ = reply.send(r);
                                }
                                Some(LoopCtrl::TransmitCallSignal { pending }) => {
                                    // Group signals have no 1:1 call to report
                                    // a send result against, so the callback is
                                    // only invoked for contact signals.
                                    let id = pending.call_id();
                                    match call::transmit(&mut manager, pending).await {
                                        Ok(()) => {
                                            if let Some(id) = id {
                                                call::call_message_sent(id);
                                            }
                                        }
                                        Err(error) => {
                                            if let Some(id) = id {
                                                eprintln!(
                                                    "[core] call signaling send failed: {error}"
                                                );
                                                call::call_message_send_failure(id);
                                            }
                                        }
                                    }
                                }
                                Some(LoopCtrl::CallAction { action }) => {
                                    call::call_action(action);
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
                                    // Reactions, receipts, edits, deletes, typing,
                                    // and calls travel as message envelopes; emit
                                    // them as events, never as chat rows.
                                    if let Some(rv) = sync::receipt_part_scoped(
                                        &store,
                                        &c,
                                        &self_aci,
                                        &names,
                                    )
                                    .await
                                    {
                                        let _ = event_tx.send(rv.to_string());
                                    } else if let Some(rv) = sync::call_signal_part(&c, &names) {
                                        // Group call signaling arrives as an
                                        // opaque payload and is handed to
                                        // RingRTC as raw bytes; 1:1 offer/answer/
                                        // ICE/hangup/busy goes through the call
                                        // state machine. Neither may become a
                                        // chat row.
                                        if rv.get("type").and_then(|v| v.as_str())
                                            == Some("group_call_signal")
                                        {
                                            if call::receive_group_call_signal(&rv) {
                                                let _ = event_tx.send(rv.to_string());
                                            }
                                            continue;
                                        }
                                        eprintln!(
                                            "[core] call signal kind={} thread={} from={}",
                                            rv.get("kind").and_then(|v| v.as_str()).unwrap_or("?"),
                                            rv.get("thread").and_then(|v| v.as_str()).unwrap_or("?"),
                                            rv.get("sender").and_then(|v| v.as_str()).unwrap_or("?"),
                                        );
                                        if call::receive_call_signal(&mut manager, &rv).await {
                                            let _ = event_tx.send(rv.to_string());
                                        }
                                    } else {
                                        if let Some(rv) = sync::reaction_part(&c, &names, &self_aci) {
                                            let _ = event_tx.send(rv.to_string());
                                        }
                                        if let Some(rv) = sync::edit_part(&c, &names, &self_aci) {
                                            if let (Some(thread), Some(target)) = (
                                                rv.get("thread").and_then(|v| v.as_str()),
                                                rv.get("target_sts").and_then(|v| v.as_u64()),
                                            ) {
                                                let native_store = names_store.clone();
                                                if let (Some(body), Some(author)) = (
                                                    rv.get("body").and_then(|v| v.as_str()),
                                                    rv.get("sender").and_then(|v| v.as_str()),
                                                ) {
                                                    let _ = sync::reconcile_edit(
                                                        &native_store,
                                                        thread,
                                                        target,
                                                        body,
                                                        author,
                                                    )
                                                    .await;
                                                }
                                            }
                                            let _ = event_tx.send(rv.to_string());
                                        }
                                        if let Some(rv) = sync::delete_part(&c, &names, &self_aci) {
                                            if let (Some(thread), Some(target)) = (
                                                rv.get("thread").and_then(|v| v.as_str()),
                                                rv.get("target_sts").and_then(|v| v.as_u64()),
                                            ) {
                                                let mut native_store = names_store.clone();
                                                if let Some(author) = rv.get("sender").and_then(|v| v.as_str()) {
                                                    let _ = sync::reconcile_delete(
                                                        &mut native_store,
                                                        thread,
                                                        target,
                                                        author,
                                                    )
                                                    .await;
                                                }
                                            }
                                            let _ = event_tx.send(rv.to_string());
                                        }
                                        if let Some(rv) = sync::typing_part(&c, &names) {
                                            let _ = event_tx.send(rv.to_string());
                                        }
                                        if let Some((v, _pointers)) =
                                            sync::content_parts(&c, &self_aci, &names)
                                        {
                                            let body_empty = v
                                                .get("body")
                                                .and_then(|b| b.as_str())
                                                .map(|b| b.is_empty())
                                                .unwrap_or(true);
                                            let has_quote = v.get("reply_to").is_some();
                                            let has_attachments = v
                                                .get("attachments")
                                                .and_then(|a| a.as_array())
                                                .map(|a| !a.is_empty())
                                                .unwrap_or(false);
                                            if !body_empty || has_attachments || has_quote {
                                                // Keep the receive loop metadata-only. CDN
                                                // downloads are performed by the bounded
                                                // Swift auto-fetch/on-demand path instead
                                                // of blocking websocket processing.
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
                                        names = sync::load_names(&names_store).await;
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
        // Awaiting the future consumes it, releasing its Manager handle. Drop
        // the cloned names store explicitly before acknowledging shutdown so
        // SQLite has no remaining native handle in this task.
        drop(names_store);
        if let Some(reply) = shutdown_reply {
            let _ = reply.send(());
        }
        if SYNC_GENERATION.load(Ordering::Acquire) == sync_generation {
            sync_alive.store(false, Ordering::Release);
            set_sync_ctrl(None);
        }
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
            call::invalidate_session();
            linked.sync_alive.store(false, Ordering::Release);
            SYNC_GENERATION.fetch_add(1, Ordering::AcqRel);
            set_sync_ctrl(None);
            if let Some(ctrl) = linked.ctrl.take() {
                let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
                if let Err(error) = send_sync_ctrl_wait(
                    &ctrl,
                    LoopCtrl::Shutdown { reply: shutdown_tx },
                )
                .await
                {
                    set_sync_ctrl(Some(ctrl.clone()));
                    linked.ctrl = Some(ctrl);
                    return Err(error);
                }
                shutdown_rx
                    .await
                    .map_err(|_| "sync loop dropped shutdown acknowledgement".to_string())?;
            }
            linked.manager.take();
            linked.events.take();
            linked.db_path.clone()
        }
        _ => return Err("not linked".to_string()),
    };
    let mut store = match state {
        WorkerState::Linked(linked) => linked.store.clone(),
        _ => return Err("not linked".to_string()),
    };
    store
        .clear_registration()
        .await
        .map_err(|e| format!("clear: {e}"))?;
    *state = WorkerState::Ready { store, db_path };
    Ok(())
}

async fn cmd_wipe(state: &mut WorkerState) -> Result<(), String> {
    call::invalidate_session();
    set_sync_ctrl(None);
    SYNC_GENERATION.fetch_add(1, Ordering::AcqRel);

    let db_path = match state {
        WorkerState::Linked(_) => {
            cmd_logout(state).await?;
            match state {
                WorkerState::Ready { db_path, .. } => db_path.clone(),
                _ => return Err("logout did not release native store".to_string()),
            }
        }
        WorkerState::Ready { db_path, .. } => db_path.clone(),
        WorkerState::Linking { task, db_path, .. } => {
            task.abort();
            let _ = task.await;
            db_path.clone()
        }
        WorkerState::Fresh => ACTIVE_DB_PATH
            .lock()
            .ok()
            .and_then(|slot| slot.clone())
            .unwrap_or_default(),
    };

    // Drop every native handle before unlinking the database and sidecars.
    let _ = std::mem::replace(state, WorkerState::Fresh);
    if db_path.is_empty() {
        return Ok(());
    }

    let remove = |path: std::path::PathBuf| -> Result<(), String> {
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("remove {}: {e}", path.display())),
        }
    };
    remove(std::path::PathBuf::from(&db_path))?;
    remove(std::path::PathBuf::from(format!("{db_path}-wal")))?;
    remove(std::path::PathBuf::from(format!("{db_path}-shm")))?;
    remove(std::path::PathBuf::from(format!("{db_path}-journal")))?;
    if let Ok(mut slot) = ACTIVE_DB_PATH.lock() {
        *slot = None;
    }
    Ok(())
}

async fn cmd_send(state: &mut WorkerState, thread: &str, body: &str) -> Result<u64, String> {
    // Auto-start the loop: sends are routed through it.
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            send_sync_ctrl(ctrl, LoopCtrl::Send { thread: thread.to_string(), body: body.to_string(), reply: tx })
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
            send_sync_ctrl(ctrl, LoopCtrl::SendAttachment {
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
            send_sync_ctrl(ctrl, LoopCtrl::SendReply {
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
            send_sync_ctrl(ctrl, LoopCtrl::SendDelete { thread: thread.to_string(), target_ts, reply: tx })
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
            send_sync_ctrl(ctrl, LoopCtrl::SendReaction {
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
    sync::send_content(manager, thread, content_body, ts).await
}

/// Profile display-name lookup (network). Errors when no profile key exists.
async fn cmd_profile(state: &mut WorkerState, uuid: &str) -> Result<String, String> {
    match state {
        WorkerState::Linked(linked) => {
            if let Some(manager) = linked.manager.as_mut() {
                sync::profile_name(manager, uuid).await
            } else if let Some(ctrl) = linked.ctrl.as_ref() {
                let (tx, rx) = tokio::sync::oneshot::channel();
                send_sync_ctrl(ctrl, LoopCtrl::Profile { uuid: uuid.to_string(), reply: tx })
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
            send_sync_ctrl(ctrl, LoopCtrl::SendReceipt {
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

/// Send a message edit (replaces content).
async fn cmd_send_message_edit(
    state: &mut WorkerState,
    thread: &str,
    target_ts: u64,
    new_body: &str,
) -> Result<u64, String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            send_sync_ctrl(ctrl, LoopCtrl::SendMessageEdit {
                thread: thread.to_string(),
                target_ts,
                new_body: new_body.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

/// Send a typing indicator.
async fn cmd_send_typing(
    state: &mut WorkerState,
    thread: &str,
    started: bool,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            send_sync_ctrl(ctrl, LoopCtrl::SendTyping {
                thread: thread.to_string(),
                started,
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

async fn cmd_call_start(
    state: &mut WorkerState,
    thread: &str,
    media_type: &str,
) -> Result<u64, String> {
    cmd_start_sync(state).await?;
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    let media = match media_type {
        "video" => ringrtc::common::CallMediaType::Video,
        _ => ringrtc::common::CallMediaType::Audio,
    };
    call::call_start(thread, media)
}

async fn cmd_call_accept(state: &mut WorkerState, call_id: u64) -> Result<(), String> {
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    call::call_accept(call_id)
}

async fn cmd_call_hangup(state: &mut WorkerState) -> Result<(), String> {
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    call::call_hangup()
}

fn cmd_call_set_muted(state: &WorkerState, muted: bool) -> Result<(), String> {
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    call::set_audio_muted(muted);
    Ok(())
}

/// Hand a group-call membership proof to RingRTC.
///
/// RingRTC asks for this via `RequestMembershipProof` and will not send its SFU
/// join request until one arrives, so a failure here means the call cannot
/// connect rather than degrading quietly.
fn cmd_group_call_set_membership_proof(
    state: &WorkerState,
    client_id: u32,
    token: Vec<u8>,
) -> Result<(), String> {
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    if token.is_empty() {
        return Err("membership proof was empty".to_string());
    }
    call::set_group_membership_proof(client_id, token)
}

/// Supply the member identities the SFU needs to attribute call traffic.
///
/// `user_ids` is `count` concatenated 16-byte service ids, `member_lens` is
/// `count` `u32` byte lengths, and `member_ids` holds the concatenated
/// ciphertexts. The lengths are validated here rather than trusted from the
/// caller.
fn cmd_group_call_set_group_members(
    state: &WorkerState,
    client_id: u32,
    count: u32,
    user_ids: Vec<u8>,
    member_lens: Vec<u32>,
    member_ids: Vec<u8>,
) -> Result<(), String> {
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    call::set_group_members(client_id, count, user_ids, member_lens, member_ids)
}

/// Deliver an SFU response the host performed for RingRTC.
///
/// RingRTC has no HTTP transport of its own here, so every SFU request/peek
/// stalls until this is called. A `status` of `None` means the request could
/// not be performed at all (DNS, TLS, connectivity), which RingRTC treats
/// differently from an HTTP error status.
fn cmd_http_response(
    state: &WorkerState,
    request_id: u32,
    status: Option<u16>,
    body: Vec<u8>,
) -> Result<(), String> {
    if !matches!(state, WorkerState::Linked(_)) {
        return Err("not linked".to_string());
    }
    call::deliver_http_response(request_id, status, body)
}

/// Fetch the ZK group auth credentials that a group-call membership proof is
/// derived from, as raw JSON.
///
/// Routed through the sync loop because that is where the live manager lives:
/// once the loop is running, `LinkedState.manager` is `None`. The body is
/// returned unparsed on purpose, so the caller decodes it where that shape is
/// tested, and the vendored presage patch stays a single authenticated GET.
async fn cmd_group_auth_credentials(state: &WorkerState) -> Result<String, String> {
    let sender = match state {
        WorkerState::Linked(linked) => match linked.ctrl.as_ref() {
            Some(sender) => sender,
            None => return Err("sync loop is not running".to_string()),
        },
        _ => return Err("not linked".to_string()),
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs();
    let day = group_calls::current_redemption_day(now);
    // Ask for today and tomorrow: the server decides which days are issued, and
    // a credential only becomes usable as its day arrives.
    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
    send_sync_ctrl_wait(
        sender,
        LoopCtrl::GroupAuthCredentials { start_day: day, end_day: day + 1, reply: reply_tx },
    )
    .await?;
    reply_rx.await.map_err(|_| "sync loop dropped the request".to_string())?
}

/// Build the CDN authorization for a group call membership proof.
///
/// `group_id` is the 32-byte ZK group identifier RingRTC reports. Everything
/// that needs the live manager happens in one hop through the sync loop: the
/// credential request is authenticated, and the ZK server public params the
/// presentation verifies against are only reachable there. Swift then redeems
/// the returned value at the CDN, which is the one part worth keeping testable
/// on its own.
async fn cmd_group_call_proof_authorization(
    state: &WorkerState,
    group_id: &[u8],
) -> Result<String, String> {
    if group_id.is_empty() {
        return Err("group call proof needs a group id".to_string());
    }
    let sender = match state {
        WorkerState::Linked(linked) => match linked.ctrl.as_ref() {
            Some(sender) => sender,
            None => return Err("sync loop is not running".to_string()),
        },
        _ => return Err("not linked".to_string()),
    };
    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
    send_sync_ctrl_wait(
        sender,
        LoopCtrl::GroupCallProofAuthorization {
            group_id: group_id.to_vec(),
            reply: reply_tx,
        },
    )
    .await?;
    reply_rx.await.map_err(|_| "sync loop dropped the request".to_string())?
}

/// Legacy SDP-shaped command retained for source compatibility. New clients
/// use `core_cmd_call_start` and let RingRTC generate the opaque signaling.
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
            send_sync_ctrl(ctrl, LoopCtrl::SendCallOffer {
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
            send_sync_ctrl(ctrl, LoopCtrl::SendCallAnswer {
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
            send_sync_ctrl(ctrl, LoopCtrl::SendCallIceCandidate {
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
            send_sync_ctrl(ctrl, LoopCtrl::SendCallHangup {
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

/// Send a call signaling message via the sync loop.
async fn cmd_send_call_signal(
    state: &mut WorkerState,
    thread: &str,
    call_message_json: &str,
) -> Result<(), String> {
    cmd_start_sync(state).await?;
    match state {
        WorkerState::Linked(linked) => {
            let ctrl = linked.ctrl.as_ref().ok_or_else(|| "sync loop not running".to_string())?;
            let (tx, rx) = tokio::sync::oneshot::channel();
            send_sync_ctrl(ctrl, LoopCtrl::SendCallSignal {
                thread: thread.to_string(),
                call_message_json: call_message_json.to_string(),
                reply: tx,
            })
            .map_err(|_| "sync loop is gone".to_string())?;
            rx.await.map_err(|_| "sync loop dropped reply".to_string())?
        }
        _ => Err("not linked".to_string()),
    }
}

fn call_id_from_wire(value: &str) -> u64 {
    value.parse().unwrap_or(0)
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn call_message_json(message: &ringrtc::core::signaling::Message) -> String {
    let json = match message {
        ringrtc::core::signaling::Message::Offer(offer) => serde_json::json!({
            "offer": {
                "media_type": match offer.call_media_type {
                    ringrtc::common::CallMediaType::Audio => "audio",
                    ringrtc::common::CallMediaType::Video => "video",
                },
                "opaque": b64(&offer.opaque),
            }
        }),
        ringrtc::core::signaling::Message::Answer(answer) => serde_json::json!({
            "answer": { "opaque": b64(&answer.opaque) }
        }),
        ringrtc::core::signaling::Message::Ice(ice) => serde_json::json!({
            "ice": ice.candidates.iter().map(|candidate| serde_json::json!({
                "opaque": b64(&candidate.opaque)
            })).collect::<Vec<_>>()
        }),
        ringrtc::core::signaling::Message::Hangup(hangup) => {
            let (kind, _) = hangup.to_type_and_device_id();
            serde_json::json!({ "hangup": { "type": kind as i32 } })
        }
        ringrtc::core::signaling::Message::Busy => serde_json::json!({ "busy": {} }),
    };
    json.to_string()
}

/// Build a call offer message (returns JSON).
async fn cmd_build_call_offer(call_id: &str, media_type: &str, opaque: &str) -> Result<String, String> {
    let media = if media_type == "video" {
        ringrtc::common::CallMediaType::Video
    } else {
        ringrtc::common::CallMediaType::Audio
    };
    let message = call::build_offer_message(
        ringrtc::common::CallId::new(call_id_from_wire(call_id)),
        media,
        opaque.as_bytes().to_vec(),
    );
    let json = if let Some(offer) = message.offer {
        serde_json::json!({
            "offer": {
                "id": offer.id,
                "type": offer.r#type,
                "opaque": b64(&offer.opaque.unwrap_or_default()),
            }
        })
    } else {
        serde_json::json!({})
    };
    Ok(json.to_string())
}

/// Build a call answer message (returns JSON).
async fn cmd_build_call_answer(call_id: &str, opaque: &str) -> Result<String, String> {
    let message = call::build_answer_message(
        ringrtc::common::CallId::new(call_id_from_wire(call_id)),
        opaque.as_bytes().to_vec(),
    );
    let json = if let Some(answer) = message.answer {
        serde_json::json!({
            "answer": { "id": answer.id, "opaque": b64(&answer.opaque.unwrap_or_default()) }
        })
    } else {
        serde_json::json!({})
    };
    Ok(json.to_string())
}

/// Build a call ICE message (returns JSON).
async fn cmd_build_call_ice(call_id: &str, opaque: &str) -> Result<String, String> {
    let message = call::build_ice_message(
        ringrtc::common::CallId::new(call_id_from_wire(call_id)),
        opaque.as_bytes().to_vec(),
    );
    Ok(serde_json::json!({
        "ice_update": message.ice_update.iter().map(|ice| serde_json::json!({
            "id": ice.id,
            "opaque": b64(ice.opaque.as_deref().unwrap_or_default()),
        })).collect::<Vec<_>>()
    }).to_string())
}

/// Build a call hangup message (returns JSON).
async fn cmd_build_call_hangup(call_id: &str, hangup_type: u32, device_id: u32) -> Result<String, String> {
    let message = call::build_hangup_message(
        ringrtc::common::CallId::new(call_id_from_wire(call_id)),
        hangup_type,
        (device_id != 0).then_some(device_id),
    );
    let json = if let Some(hangup) = message.hangup {
        serde_json::json!({
            "hangup": { "id": hangup.id, "type": hangup.r#type, "device_id": hangup.device_id }
        })
    } else {
        serde_json::json!({})
    };
    Ok(json.to_string())
}

/// Build a call busy message (returns JSON).
async fn cmd_build_call_busy(call_id: &str) -> Result<String, String> {
    let message = call::build_busy_message(ringrtc::common::CallId::new(call_id_from_wire(call_id)));
    let json = if let Some(busy) = message.busy {
        serde_json::json!({ "busy": { "id": busy.id } })
    } else {
        serde_json::json!({})
    };
    Ok(json.to_string())
}

/// Parse a base64 protobuf call message (returns JSON).
async fn cmd_parse_call_message(call_message_json: &str) -> Result<String, String> {
    use prost::Message as _;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(call_message_json)
        .map_err(|e| format!("base64 decode: {e}"))?;
    let message = ProtoCallMessage::decode(bytes.as_slice())
        .map_err(|e| format!("protobuf decode: {e}"))?;
    let parsed = call::parse_call_message(&message).map_err(|e| e.to_string())?;
    Ok(call_message_json_for_signal(&parsed))
}

fn call_message_json_for_signal(message: &ringrtc::core::signaling::Message) -> String {
    call_message_json(message)
}

/// Convert a call end reason to string.
async fn cmd_call_end_reason_to_string(reason: i32) -> Result<String, String> {
    let name = match reason {
        0 => "local_hangup",
        1 => "remote_hangup",
        2 => "remote_hangup_need_permission",
        3 => "remote_hangup_accepted",
        4 => "remote_hangup_declined",
        5 => "remote_hangup_busy",
        6 => "remote_busy",
        7 => "remote_glare",
        8 => "remote_recall",
        9 => "timeout",
        10 => "internal_failure",
        11 => "signaling_failure",
        12 => "connection_failure",
        13 => "app_dropped_call",
        14 => "device_explicitly_disconnected",
        15 => "server_explicitly_disconnected",
        _ => "other",
    };
    Ok(name.to_string())
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
            send_sync_ctrl(ctrl, LoopCtrl::FetchAttachment {
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

/// ABI version consumed by the Swift loader before any other symbol is used.
///
/// 3 adds `core_cmd_http_response`, which lets the host perform the SFU
/// requests RingRTC raises. Older dylibs lack that symbol, so the loader
/// rejects them rather than stalling group calls on unanswered SFU requests.
pub const CORE_ABI_VERSION: u32 = 4;

#[no_mangle]
pub extern "C" fn core_abi_version() -> u32 {
    CORE_ABI_VERSION
}

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
///
/// The Keychain-backed initializer is `core_cmd_init_encrypted`; this legacy
/// symbol is retained only as a fail-closed migration guard for old callers.
#[no_mangle]
pub extern "C" fn core_cmd_init(db_path: *const c_char) -> i32 {
    if let Err(error) = c_str_arg(db_path, "db_path") {
        set_last_error(error);
    } else {
        set_last_error(
            "plaintext core_cmd_init is disabled; use core_cmd_init_encrypted".to_string(),
        );
    }
    -1
}

/// 1 linked, 0 fresh, -1 error (see `core_last_error`).
#[no_mangle]
pub extern "C" fn core_cmd_init_encrypted(
    db_path: *const c_char,
    passphrase: *const c_char,
) -> i32 {
    let path = match c_str_arg(db_path, "db_path") {
        Ok(path) => path,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let passphrase = match c_str_arg(passphrase, "passphrase") {
        Ok(passphrase) if !passphrase.is_empty() => passphrase,
        Ok(_) => {
            set_last_error("passphrase: empty".to_string());
            return -1;
        }
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let core = CORE.get_or_init(|| Core { cmd_tx: spawn_worker() });
    let _ = core;
    match roundtrip(|reply| Command::Init {
        db_path: path,
        passphrase,
        reply,
    }) {
        Ok(Ok(true)) => 1,
        Ok(Ok(false)) => 0,
        Ok(Err(error)) | Err(error) => {
            set_last_error(error);
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

/// Wipe the native session and database. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_wipe() -> i32 {
    match roundtrip(|reply| Command::Wipe { reply }) {
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
    let limit = (limit.max(1).min(5_000)) as usize;
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

/// Send a message edit (replaces content). Returns sent timestamp (ms), or -1 on error.
#[no_mangle]
pub extern "C" fn core_cmd_send_message_edit(
    thread: *const c_char,
    target_ts: u64,
    new_body: *const c_char,
) -> i64 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => { set_last_error(e); return -1; }
    };
    let b = match c_str_arg(new_body, "new_body") {
        Ok(b) => b,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendMessageEdit { thread: t, target_ts, new_body: b, reply }) {
        Ok(Ok(ts)) => ts as i64,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Send a typing indicator. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_typing(
    thread: *const c_char,
    started: i32,
) -> i32 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendTyping { thread: t, started: started != 0, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
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

/// Start a native RingRTC call. Returns the RingRTC call id, or `u64::MAX` on error.
#[no_mangle]
pub extern "C" fn core_cmd_call_start(thread: *const c_char, media_type: *const c_char) -> u64 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => { set_last_error(e); return u64::MAX; }
    };
    let m = match c_str_arg(media_type, "media_type") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return u64::MAX; }
    };
    match roundtrip(|reply| Command::CallStart { thread: t, media_type: m, reply }) {
        Ok(Ok(id)) => id,
        Ok(Err(e)) | Err(e) => { set_last_error(e); u64::MAX }
    }
}

/// Accept an incoming native call. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_call_accept(call_id: u64) -> i32 {
    match roundtrip(|reply| Command::CallAccept { call_id, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Hang up the active native call. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_call_hangup() -> i32 {
    match roundtrip(|reply| Command::CallHangup { reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Set the native outgoing audio track mute state. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_call_set_muted(muted: i32) -> i32 {
    match roundtrip(|reply| Command::CallSetMuted { muted: muted != 0, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Create a group call client and connect it.
///
/// `group_id` is the group's 32-byte ZK identifier in hex. `sfu_url` may be
/// NULL to use the production SFU; it is never inferred from the environment.
/// Returns the RingRTC client id plus one, so zero means failure; the id is the
/// value every later group-call command addresses. Returns UINT64_MAX on error.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_start(
    group_id_hex: *const c_char,
    sfu_url: *const c_char,
) -> u64 {
    let group_id_hex = match c_str_arg(group_id_hex, "group_id_hex") {
        Ok(value) => value,
        Err(e) => {
            set_last_error(e);
            return u64::MAX;
        }
    };
    let group_id = match hex::decode(group_id_hex.trim()) {
        Ok(bytes) if !bytes.is_empty() => bytes,
        Ok(_) => {
            set_last_error("group id was empty".to_string());
            return u64::MAX;
        }
        Err(e) => {
            set_last_error(format!("group id was not hex: {e}"));
            return u64::MAX;
        }
    };
    // A NULL url means "use the default"; an empty string is a caller mistake
    // and is reported rather than silently replaced.
    let sfu_url = if sfu_url.is_null() {
        None
    } else {
        match c_str_arg(sfu_url, "sfu_url") {
            Ok(value) if value.trim().is_empty() => {
                set_last_error("sfu url was empty".to_string());
                return u64::MAX;
            }
            Ok(value) => Some(value),
            Err(e) => {
                set_last_error(e);
                return u64::MAX;
            }
        }
    };

    match roundtrip(|reply| Command::GroupCallStart { group_id, sfu_url, reply }) {
        Ok(Ok(id)) => id,
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            u64::MAX
        }
    }
}

/// Ask the SFU to admit a group call client. This raises the
/// `request_membership_proof` update the host answers. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_join(client_id: u32) -> i32 {
    match roundtrip(|reply| Command::GroupCallJoin { client_id, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Leave the SFU but keep the client so a call can be rejoined.
/// 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_leave(client_id: u32) -> i32 {
    match roundtrip(|reply| Command::GroupCallLeave { client_id, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Leave if needed, then delete the client and forget it. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_end(client_id: u32) -> i32 {
    match roundtrip(|reply| Command::GroupCallEnd { client_id, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Hand a group-call membership proof to RingRTC.
///
/// RingRTC asks for this via a `request_membership_proof` group update and will
/// not send its SFU join request until one arrives, so a failure here means the
/// call cannot connect rather than degrading quietly. Returns 0 on success.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_set_membership_proof(
    client_id: u32,
    proof: *const u8,
    proof_len: usize,
) -> i32 {
    let token = if proof.is_null() || proof_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(proof, proof_len).to_vec() }
    };
    match roundtrip(|reply| Command::GroupCallSetMembershipProof { client_id, token, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Supply the member identities the SFU needs to attribute call traffic.
///
/// `user_ids` is `count` concatenated 16-byte service ids, `member_lens` is
/// `count` `u32` byte lengths, and `member_ids` holds the concatenated
/// encrypted-UID ciphertexts. Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_set_group_members(
    client_id: u32,
    count: u32,
    user_ids: *const u8,
    member_lens: *const u32,
    member_ids: *const u8,
    member_count: u32,
) -> i32 {
    let user_count = count as usize;
    let users = if user_ids.is_null() || user_count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(user_ids, user_count * 16).to_vec() }
    };
    let lens = if member_lens.is_null() || user_count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(member_lens, user_count).to_vec() }
    };
    let ids = if member_ids.is_null() || member_count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(member_ids, member_count as usize).to_vec() }
    };
    match roundtrip(|reply| Command::GroupCallSetGroupMembers {
        client_id,
        count,
        user_ids: users,
        member_lens: lens,
        member_ids: ids,
        reply,
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Fetch today's ZK group auth credentials as raw JSON.
///
/// Group calls need one of these to derive a membership proof. Returns a
/// JSON document; the caller decodes it. Fails when the account is not linked
/// or the sync loop is not running, since the loop owns the live manager.
#[no_mangle]
pub extern "C" fn core_cmd_group_auth_credentials() -> *mut c_char {
    match roundtrip(|reply| Command::GroupAuthCredentials { reply }) {
        Ok(Ok(json)) => match std::ffi::CString::new(json) {
            Ok(value) => value.into_raw(),
            Err(_) => {
                set_last_error("credential response was not valid UTF-8".to_string());
                std::ptr::null_mut()
            }
        },
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Build the CDN authorization for a group call membership proof.
///
/// `group_id` is the 32-byte ZK group identifier RingRTC reports, as raw bytes.
/// Returns the `hex(groupPublicParams):hex(presentation)` value that
/// `GroupCallProofService` redeems at the CDN, as a NUL-terminated string the
/// caller frees with `core_cmd_string_free`.
///
/// Nothing is returned when the account is not linked, when the sync loop is not
/// running, or when the group is not one this device is a member of. There is no
/// synthesized proof: without a real server-issued credential the SFU would
/// reject the join, and faking it would make the failure look like a transport
/// fault.
#[no_mangle]
pub extern "C" fn core_cmd_group_call_proof_authorization(group_id: *const u8, group_id_len: u32) -> *mut c_char {
    if group_id.is_null() {
        set_last_error("group call proof needs a group id".to_string());
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(group_id, group_id_len as usize) }.to_vec();
    match roundtrip(|reply| Command::GroupCallProofAuthorization { group_id: bytes, reply }) {
        Ok(Ok(authorization)) => match std::ffi::CString::new(authorization) {
            Ok(value) => value.into_raw(),
            Err(_) => {
                set_last_error("membership proof was not valid UTF-8".to_string());
                std::ptr::null_mut()
            }
        },
        Ok(Err(e)) | Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Deliver an SFU HTTP response that the host performed for RingRTC.
///
/// RingRTC raises SFU requests as `http_request` events and stalls until this
/// is called with the matching request id. `status` of 0 reports that the
/// request could not be performed at all, which RingRTC treats differently
/// from an HTTP error status. 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_http_response(
    request_id: u32,
    status: u32,
    body: *const u8,
    body_len: usize,
) -> i32 {
    let body = if body.is_null() || body_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(body, body_len).to_vec() }
    };
    let status = u16::try_from(status).ok();
    match roundtrip(|reply| Command::HttpResponse { request_id, status, body, reply }) {
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

/// Send a call signaling message (offer, answer, ICE, hangup, busy). 0 ok, -1 error.
#[no_mangle]
pub extern "C" fn core_cmd_send_call_signal(
    thread: *const c_char,
    call_message_json: *const c_char,
) -> i32 {
    let t = match c_str_arg(thread, "thread") {
        Ok(t) => t,
        Err(e) => { set_last_error(e); return -1; }
    };
    let json = match c_str_arg(call_message_json, "call_message_json") {
        Ok(j) => j,
        Err(e) => { set_last_error(e); return -1; }
    };
    match roundtrip(|reply| Command::SendCallSignal { thread: t, call_message_json: json, reply }) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => { set_last_error(e); -1 }
    }
}

/// Build a call offer message. Returns JSON string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_build_call_offer(
    call_id: *const c_char,
    media_type: *const c_char,
    opaque: *const c_char,
) -> *mut c_char {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };
    let mt = match c_str_arg(media_type, "media_type") {
        Ok(m) => m,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };
    let op = match c_str_arg(opaque, "opaque") {
        Ok(o) => o,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };

    match roundtrip(|reply| Command::BuildCallOffer { call_id: cid, media_type: mt, opaque: op, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Build a call answer message. Returns JSON string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_build_call_answer(
    call_id: *const c_char,
    opaque: *const c_char,
) -> *mut c_char {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };
    let op = match c_str_arg(opaque, "opaque") {
        Ok(o) => o,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };

    match roundtrip(|reply| Command::BuildCallAnswer { call_id: cid, opaque: op, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Build a call ICE message. Returns JSON string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_build_call_ice(
    call_id: *const c_char,
    opaque: *const c_char,
) -> *mut c_char {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };
    let op = match c_str_arg(opaque, "opaque") {
        Ok(o) => o,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };

    match roundtrip(|reply| Command::BuildCallIce { call_id: cid, opaque: op, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Build a call hangup message. Returns JSON string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_build_call_hangup(
    call_id: *const c_char,
    hangup_type: u32,
    device_id: u32,
) -> *mut c_char {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };

    match roundtrip(|reply| Command::BuildCallHangup { call_id: cid, hangup_type, device_id, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Build a call busy message. Returns JSON string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_build_call_busy(
    call_id: *const c_char,
) -> *mut c_char {
    let cid = match c_str_arg(call_id, "call_id") {
        Ok(c) => c,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };

    match roundtrip(|reply| Command::BuildCallBusy { call_id: cid, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Parse a call message from JSON. Returns JSON string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_parse_call_message(
    call_message_json: *const c_char,
) -> *mut c_char {
    let json = match c_str_arg(call_message_json, "call_message_json") {
        Ok(j) => j,
        Err(e) => { set_last_error(e); return std::ptr::null_mut(); }
    };

    match roundtrip(|reply| Command::ParseCallMessage { call_message_json: json, reply }) {
        Ok(Ok(json)) => ok_string(json),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
    }
}

/// Convert a call end reason to string. Returns string (free with core_free_string).
#[no_mangle]
pub extern "C" fn core_cmd_call_end_reason_to_string(
    reason: i32,
) -> *mut c_char {
    match roundtrip(|reply| Command::CallEndReasonToString { reason, reply }) {
        Ok(Ok(s)) => ok_string(s),
        Ok(Err(e)) | Err(e) => { set_last_error(e); std::ptr::null_mut() }
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
    fn sync_control_queue_is_bounded() {
        let (sender, _receiver) = tmpsc::channel(1);
        let (reply, _ack) = oneshot::channel();
        send_sync_ctrl(&sender, LoopCtrl::Shutdown { reply }).unwrap();
        let (reply, _ack) = oneshot::channel();
        let error = send_sync_ctrl(&sender, LoopCtrl::Shutdown { reply }).unwrap_err();
        assert!(error.contains("full"));
    }

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(core_abi_version(), 4);
        assert_eq!(core_abi_version(), CORE_ABI_VERSION);
    }

    #[test]
    fn null_args_fail_loudly() {
        assert_eq!(core_cmd_init(std::ptr::null()), -1);
        assert_eq!(core_cmd_init_encrypted(std::ptr::null(), std::ptr::null()), -1);
        assert!(!core_last_error().is_null());
        assert!(core_cmd_begin_link(std::ptr::null()).is_null());
        // The worker is process-wide and may already have been initialized by
        // another test; the null-pointer contract is that these calls never
        // panic, which is covered by the assertions above.
        core_free_string(std::ptr::null_mut());
    }

    #[test]
    fn init_rejects_bad_db_dir() {
        // /proc is not writable: open must fail instead of hanging.
        let raw = CString::new("/proc/nope/signal.db").unwrap().into_raw();
        let key = CString::new("test-passphrase").unwrap().into_raw();
        assert_eq!(core_cmd_init_encrypted(raw, key), -1);
        core_free_string(raw);
        core_free_string(key);
    }

    #[test]
    fn init_creates_temp_store_unlinked() {
        let dir = std::env::temp_dir().join(format!("cuztom-test-{}", std::process::id()));
        let db = dir.join("signal.db");
        let raw = CString::new(db.to_string_lossy().into_owned()).unwrap().into_raw();
        let key = CString::new("test-passphrase").unwrap().into_raw();
        assert_eq!(core_cmd_init_encrypted(raw, key), 0);
        core_free_string(raw);
        core_free_string(key);
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
