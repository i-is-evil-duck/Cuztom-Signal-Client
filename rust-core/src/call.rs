//! Signal 1:1 calls using ringrtc's native (macOS/CoreAudio) platform.
//!
//! RingRTC's `CallManager` runs on its own worker thread. Its signaling
//! callback is synchronous, while libsignal sends are asynchronous and must
//! run on the core's `!Send` tokio `LocalSet`. The two sides are connected by
//! bounded channels: the callback enqueues a fully-built Signal
//! `CallMessage`, and the core sync loop performs the actual send. RingRTC is
//! notified when that send succeeds or fails.

use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::Duration;

use base64::Engine as _;
use prost::Message as _;
use ringrtc::{
    common::{CallConfig, CallEndReason, CallId, CallMediaType, DeviceId},
    core::{
        call_manager::CallManager,
        group_call::SignalingMessageUrgency,
        signaling::{
            self, Answer, Ice, IceCandidate, Offer, ReceivedAnswer, ReceivedBusy,
            ReceivedHangup, ReceivedIce, ReceivedOffer,
        },
    },
    lite::{
        http,
        sfu::DemuxId,
    },
    native::{
        CallState, CallStateHandler, GroupUpdate, GroupUpdateHandler, NativeCallContext,
        NativePlatform, SignalingSender,
    },
    webrtc::{
        media::{AudioTrack, VideoFrame, VideoSink, VideoTrack},
        peer_connection::AudioLevel,
        peer_connection_factory::{AudioConfig, IceServer, PeerConnectionFactory},
        peer_connection_observer::NetworkRoute,
    },
};

use libsignal_service::{
    content::ContentBody,
    protocol::{Aci, DeviceId as SignalDeviceId, IdentityKeyStore, Pni, ProtocolAddress, ServiceId},
    proto::{
        call_message::{
            Answer as ProtoAnswer, Busy as ProtoBusy, Hangup as ProtoHangup,
            IceUpdate as ProtoIceUpdate, Offer as ProtoOffer,
        },
        CallMessage as ProtoCallMessage,
    },
};
use presage::store::Store;

use crate::sync::StoredManager;

// ---------------------------------------------------------------------------
// Channels and process-wide call state
// ---------------------------------------------------------------------------

/// A Signal `CallMessage` waiting to be sent through libsignal.
pub struct PendingCallSignal {
    pub session_generation: u64,
    pub thread: String,
    pub call_id: u64,
    pub proto: Vec<u8>,
}

/// A deferred RingRTC action. The state callback cannot call `proceed`
/// directly: it is invoked while RingRTC's internal worker is active. The core
/// loop drains this channel instead.
pub enum CallAction {
    Proceed {
        session_generation: u64,
        call_id: u64,
    },
}

static CALL_SIGNAL_TX: OnceLock<tokio::sync::mpsc::Sender<PendingCallSignal>> = OnceLock::new();
static CALL_SIGNAL_RX: OnceLock<Mutex<Option<tokio::sync::mpsc::Receiver<PendingCallSignal>>>> =
    OnceLock::new();

static CALL_ACTION_TX: OnceLock<tokio::sync::mpsc::Sender<CallAction>> = OnceLock::new();
static CALL_ACTION_RX: OnceLock<Mutex<Option<tokio::sync::mpsc::Receiver<CallAction>>>> =
    OnceLock::new();

static CALL_EVENT_TX: OnceLock<std::sync::mpsc::SyncSender<String>> = OnceLock::new();
static CALL_EVENT_RX: OnceLock<Mutex<std::sync::mpsc::Receiver<String>>> = OnceLock::new();

static CALL_MANAGER: OnceLock<Mutex<CallManager<NativePlatform>>> = OnceLock::new();
static CALL_CONTEXT: OnceLock<NativeCallContext> = OnceLock::new();
static CALL_AUDIO_TRACK: OnceLock<AudioTrack> = OnceLock::new();
static LOCAL_DEVICE_ID: AtomicU32 = AtomicU32::new(1);
static SESSION_GENERATION: AtomicU64 = AtomicU64::new(1);

fn signal_tx() -> Option<&'static tokio::sync::mpsc::Sender<PendingCallSignal>> {
    CALL_SIGNAL_TX.get()
}
fn action_tx() -> Option<&'static tokio::sync::mpsc::Sender<CallAction>> {
    CALL_ACTION_TX.get()
}
fn event_tx() -> Option<&'static std::sync::mpsc::SyncSender<String>> {
    CALL_EVENT_TX.get()
}
fn manager() -> Option<&'static Mutex<CallManager<NativePlatform>>> {
    CALL_MANAGER.get()
}
fn context() -> Option<&'static NativeCallContext> {
    CALL_CONTEXT.get()
}

/// Take the signal receiver once, when the core receive loop starts.
pub fn take_signal_rx() -> Option<tokio::sync::mpsc::Receiver<PendingCallSignal>> {
    CALL_SIGNAL_RX
        .get()
        .and_then(|slot| slot.lock().ok().and_then(|mut r| r.take()))
}

/// Take the deferred RingRTC-action receiver once.
pub fn take_action_rx() -> Option<tokio::sync::mpsc::Receiver<CallAction>> {
    CALL_ACTION_RX
        .get()
        .and_then(|slot| slot.lock().ok().and_then(|mut r| r.take()))
}

/// Drain one state event without blocking the core worker.
pub fn try_event() -> Option<String> {
    CALL_EVENT_RX
        .get()
        .and_then(|rx| rx.lock().ok().and_then(|rx| rx.try_recv().ok()))
}

pub fn clear_events() {
    while try_event().is_some() {}
}

pub fn session_generation() -> u64 {
    SESSION_GENERATION.load(Ordering::Acquire)
}

/// Invalidate all queued RingRTC work before an account boundary. The
/// process-wide bridge remains alive, but messages/actions stamped with the
/// previous generation are discarded instead of being sent after relink.
pub fn invalidate_session() {
    SESSION_GENERATION.fetch_add(1, Ordering::AcqRel);
    clear_events();
    drop_active_call();
}

pub fn set_self_uuid(uuid: &str) {
    let Some(manager) = manager() else { return };
    let Ok(parsed) = uuid.parse::<uuid::Uuid>() else { return };
    let Ok(mut manager) = manager.lock() else { return };
    let _ = manager.set_self_uuid(parsed.as_bytes().to_vec());
}

pub fn set_local_device_id(device_id: u32) {
    LOCAL_DEVICE_ID.store(device_id.max(1), Ordering::Relaxed);
}

fn local_device_id() -> DeviceId {
    LOCAL_DEVICE_ID.load(Ordering::Relaxed).max(1)
}

// ---------------------------------------------------------------------------
// RingRTC signaling adapter
// ---------------------------------------------------------------------------

struct CuztomSignalingSender;

impl SignalingSender for CuztomSignalingSender {
    fn send_signaling(
        &self,
        recipient_id: &str,
        call_id: CallId,
        receiver_device_id: Option<DeviceId>,
        message: signaling::Message,
    ) -> ringrtc::common::Result<()> {
        let id = Some(call_id.as_u64());
        let destination_device_id = receiver_device_id.map(|v| v);
        let proto = match message {
            signaling::Message::Offer(offer) => ProtoCallMessage {
                offer: Some(ProtoOffer {
                    id,
                    r#type: Some(match offer.call_media_type {
                        CallMediaType::Audio => 0,
                        CallMediaType::Video => 1,
                    }),
                    opaque: Some(offer.opaque),
                }),
                ..Default::default()
            },
            signaling::Message::Answer(answer) => ProtoCallMessage {
                answer: Some(ProtoAnswer {
                    id,
                    opaque: Some(answer.opaque),
                }),
                // Answers and targeted ICE are delivered to the device that
                // sent the offer. This field is part of Signal's CallMessage.
                destination_device_id,
                ..Default::default()
            },
            signaling::Message::Ice(ice) => ProtoCallMessage {
                ice_update: ice
                    .candidates
                    .iter()
                    .map(|candidate| ProtoIceUpdate {
                        id,
                        opaque: Some(candidate.opaque.clone()),
                    })
                    .collect(),
                destination_device_id,
                ..Default::default()
            },
            signaling::Message::Hangup(hangup) => {
                let (hangup_type, device_id) = hangup.to_type_and_device_id();
                ProtoCallMessage {
                    hangup: Some(ProtoHangup {
                        id,
                        r#type: Some(hangup_type as i32),
                        device_id,
                    }),
                    ..Default::default()
                }
            }
            signaling::Message::Busy => ProtoCallMessage {
                busy: Some(ProtoBusy { id }),
                ..Default::default()
            },
        };

        let Some(tx) = signal_tx() else {
            return Err(std::io::Error::other("call signaling is not initialized").into());
        };
        tx.try_send(PendingCallSignal {
            session_generation: session_generation(),
            thread: recipient_id.to_string(),
            call_id: call_id.as_u64(),
            proto: proto.encode_to_vec(),
        })
        .map_err(|error| {
            std::io::Error::other(match error {
                tokio::sync::mpsc::error::TrySendError::Full(_) => "call signaling queue is full",
                tokio::sync::mpsc::error::TrySendError::Closed(_) => "call signaling receiver is closed",
            })
        })
        .map_err(Into::into)
    }

    fn send_call_message(
        &self,
        _recipient_id: Vec<u8>,
        _message: Vec<u8>,
        _urgency: SignalingMessageUrgency,
    ) -> ringrtc::common::Result<()> {
        Err(std::io::Error::other("group calls are not supported").into())
    }

    fn send_call_message_to_group(
        &self,
        _group_id: Vec<u8>,
        _message: Vec<u8>,
        _urgency: SignalingMessageUrgency,
        _recipients_override: HashSet<Vec<u8>>,
    ) -> ringrtc::common::Result<()> {
        Err(std::io::Error::other("group calls are not supported").into())
    }

    fn send_call_message_to_adhoc_group(
        &self,
        _message: Vec<u8>,
        _urgency: SignalingMessageUrgency,
        _expiration: u64,
        _recipients_to_endorsements: std::collections::HashMap<Vec<u8>, Vec<u8>>,
    ) -> ringrtc::common::Result<()> {
        Err(std::io::Error::other("group calls are not supported").into())
    }
}

// ---------------------------------------------------------------------------
// RingRTC state adapter
// ---------------------------------------------------------------------------

fn state_name(state: &CallState) -> &'static str {
    match state {
        CallState::Incoming(_) => "incoming",
        CallState::Outgoing(_) => "outgoing",
        CallState::Ringing => "ringing",
        CallState::Connected => "connected",
        CallState::Connecting => "connecting",
        CallState::Ended(reason, _) => match reason {
            CallEndReason::LocalHangup => "ended_local",
            CallEndReason::RemoteHangup => "ended_remote",
            CallEndReason::RemoteHangupNeedPermission => "ended_need_permission",
            CallEndReason::RemoteHangupAccepted => "ended_accepted",
            CallEndReason::RemoteHangupDeclined => "ended_declined",
            CallEndReason::RemoteHangupBusy => "ended_busy",
            CallEndReason::RemoteBusy => "busy",
            CallEndReason::RemoteGlare => "glare",
            CallEndReason::RemoteReCall => "recall",
            CallEndReason::Timeout => "timeout",
            CallEndReason::InternalFailure => "failed",
            CallEndReason::SignalingFailure => "signaling_failed",
            CallEndReason::ConnectionFailure => "connection_failed",
            CallEndReason::AppDroppedCall => "dropped",
            CallEndReason::DeviceExplicitlyDisconnected => "disconnected",
            CallEndReason::ServerExplicitlyDisconnected => "server_disconnected",
            CallEndReason::DeniedRequestToJoinCall => "denied",
            _ => "ended",
        },
        CallState::Rejected(_) => "rejected",
        CallState::Concluded => "concluded",
    }
}

struct CuztomStateHandler;

impl CallStateHandler for CuztomStateHandler {
    fn handle_call_state(
        &self,
        remote_peer_id: &str,
        call_id: CallId,
        state: CallState,
    ) -> ringrtc::common::Result<()> {
        if let Some(tx) = event_tx() {
            let _ = tx.try_send(
                serde_json::json!({
                    "type": "call_state",
                    "thread": remote_peer_id,
                    "call_id": call_id.as_u64(),
                    "state": state_name(&state),
                })
                .to_string(),
            );
        }

        // RingRTC requires the application to call `proceed` after it receives
        // the initial Incoming/Outgoing state. Defer it to the core loop.
        if matches!(state, CallState::Incoming(_) | CallState::Outgoing(_)) {
            if let Some(tx) = action_tx() {
                let _ = tx.try_send(CallAction::Proceed {
                    session_generation: session_generation(),
                    call_id: call_id.as_u64(),
                });
            }
        }
        Ok(())
    }

    fn handle_remote_audio_state(&self, _peer: &str, _enabled: bool) -> ringrtc::common::Result<()> {
        Ok(())
    }
    fn handle_remote_video_state(&self, _peer: &str, _enabled: bool) -> ringrtc::common::Result<()> {
        Ok(())
    }
    fn handle_remote_sharing_screen(
        &self,
        _peer: &str,
        _enabled: bool,
    ) -> ringrtc::common::Result<()> {
        Ok(())
    }
    fn handle_network_route(&self, _peer: &str, _route: NetworkRoute) -> ringrtc::common::Result<()> {
        Ok(())
    }
    fn handle_audio_levels(
        &self,
        _peer: &str,
        _captured: AudioLevel,
        _received: AudioLevel,
    ) -> ringrtc::common::Result<()> {
        Ok(())
    }
    fn handle_low_bandwidth_for_video(
        &self,
        _peer: &str,
        _recovered: bool,
    ) -> ringrtc::common::Result<()> {
        Ok(())
    }
}

struct CuztomGroupHandler;
impl GroupUpdateHandler for CuztomGroupHandler {
    fn handle_group_update(&self, _update: GroupUpdate) -> ringrtc::common::Result<()> {
        Ok(())
    }
}

struct CuztomHttpDelegate;
impl http::Delegate for CuztomHttpDelegate {
    fn send_request(&self, _request_id: u32, _request: http::Request) {}
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

fn ice_servers() -> Vec<IceServer> {
    vec![IceServer::new(
        String::new(),
        String::new(),
        String::new(),
        vec![
            "stun:stun.l.google.com:19302".to_string(),
            "stun:stun1.l.google.com:19302".to_string(),
        ],
    )]
}

#[derive(Clone, Copy, Default)]
struct NullVideoSink;
impl VideoSink for NullVideoSink {
    fn on_video_frame(&self, _demux_id: DemuxId, _frame: VideoFrame) {}
    fn box_clone(&self) -> Box<dyn VideoSink> {
        Box::new(Self)
    }
}

/// Select the first CoreAudio input/output when the native audio device module
/// has finished enumerating them. Failure is non-fatal: the default device
/// selected by WebRTC remains usable and the next call can retry setup.
fn select_default_audio_devices(pcf: &mut PeerConnectionFactory) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let playout = pcf.get_audio_playout_devices().unwrap_or_default();
        let recording = pcf.get_audio_recording_devices().unwrap_or_default();
        if !playout.is_empty() && !recording.is_empty() {
            if let Err(error) = pcf.set_audio_playout_device(0) {
                eprintln!("[core] select audio output failed: {error}");
            }
            if let Err(error) = pcf.set_audio_recording_device(0) {
                eprintln!("[core] select audio input failed: {error}");
            }
            return;
        }
        if std::time::Instant::now() >= deadline {
            eprintln!(
                "[core] audio devices not ready (playout={}, recording={}); using WebRTC defaults",
                playout.len(),
                recording.len()
            );
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Initialize the native RingRTC stack. This is called when the receive loop
/// starts, before the first inbound call can arrive.
pub fn init_calls() -> Result<(), String> {
    if CALL_MANAGER.get().is_some() {
        return Ok(());
    }

    let (signal_tx, signal_rx) = tokio::sync::mpsc::channel::<PendingCallSignal>(64);
    let (action_tx, action_rx) = tokio::sync::mpsc::channel::<CallAction>(64);
    let (event_tx, event_rx) = std::sync::mpsc::sync_channel::<String>(128);
    let _ = CALL_SIGNAL_TX.set(signal_tx);
    let _ = CALL_SIGNAL_RX.set(Mutex::new(Some(signal_rx)));
    let _ = CALL_ACTION_TX.set(action_tx);
    let _ = CALL_ACTION_RX.set(Mutex::new(Some(action_rx)));
    let _ = CALL_EVENT_TX.set(event_tx);
    let _ = CALL_EVENT_RX.set(Mutex::new(event_rx));

    let mut pcf = PeerConnectionFactory::new(
        &AudioConfig::default(),
        false,
        "",
        None,
    )
    .map_err(|e| format!("PeerConnectionFactory: {e}"))?;
    select_default_audio_devices(&mut pcf);

    let outgoing_audio_track: AudioTrack = pcf
        .create_outgoing_audio_track()
        .map_err(|e| format!("audio track: {e}"))?;
    let _ = CALL_AUDIO_TRACK.set(outgoing_audio_track.clone());
    let outgoing_video_source = pcf
        .create_outgoing_video_source()
        .map_err(|e| format!("video source: {e}"))?;
    let outgoing_video_track: VideoTrack = pcf
        .create_outgoing_video_track(&outgoing_video_source)
        .map_err(|e| format!("video track: {e}"))?;

    let call_context = NativeCallContext::new(
        false,
        ice_servers(),
        outgoing_audio_track,
        outgoing_video_track,
        Box::new(NullVideoSink),
    );
    let _ = CALL_CONTEXT.set(call_context);

    let platform = NativePlatform::new(
        pcf,
        Box::new(CuztomSignalingSender),
        false,
        Box::new(CuztomStateHandler),
        Box::new(CuztomGroupHandler),
    );
    let http_client = http::DelegatingClient::new(CuztomHttpDelegate);
    let call_manager = CallManager::new(platform, http_client)
        .map_err(|e| format!("CallManager: {e}"))?;
    let _ = CALL_MANAGER.set(Mutex::new(call_manager));
    eprintln!("[core] native RingRTC calls initialized");
    Ok(())
}

// ---------------------------------------------------------------------------
// Outbound call control
// ---------------------------------------------------------------------------

/// Start an outgoing call. The initial state callback will request `proceed`.
pub fn call_start(thread: &str, media_type: CallMediaType) -> Result<u64, String> {
    init_calls()?;
    let Some(manager) = manager() else {
        return Err("call manager is not initialized".to_string());
    };
    let id = CallId::random();
    let mut manager = manager
        .lock()
        .map_err(|_| "call manager lock poisoned".to_string())?;
    manager
        .create_outgoing_call(
            thread.to_string(),
            id,
            media_type,
            local_device_id(),
        )
        .map_err(|e| format!("create call: {e}"))?;
    Ok(id.as_u64())
}

pub fn call_accept(id: u64) -> Result<(), String> {
    let manager = manager().ok_or_else(|| "call manager is not initialized".to_string())?;
    manager
        .lock()
        .map_err(|_| "call manager lock poisoned".to_string())?
        .accept_call(CallId::new(id))
        .map_err(|e| format!("accept call: {e}"))
}

pub fn set_audio_muted(muted: bool) {
    if let Some(track) = CALL_AUDIO_TRACK.get() {
        track.set_enabled(!muted);
    }
}

pub fn call_hangup() -> Result<(), String> {
    let manager = manager().ok_or_else(|| "call manager is not initialized".to_string())?;
    manager
        .lock()
        .map_err(|_| "call manager lock poisoned".to_string())?
        .hangup()
        .map_err(|e| format!("hangup: {e}"))
}

/// Drop the active call without emitting signaling. Used during logout so a
/// queued hangup can never be delivered to a subsequently linked account.
pub fn drop_active_call() {
    let Some(manager) = manager() else { return };
    let Ok(mut manager) = manager.lock() else { return };
    if let Ok(call) = manager.active_call() {
        let _ = manager.drop_call(call.call_id());
    }
}

/// Execute an action requested by RingRTC's state callback.
pub fn call_action(action: CallAction) {
    let CallAction::Proceed {
        session_generation: action_generation,
        call_id,
    } = action;
    if action_generation != session_generation() {
        return;
    }
    let (Some(manager), Some(context)) = (manager(), context()) else {
        return;
    };
    let Ok(mut manager) = manager.lock() else { return };
    if let Err(error) = manager.proceed(
        CallId::new(call_id),
        context.clone(),
        CallConfig::default(),
        None,
    ) {
        eprintln!("[core] RingRTC proceed({call_id}) failed: {error}");
    }
}

pub fn call_message_sent(id: u64) {
    if let Some(manager) = manager() {
        if let Ok(mut manager) = manager.lock() {
            let _ = manager.message_sent(CallId::new(id));
        }
    }
}

pub fn call_message_send_failure(id: u64) {
    if let Some(manager) = manager() {
        if let Ok(mut manager) = manager.lock() {
            let _ = manager.message_send_failure(CallId::new(id));
        }
    }
}

// ---------------------------------------------------------------------------
// Inbound signaling
// ---------------------------------------------------------------------------

fn decode_opaque(signal: &serde_json::Value) -> Vec<u8> {
    signal
        .get("opaque")
        .and_then(|v| v.as_str())
        .and_then(|value| {
            base64::engine::general_purpose::STANDARD
                .decode(value)
                .ok()
        })
        .unwrap_or_default()
}

/// Feed one decoded `call_signal` event into RingRTC. The event was decoded
/// from a Signal `CallMessage`; its `opaque` is a RingRTC signaling protobuf.
fn ringrtc_identity_bytes(key: &libsignal_service::protocol::IdentityKey) -> Vec<u8> {
    // RingRTC's Signal integration expects the raw 32-byte public key. The
    // libsignal serialization includes a one-byte key-type prefix; Signal
    // Desktop strips it before passing the key to RingRTC as well.
    key.serialize().iter().copied().skip(1).collect()
}

fn service_id_from_wire(value: &str) -> Option<ServiceId> {
    let (is_pni, bare) = value
        .strip_prefix("PNI:")
        .map(|v| (true, v))
        .unwrap_or((false, value));
    let id = bare.parse::<uuid::Uuid>().ok()?;
    Some(if is_pni {
        ServiceId::Pni(Pni::from(id))
    } else {
        ServiceId::Aci(Aci::from(id))
    })
}

async fn identity_keys(
    manager: &StoredManager,
    remote_service: &str,
    local_service: &str,
    sender_device: u64,
) -> (Vec<u8>, Vec<u8>) {
    let local_sid = service_id_from_wire(local_service);
    let local = match local_sid {
        Some(ServiceId::Pni(_)) => match manager
            .store()
            .pni_protocol_store()
            .get_identity_key_pair()
            .await
        {
            Ok(pair) => ringrtc_identity_bytes(pair.identity_key()),
            Err(error) => {
                eprintln!("[core] call local PNI identity lookup failed: {error}");
                Vec::new()
            }
        },
        Some(ServiceId::Aci(_)) => match manager
            .store()
            .aci_protocol_store()
            .get_identity_key_pair()
            .await
        {
            Ok(pair) => ringrtc_identity_bytes(pair.identity_key()),
            Err(error) => {
                eprintln!("[core] call local identity lookup failed: {error}");
                Vec::new()
            }
        },
        None => Vec::new(),
    };

    let remote = match service_id_from_wire(remote_service) {
        Some(remote_sid) => {
            let device_u8 = u8::try_from(sender_device).unwrap_or(1).max(1);
            let device: SignalDeviceId = device_u8
                .try_into()
                .expect("Signal device id must be in the valid range");
            let address = ProtocolAddress::new(remote_sid.service_id_string(), device);
            let result = match remote_sid {
                ServiceId::Pni(_) => manager
                    .store()
                    .pni_protocol_store()
                    .get_identity(&address)
                    .await,
                ServiceId::Aci(_) => manager
                    .store()
                    .aci_protocol_store()
                    .get_identity(&address)
                    .await,
            };
            match result {
                Ok(Some(key)) => ringrtc_identity_bytes(&key),
                Ok(None) => {
                    eprintln!(
                        "[core] call remote identity not found for {remote_service}:{sender_device}"
                    );
                    Vec::new()
                }
                Err(error) => {
                    eprintln!("[core] call remote identity lookup failed: {error}");
                    Vec::new()
                }
            }
        }
        None => Vec::new(),
    };
    (remote, local)
}

pub async fn receive_call_signal(
    manager: &mut StoredManager,
    signal: &serde_json::Value,
) -> bool {
    let sender_service = signal.get("sender").and_then(|v| v.as_str()).unwrap_or("");
    let destination_service = signal
        .get("destination")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let kind = signal.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    if let Some(destination) = signal
        .get("destination_device_id")
        .and_then(|v| v.as_u64())
        .filter(|value| *value != 0)
    {
        if destination != u64::from(local_device_id()) {
            return false;
        }
    }
    if !matches!(kind, "offer" | "answer") {
        return call_received_with_keys(signal, Vec::new(), Vec::new());
    }
    let sender_device = signal
        .get("sender_device_id")
        .and_then(|v| v.as_u64())
        .unwrap_or(1);
    let (sender_key, receiver_key) = identity_keys(
        manager,
        sender_service,
        destination_service,
        sender_device,
    )
    .await;
    if sender_key.len() != 32 || receiver_key.len() != 32
    {
        eprintln!(
            "[core] ignoring {kind}: identity keys unavailable (sender={} receiver={})",
            sender_key.len(),
            receiver_key.len()
        );
        return false;
    }
    call_received_with_keys(signal, sender_key, receiver_key)
}

/// Compatibility entry point for callers that do not have a live store.
#[allow(dead_code)]
pub fn call_received(signal: &serde_json::Value) {
    let _ = call_received_with_keys(signal, Vec::new(), Vec::new());
}

fn call_received_with_keys(
    signal: &serde_json::Value,
    sender_identity_key: Vec<u8>,
    receiver_identity_key: Vec<u8>,
) -> bool {
    let kind = signal.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    let thread = signal.get("thread").and_then(|v| v.as_str()).unwrap_or("");
    if !thread.starts_with("contact:") {
        return false; // group calls are intentionally out of scope
    }
    let call_id = signal.get("call_id").and_then(|v| v.as_u64()).unwrap_or(0);
    let sender_device_id = signal
        .get("sender_device_id")
        .and_then(|v| v.as_u64())
        .unwrap_or(1) as DeviceId;
    let Some(manager) = manager() else { return false };
    let Ok(mut manager) = manager.lock() else { return false };
    let peer = thread.to_string();

    let result = match kind {
        "offer" => {
            let media = if signal.get("media_type").and_then(|v| v.as_str()) == Some("video") {
                CallMediaType::Video
            } else {
                CallMediaType::Audio
            };
            match Offer::new(media, decode_opaque(signal)) {
                Ok(offer) => manager.received_offer(
                    peer,
                    CallId::new(call_id),
                    ReceivedOffer {
                        offer,
                        age: Duration::from_millis({
                            let now_ms = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(0);
                            let message_ts = signal
                                .get("ts")
                                .and_then(|v| v.as_u64())
                                .filter(|value| *value != 0)
                                .unwrap_or(now_ms);
                            now_ms.saturating_sub(message_ts)
                        }),
                        sender_device_id,
                        receiver_device_id: local_device_id(),
                        // Identity keys are supplied by the caller below in the
                        // async path. Empty keys are retained only as a safe
                        // fallback for old events; current receive code fills
                        // them before invoking this function.
                        sender_identity_key: sender_identity_key.clone(),
                        receiver_identity_key: receiver_identity_key.clone(),
                    },
                ),
                Err(error) => Err(error),
            }
        }
        "answer" => match Answer::new(decode_opaque(signal)) {
            Ok(answer) => manager.received_answer(
                peer,
                CallId::new(call_id),
                ReceivedAnswer {
                    answer,
                    sender_device_id,
                    sender_identity_key: sender_identity_key.clone(),
                    receiver_identity_key: receiver_identity_key.clone(),
                },
            ),
            Err(error) => Err(error),
        },
        "ice" => {
            let mut candidates = Vec::new();
            if let Some(values) = signal.get("opaques").and_then(|v| v.as_array()) {
                for value in values {
                    if let Some(encoded) = value.as_str() {
                        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) {
                            candidates.push(IceCandidate { opaque: bytes });
                        }
                    }
                }
            }
            if candidates.is_empty() {
                candidates.push(IceCandidate { opaque: decode_opaque(signal) });
            }
            manager.received_ice(
                peer,
                CallId::new(call_id),
                ReceivedIce {
                    ice: Ice { candidates },
                    sender_device_id,
                },
            )
        }
        "hangup" => {
            let typ = signal.get("hangup_type").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let device_id = signal
                .get("device_id")
                .and_then(|v| v.as_u64())
                .unwrap_or(1) as DeviceId;
            let hangup = match typ {
                1 => signaling::Hangup::AcceptedOnAnotherDevice(device_id),
                2 => signaling::Hangup::DeclinedOnAnotherDevice(device_id),
                3 => signaling::Hangup::BusyOnAnotherDevice(device_id),
                4 => signaling::Hangup::NeedPermission(Some(device_id)),
                _ => signaling::Hangup::Normal,
            };
            manager.received_hangup(
                peer,
                CallId::new(call_id),
                ReceivedHangup {
                    hangup,
                    sender_device_id,
                },
            )
        }
        "busy" => manager.received_busy(
            peer,
            CallId::new(call_id),
            ReceivedBusy { sender_device_id },
        ),
        _ => Ok(()),
    };

    if let Err(error) = result {
        eprintln!("[core] RingRTC received {kind} failed: {error}");
        false
    } else {
        true
    }
}

// ---------------------------------------------------------------------------
// Existing protobuf helpers used by the FFI compatibility surface
// ---------------------------------------------------------------------------

pub fn build_offer_message(
    call_id: CallId,
    media_type: CallMediaType,
    opaque: Vec<u8>,
) -> ProtoCallMessage {
    ProtoCallMessage {
        offer: Some(ProtoOffer {
            id: Some(call_id.as_u64()),
            r#type: Some(match media_type {
                CallMediaType::Audio => 0,
                CallMediaType::Video => 1,
            }),
            opaque: Some(opaque),
        }),
        ..Default::default()
    }
}

pub fn build_answer_message(call_id: CallId, opaque: Vec<u8>) -> ProtoCallMessage {
    ProtoCallMessage {
        answer: Some(ProtoAnswer {
            id: Some(call_id.as_u64()),
            opaque: Some(opaque),
        }),
        ..Default::default()
    }
}

pub fn build_ice_message(call_id: CallId, opaque: Vec<u8>) -> ProtoCallMessage {
    ProtoCallMessage {
        ice_update: vec![ProtoIceUpdate {
            id: Some(call_id.as_u64()),
            opaque: Some(opaque),
        }],
        ..Default::default()
    }
}

pub fn build_hangup_message(
    call_id: CallId,
    hangup_type: u32,
    device_id: Option<u32>,
) -> ProtoCallMessage {
    ProtoCallMessage {
        hangup: Some(ProtoHangup {
            id: Some(call_id.as_u64()),
            r#type: Some(hangup_type as i32),
            device_id,
        }),
        ..Default::default()
    }
}

pub fn build_busy_message(call_id: CallId) -> ProtoCallMessage {
    ProtoCallMessage {
        busy: Some(ProtoBusy { id: Some(call_id.as_u64()) }),
        ..Default::default()
    }
}

pub fn parse_call_message(call: &ProtoCallMessage) -> Result<signaling::Message, String> {
    if let Some(offer) = &call.offer {
        let media = if offer.r#type.unwrap_or(0) == 1 {
            CallMediaType::Video
        } else {
            CallMediaType::Audio
        };
        return Offer::new(media, offer.opaque.clone().unwrap_or_default())
            .map(signaling::Message::Offer)
            .map_err(|e| e.to_string());
    }
    if let Some(answer) = &call.answer {
        return Answer::new(answer.opaque.clone().unwrap_or_default())
            .map(signaling::Message::Answer)
            .map_err(|e| e.to_string());
    }
    if !call.ice_update.is_empty() {
        return Ok(signaling::Message::Ice(Ice {
            candidates: call
                .ice_update
                .iter()
                .filter_map(|candidate| candidate.opaque.clone())
                .map(|opaque| IceCandidate { opaque })
                .collect(),
        }));
    }
    if let Some(hangup) = &call.hangup {
        let device_id = hangup.device_id.unwrap_or(1);
        let value = match hangup.r#type.unwrap_or(0) {
            1 => signaling::Hangup::AcceptedOnAnotherDevice(device_id),
            2 => signaling::Hangup::DeclinedOnAnotherDevice(device_id),
            3 => signaling::Hangup::BusyOnAnotherDevice(device_id),
            4 => signaling::Hangup::NeedPermission(Some(device_id)),
            _ => signaling::Hangup::Normal,
        };
        return Ok(signaling::Message::Hangup(value));
    }
    if call.busy.is_some() {
        return Ok(signaling::Message::Busy);
    }
    Err("CallMessage has no supported signaling field".to_string())
}

// ---------------------------------------------------------------------------
// libsignal transmit path (runs on the core LocalSet)
// ---------------------------------------------------------------------------

pub async fn send_call_signal(
    manager: &mut StoredManager,
    thread: &str,
    encoded_proto: &str,
) -> Result<(), String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded_proto)
        .map_err(|e| format!("call message base64: {e}"))?;
    let proto = ProtoCallMessage::decode(bytes.as_slice())
        .map_err(|e| format!("call message protobuf: {e}"))?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);

    let recipient = match crate::sync::parse_thread(thread)
        .map_err(|e| format!("call recipient: {e}"))?
    {
        presage::store::Thread::Contact(recipient) => recipient,
        presage::store::Thread::Group(_) => {
            return Err("group calls are not supported".to_string())
        }
    };

    // `Manager::send_message` sends to the Signal service first and then
    // persists the outgoing message locally. A local SQLite failure after
    // the wire send must not make RingRTC retry a message the peer already
    // received.
    match manager
        .send_message(recipient, ContentBody::CallMessage(proto), timestamp)
        .await
    {
        Ok(()) => Ok(()),
        Err(presage::Error::Store(error)) => {
            eprintln!("[core] call signal sent but local persistence failed: {error}");
            Ok(())
        }
        Err(error) => Err(format!("call signal send: {error}")),
    }
}

pub async fn transmit(manager: &mut StoredManager, pending: PendingCallSignal) -> Result<(), String> {
    if pending.session_generation != session_generation() {
        return Err("stale call session".to_string());
    }
    send_call_signal(manager, &pending.thread, &base64::engine::general_purpose::STANDARD.encode(pending.proto))
        .await
}
