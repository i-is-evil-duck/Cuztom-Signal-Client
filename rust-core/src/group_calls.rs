//! Group-call identity derivation and membership-proof request construction.
//!
//! Signal's group calls need two ZK-group values before RingRTC can even try to
//! join an SFU:
//!
//! * `group_id` — the 16-byte group identifier the SFU keys the room on.
//! * A *membership proof* — a token that authenticates this device to the SFU.
//!
//! The proof is not a separate calling-server protocol. Traced from Signal
//! Desktop 8.28.0, the client:
//!
//! 1. fetches ZK group auth credentials from the chat service
//!    (`GET /v1/certificate/auth/group?...&zkcCredential=true`),
//! 2. presents today's credential locally with the group's secret params via
//!    `AuthCredentialWithPniZkc::present`,
//! 3. redeems the presentation at the CDN: `GET {cdn}/v2/groups/token` with
//!    basic auth `hex(groupPublicParams) + ":" + hex(presentation)`,
//! 4. receives `ExternalGroupCredential { token }` and hands it to RingRTC.
//!
//! Everything except the two HTTP round trips is pure maths, so it lives here
//! and is unit tested offline. Nothing in this module performs I/O or invents
//! credentials: without a real server-issued credential the proof cannot be
//! built, and that is reported as an error rather than worked around.

use presage::libsignal_service::protocol::{Aci, ServiceId};
use presage::libsignal_service::zkgroup::{
    api::{
        auth::AuthCredentialWithPniZkc,
        groups::{GroupMasterKey, GroupPublicParams, GroupSecretParams},
        server_params::ServerPublicParams,
    },
    serialize, RandomnessBytes, GROUP_IDENTIFIER_LEN, GROUP_MASTER_KEY_LEN,
};
use uuid::Uuid;

/// The ZK group identifier the SFU keys a group call's room on.
pub const GROUP_CALL_GROUP_ID_LEN: usize = GROUP_IDENTIFIER_LEN;

/// Length of the encrypted-UID ciphertext a group call member id is made of.
///
/// zkgroup's `UuidCiphertext` is a one-byte `ReservedByte` followed by two
/// Ristretto points, and the whole thing is what gets hashed into a member's
/// opaque call id. Measured, not assumed — see `member`.
const GROUP_MEMBER_ID_LEN: usize = 1 + 64;

/// CDNs serve the membership proof at this path. Callers supply the CDN host.
pub const GROUP_TOKEN_PATH: &str = "v2/groups/token";

#[derive(Debug)]
pub enum GroupCallError {
    InvalidMasterKey,
    InvalidServiceId(String),
    Serialization(&'static str),
    EmptyGroupPublicParams,
    /// The server sent no credential valid on the requested day. Not
    /// substituted with a nearby one: that presents a credential the SFU will
    /// reject, and the rejection reads like a transport fault.
    NoCredentialForDay { day: u64, available: Vec<u64> },
    /// The response carried no PNI to bind the credential to.
    CredentialMissingPni,
    /// The credential did not verify against the server's public params, so it
    /// was not issued for this account, group, or time.
    CredentialRejected,
    /// A PNI was supplied where an ACI is required.
    NotAnAci,
    /// The response's `redemptionTime` is implausibly far from the present.
    ///
    /// The value is seconds, and the credential is bound to that exact instant,
    /// so a value nowhere near today means the response is not what it claims to
    /// be. Caught here because a wrong unit puts every credential in the same
    /// wrong place, and that otherwise surfaces only as an unexplained
    /// verification failure.
    ImplausibleRedemptionTime(u64),
    /// A group id of the wrong length. A ZK group identifier is 32 bytes, and a
    /// message built from any other length would name a room that cannot exist.
    InvalidGroupIdLength(usize),
}

impl std::fmt::Display for GroupCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GroupCallError::InvalidMasterKey => write!(f, "group master key must be 32 bytes"),
            GroupCallError::InvalidServiceId(id) => write!(f, "invalid service id: {id}"),
            GroupCallError::InvalidGroupIdLength(len) => write!(
                f,
                "group id was {len} bytes, expected {GROUP_CALL_GROUP_ID_LEN}"
            ),
            GroupCallError::Serialization(what) => write!(f, "failed to serialize {what}"),
            GroupCallError::EmptyGroupPublicParams => {
                write!(f, "group public params serialized to an empty buffer")
            }
            GroupCallError::NoCredentialForDay { day, available } => {
                if available.is_empty() {
                    write!(
                        f,
                        "no group auth credential was issued to this account for redemption day {day}"
                    )
                } else {
                    write!(
                        f,
                        "no group auth credential for redemption day {day}; the service returned days {available:?}"
                    )
                }
            }
            GroupCallError::CredentialMissingPni => {
                write!(f, "group credential response carried no PNI")
            }
            GroupCallError::CredentialRejected => {
                write!(f, "group auth credential failed verification")
            }
            GroupCallError::NotAnAci => write!(f, "group call proof requires an ACI, not a PNI"),
            GroupCallError::ImplausibleRedemptionTime(secs) => write!(
                f,
                "group credential redemptionTime {secs}s is not a plausible current timestamp"
            ),
        }
    }
}

impl std::error::Error for GroupCallError {}

/// Days since the Unix epoch, the addressing Signal uses for credential
/// redemption.
pub fn current_redemption_day(now_secs: u64) -> u64 {
    now_secs / 86_400
}

/// Seconds since the Unix epoch at which a redemption day begins.
///
/// The credential endpoint takes a *window in seconds*
/// (`redemptionStartSeconds`/`redemptionEndSeconds`), not a day index. Passing a
/// day number there asks for a window in 1970, which yields no credential and
/// leaves the join unable to proceed.
///
/// Saturating rather than wrapping: a start past the end of the window would
/// ask for a range that cannot exist, and refusing that is clearer than
/// silently asking for the wrong one.
pub fn redemption_day_start_seconds(day: u64) -> u64 {
    day.saturating_mul(86_400)
}

/// The `[start, end)` window to request credentials for, in seconds.
///
/// The end is the start of the following day rather than the last instant of
/// this one, because the service treats these as a half-open range and a
/// credential for the next day is not usable yet.
pub fn credential_window_seconds(day: u64) -> (u64, u64) {
    let start = redemption_day_start_seconds(day);
    let end = redemption_day_start_seconds(day.saturating_add(1));
    (start, end)
}

/// How many days either side of today to ask for.
///
/// A credential is issued per day and only becomes usable once its day arrives,
/// so the service commonly holds a small range around now rather than exactly
/// today. Asking for today alone can therefore come back empty on a day the
/// credential does exist, which looks identical to never having been issued one.
/// The surrounding days are only ever used to describe what is available: a
/// credential is still only ever presented for its own day.
pub const CREDENTIAL_DAYS_BEFORE: u64 = 1;
pub const CREDENTIAL_DAYS_AFTER: u64 = 2;

/// The window to request for `day`, widened either side.
pub fn credential_request_window_seconds(day: u64) -> (u64, u64) {
    let start = redemption_day_start_seconds(day.saturating_sub(CREDENTIAL_DAYS_BEFORE));
    let end = redemption_day_start_seconds(day.saturating_add(CREDENTIAL_DAYS_AFTER));
    (start, end)
}

/// One server-issued ZK auth credential.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ZkAuthCredential {
    /// Base64-encoded `AuthCredentialWithPniResponse` protobuf.
    pub credential: String,
    /// Signal's REST API uses camelCase even though the websocket proto does
    /// not. Strict on purpose: an unrecognised shape is rejected rather than
    /// partially interpreted.
    #[serde(rename = "redemptionTime")]
    /// **Seconds** since the Unix epoch, not milliseconds.
    ///
    /// Observed from the live service: a response for a window starting at
    /// 1790208000 returned `redemptionTime` values near 1.79e9, and dividing by
    /// 86_400 yields the redemption day (20721 for 2026-09-25). Dividing by
    /// 86_400_000 instead yields day 20 for every entry, which is how this was
    /// wrong for so long: the value is a plausible timestamp either way, so an
    /// offline test built on the wrong assumption agreed with itself.
    pub redemption_time: u64,
}

/// The `GET /v1/certificate/auth/group?zkcCredential=true` response.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct GroupAuthCredentialsResponse {
    /// PNI echoed back, when the server sends it. Checked against our own PNI
    /// by the caller when we have one.
    #[serde(default)]
    pub pni: Option<String>,
    #[serde(default)]
    pub credentials: Vec<ZkAuthCredential>,
}

impl GroupAuthCredentialsResponse {
    /// The credential valid on `day`, if the server sent one.
    ///
    /// The window is a range rather than a single day, so a credential is only
    /// returned when its redemption day actually falls inside it. Picking the
    /// nearest entry instead would let a stale or not-yet-valid credential be
    /// presented, which the SFU rejects and which is hard to diagnose.
    pub fn credential_for_day(&self, day: u64) -> Option<&ZkAuthCredential> {
        self.credentials.iter().find(|entry| {
            let entry_day = redemption_day_of(entry.redemption_time);
            entry_day == day
        })
    }

    /// Redemption days present in the response, ascending.
    pub fn days(&self) -> Vec<u64> {
        let mut days: Vec<u64> = self
            .credentials
            .iter()
            .map(|entry| redemption_day_of(entry.redemption_time))
            .collect();
        days.sort_unstable();
        days.dedup();
        days
    }
}

/// How far from `day` a credential's `redemptionTime` may be and still be
/// believed, in days.
///
/// Two days is enough to cover the requested window on either side plus a
/// little slack, while still rejecting a value that is off by a factor of a
/// thousand.
const REDEMPTION_TIME_TOLERANCE_DAYS: u64 = 2;

/// Reject a `redemptionTime` that cannot be a current timestamp in seconds.
///
/// This exists because the unit is easy to get wrong and impossible to notice:
/// milliseconds divided by the second constant still produces a small, entirely
/// plausible-looking day number, so the mistake only shows up much later as an
/// unexplained verification failure. The check is on the *value*, not on a
/// remainder, so it catches both a thousand-fold and a million-fold error.
fn check_redemption_time_is_current(
    redemption_time_secs: u64,
    requested_day: u64,
) -> Result<(), GroupCallError> {
    let day = redemption_day_of(redemption_time_secs);
    let low = requested_day.saturating_sub(REDEMPTION_TIME_TOLERANCE_DAYS);
    let high = requested_day.saturating_add(REDEMPTION_TIME_TOLERANCE_DAYS);
    if day < low || day > high {
        return Err(GroupCallError::ImplausibleRedemptionTime(
            redemption_time_secs,
        ));
    }
    Ok(())
}

/// The redemption day a credential's `redemptionTime` falls in.
///
/// The service sends **seconds**, matching zkgroup's own timestamp unit and the
/// `redemptionStartSeconds` window it was asked with. Dividing by the
/// millisecond constant instead maps every real credential to day 20, which is
/// a valid day and so fails silently rather than loudly.
fn redemption_day_of(redemption_time_secs: u64) -> u64 {
    redemption_time_secs / 86_400
}

/// Wrap RingRTC's encoded `signaling::CallMessage` in the Signal protocol
/// carrier used for group call signaling.
///
/// Signal reserves `CallMessage.opaque` (field 10) for payloads that are opaque
/// to the protocol layer but interpreted by RingRTC. The urgency maps one-to-one
/// onto Signal's `Opaque.Urgency`, where a missing value means `DROPPABLE`, so
/// it is always written explicitly.
pub fn wrap_group_call_signal(
    ringrtc_message: &[u8],
    handle_immediately: bool,
) -> Result<Vec<u8>, GroupCallError> {
    use presage::libsignal_service::proto::{
        call_message::Opaque as ProtoOpaque, CallMessage as ProtoCallMessage,
    };
    use prost::Message as _;

    if ringrtc_message.is_empty() {
        return Err(GroupCallError::Serialization("empty ringrtc payload"));
    }
    let proto = ProtoCallMessage {
        opaque: Some(ProtoOpaque {
            data: Some(ringrtc_message.to_vec()),
            urgency: Some(i32::from(handle_immediately)),
        }),
        ..Default::default()
    };
    Ok(proto.encode_to_vec())
}

/// Build the message that announces a group call to the group.
///
/// **Not sent by the host, and not the ring.** The host no longer composes group
/// call messages: RingRTC sends both the ring and the media-key messages, and
/// the ring specifically has to carry an `era_id` the host cannot know. What this
/// remains for is describing the shape RingRTC's own `group_call_message` takes —
/// a `DeviceToDevice` with only a `group_id` — so the receive path can be tested
/// against something that matches the wire, rather than against a shape invented
/// here. Kept because the receive path reads that field and the test is the only
/// thing proving the two agree.
///
/// A `group_call_message` carrying only `group_id` is the shape, and it is the
/// same structure the receive path reads a group id out of — so a peer that
/// understands this one understands a media key from the same field, and needs no
/// separate case.
///
/// Wrapped in `CallMessage.opaque` because that is the only carrier
/// `CallMessage` has: `offer`, `answer`, `iceUpdate`, `busy`, `hangup`,
/// `destinationDeviceId` and `opaque` are the complete set. The opaque payload
/// is RingRTC's own `signaling::CallMessage`, so a real client reads it with the
/// same parser this code does.
pub fn wrap_group_call_announce(group_id: &[u8]) -> Result<Vec<u8>, GroupCallError> {
    use presage::libsignal_service::proto::{
        call_message::Opaque as ProtoOpaque, CallMessage as ProtoCallMessage,
    };
    use ringrtc::protobuf::{
        group_call::DeviceToDevice, signaling::CallMessage as SignalCallMessage,
    };
    use prost::Message as _;

    if group_id.len() != GROUP_CALL_GROUP_ID_LEN {
        return Err(GroupCallError::InvalidGroupIdLength(group_id.len()));
    }
    let signal = SignalCallMessage {
        group_call_message: Some(DeviceToDevice {
            group_id: Some(group_id.to_vec()),
            ..Default::default()
        }),
        ..Default::default()
    };
    Ok(ProtoCallMessage {
        opaque: Some(ProtoOpaque {
            data: Some(signal.encode_to_vec()),
            // Droppable, matching the media key: a device that is not listening
            // for this call should not be woken for it.
            urgency: Some(0),
        }),
        ..Default::default()
    }
    .encode_to_vec())
}

/// Pull RingRTC's payload back out of a Signal `CallMessage`.
///
/// Used by the receive path. Returns `None` for a message that carries no
/// opaque payload, which is how a 1:1 call message is distinguished from a group
/// call message.
pub fn unwrap_group_call_signal(
    signal_proto: &[u8],
) -> Option<(Vec<u8>, bool)> {
    use presage::libsignal_service::proto::CallMessage as ProtoCallMessage;
    use prost::Message as _;

    let proto = ProtoCallMessage::decode(signal_proto).ok()?;
    let opaque = proto.opaque?;
    let data = opaque.data?;
    // Signal's enum: DROPPABLE = 0, HANDLE_IMMEDIATELY = 1. Anything else is
    // treated as droppable rather than trusted as immediate.
    let immediate = opaque.urgency.unwrap_or(0) == 1;
    Some((data, immediate))
}

/// The ZK group identifier for a 32-byte group master key.
///
/// This is the inverse of what RingRTC is given, and is how a signaling
/// message that names a group by identifier is routed back to the group it
/// belongs to.
pub fn group_id_for_master_key(master_key: &[u8]) -> Result<[u8; GROUP_CALL_GROUP_ID_LEN], GroupCallError> {
    let bytes: [u8; GROUP_MASTER_KEY_LEN] = master_key
        .try_into()
        .map_err(|_| GroupCallError::InvalidMasterKey)?;
    let secret_params = GroupSecretParams::derive_from_master_key(GroupMasterKey::new(bytes));
    let mut group_id = [0u8; GROUP_CALL_GROUP_ID_LEN];
    group_id.copy_from_slice(&secret_params.get_public_params().get_group_identifier());
    Ok(group_id)
}

/// The ZK identity a group call is made with, derived from the group master key.
pub struct GroupCallIdentity {
    secret_params: GroupSecretParams,
    public_params: GroupPublicParams,
    group_id: [u8; GROUP_CALL_GROUP_ID_LEN],
}

impl GroupCallIdentity {
    /// Derive from the 32-byte group master key that presage stores alongside
    /// each group. This is pure and offline.
    pub fn from_master_key(master_key: &[u8]) -> Result<Self, GroupCallError> {
        let bytes: [u8; GROUP_MASTER_KEY_LEN] = master_key
            .try_into()
            .map_err(|_| GroupCallError::InvalidMasterKey)?;
        let secret_params = GroupSecretParams::derive_from_master_key(GroupMasterKey::new(bytes));
        let public_params = secret_params.get_public_params();
        let group_id_bytes = public_params.get_group_identifier();
        let mut group_id = [0u8; GROUP_CALL_GROUP_ID_LEN];
        group_id.copy_from_slice(&group_id_bytes);
        Ok(Self { secret_params, public_params, group_id })
    }

    /// The 16-byte identifier the SFU keys the room on.
    pub fn group_id(&self) -> &[u8; GROUP_CALL_GROUP_ID_LEN] {
        &self.group_id
    }

    /// Serialized group public params, as used in the proof basic-auth header.
    pub fn public_params_bytes(&self) -> Vec<u8> {
        serialize(&self.public_params)
    }

    /// A RingRTC `GroupMember` pair for one ACI.
    ///
    /// `user_id` is the raw 16-byte ACI and `member_id` is the group's
    /// encrypted-UID ciphertext, which the SFU uses to map an opaque call
    /// participant id back to a group member.
    pub fn member(&self, aci_uuid: &str) -> Result<GroupMemberIdentity, GroupCallError> {
        let uuid = Uuid::parse_str(aci_uuid)
            .map_err(|_| GroupCallError::InvalidServiceId(aci_uuid.to_string()))?;
        let service_id: ServiceId = Aci::from(uuid).into();
        // `service_id_fixed_width_binary` is a 17-byte kind-prefixed form; the
        // SFU's user id is the bare 16-byte service id.
        let fixed = service_id.service_id_fixed_width_binary();
        let mut user_id = [0u8; 16];
        user_id.copy_from_slice(&fixed[1..17]);
        let ciphertext = self.secret_params.encrypt_service_id(service_id);
        // The whole serialization goes to the SFU, including zkgroup's leading
        // `ReservedByte` (`VersionByte<0>`, serialized as a single `0x00`).
        //
        // That byte is not ours to strip. It is part of the member id the SFU
        // hashes: RingRTC derives a participant's opaque id as
        // `hex(sha256(member_id))` over exactly these bytes, and the SFU derives
        // the same hash over the member id in the group credential. Dropping the
        // reserved byte produced a 64-byte value where the credential has 65, so
        // the two hashes could never agree, no participant could be resolved,
        // and the call was silent in both directions while looking perfectly
        // healthy.
        //
        // The failure is silent and total: an unresolvable participant is dropped
        // from RingRTC's device list without a word, an empty device list is
        // read as "nobody else is here", and that switches off audio recording,
        // outgoing media and playout together.
        //
        // Signal's own client passes the full serialization:
        // `encryptServiceId(aci).serialize()`.
        let member_id = serialize(&ciphertext);
        // 1 reserved byte + 2 Ristretto points. Checked rather than assumed,
        // because a length that is wrong here produces a call that connects and
        // is silent, with nothing anywhere reporting a fault.
        if member_id.len() != GROUP_MEMBER_ID_LEN {
            return Err(GroupCallError::Serialization("member uid ciphertext"));
        }
        Ok(GroupMemberIdentity { user_id, member_id })
    }

    /// Present a server-issued ZK auth credential for this group.
    ///
    /// Returns the exact string that becomes the CDN basic-auth credential:
    /// `hex(group public params) + ":" + hex(presentation)`.
    ///
    /// This deliberately cannot succeed without a real credential. There is no
    /// fallback and no synthesized token: the SFU would reject one anyway, and
    /// faking it would make the failure look like a transport bug.
    pub fn membership_proof_authorization(
        &self,
        server_params: &ServerPublicParams,
        credential: &AuthCredentialWithPniZkc,
        randomness: RandomnessBytes,
    ) -> Result<String, GroupCallError> {
        let presentation = credential.present(server_params, &self.secret_params, randomness);
        let presentation_bytes = serialize(&presentation);
        let public_params_bytes = self.public_params_bytes();
        if public_params_bytes.is_empty() {
            return Err(GroupCallError::EmptyGroupPublicParams);
        }
        Ok(format!(
            "{}:{}",
            hex_encode(&public_params_bytes),
            hex_encode(&presentation_bytes)
        ))
    }
}

/// Build the CDN authorization value for a group call membership proof.
///
/// This is the whole crypto half of a group-call join. The credential fetch and
/// the CDN redemption are I/O and happen elsewhere; everything between them is
/// here and is pure, so it can be tested offline.
///
/// 1. pick the credential whose redemption day is `day`,
/// 2. base64-decode and deserialize the `AuthCredentialWithPniResponse`,
/// 3. bind it to our ACI and the PNI the server echoed back,
/// 4. present it with the group's secret params and the server's public params.
///
/// The PNI is taken from the *response* rather than from local state because the
/// credential is bound to that specific (ACI, PNI) pair. A response without one
/// is refused rather than guessed at: presenting a credential against the wrong
/// identity produces an SFU rejection with no useful diagnostic.
pub fn build_proof_authorization(
    master_key: &[u8],
    credentials_json: &str,
    server_public_params: &ServerPublicParams,
    our_aci: ServiceId,
    day: u64,
) -> Result<String, GroupCallError> {
    use presage::libsignal_service::zkgroup::api::auth::{
        AuthCredentialWithPni, AuthCredentialWithPniResponse,
    };
    use presage::libsignal_service::zkgroup::Timestamp;
    use base64::Engine as _;

    let identity = GroupCallIdentity::from_master_key(master_key)?;
    let response: GroupAuthCredentialsResponse = serde_json::from_str(credentials_json)
        .map_err(|_| GroupCallError::Serialization("group credential response"))?;
    let entry = response
        .credential_for_day(day)
        .ok_or_else(|| GroupCallError::NoCredentialForDay {
            day,
            available: response.days(),
        })?;
    let pni_text = response
        .pni
        .as_deref()
        .ok_or(GroupCallError::CredentialMissingPni)?;
    let pni_uuid = pni_text
        .strip_prefix("PNI:")
        .unwrap_or(pni_text)
        .parse::<Uuid>()
        .map_err(|_| GroupCallError::InvalidServiceId(pni_text.to_string()))?;
    let aci = match our_aci {
        ServiceId::Aci(aci) => aci,
        // A PNI cannot be an ACI. Failing is the only safe answer: the
        // credential would be presented against a different identity.
        ServiceId::Pni(_) => return Err(GroupCallError::NotAnAci),
    };

    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&entry.credential)
        .map_err(|_| GroupCallError::Serialization("group credential base64"))?;
    let response = AuthCredentialWithPniResponse::new(&bytes)
        .map_err(|_| GroupCallError::Serialization("group credential body"))?;
    // The credential is bound to this exact instant, so a value nowhere near the
    // present means the unit is not what this code assumes. Catching it here
    // names the cause instead of leaving every presentation to fail
    // verification with a message that points at the credential rather than at
    // the arithmetic.
    check_redemption_time_is_current(entry.redemption_time, day)?;
    // The service sends seconds, which is the unit zkgroup's `Timestamp` uses,
    // so the value is passed through unchanged. Dividing by a thousand here
    // would bind the credential to 1970 and every presentation would fail
    // verification as an unexplained rejection.
    let credential = response
        .receive(
            server_public_params,
            aci,
            pni_uuid.into(),
            Timestamp::from_epoch_seconds(entry.redemption_time),
        )
        .map_err(|_| GroupCallError::CredentialRejected)?;
    // The enum has exactly one variant today. Unwrapping it explicitly means a
    // future version fails here, in this file, rather than being presented
    // through a version-wrapping helper that changes the bytes on the wire.
    let credential = match credential {
        AuthCredentialWithPni::Zkc(credential) => credential,
    };
    identity.membership_proof_authorization(
        server_public_params,
        &credential,
        proof_randomness(),
    )
}

/// Fresh randomness for one proof presentation.
///
/// `OsRng` panics if the OS cannot supply entropy, which is the correct outcome
/// here: a predictable presentation would be sent to the SFU and would fail
/// there with a diagnostic that points nowhere near the real cause.
fn proof_randomness() -> RandomnessBytes {
    use rand::RngCore as _;
    let mut randomness: RandomnessBytes = [0u8; presage::libsignal_service::zkgroup::RANDOMNESS_LEN];
    rand::rngs::OsRng.fill_bytes(&mut randomness);
    randomness
}

/// Why a group call signal did not yield a group id.
///
/// A `None` with no explanation is the whole reason inbound group calls were
/// invisible: the payload arrives, it is a group call message, and nothing says
/// which part of it was unusable. Group call traffic flows constantly in an
/// active group, so "we could not identify this" is a normal observation rather
/// than an error, and it is only actionable if it says what it saw.
///
/// **Field names only, never values.** A `media_key` carries an ratcheted
/// secret; its *presence* is diagnostic and its contents are not.
pub fn describe_group_call_signal(payload: &[u8]) -> String {
    use ringrtc::protobuf::signaling::CallMessage as SignalCallMessage;
    use prost::Message as _;

    let message = match SignalCallMessage::decode(payload) {
        Ok(message) => message,
        Err(e) => return format!("not a signaling CallMessage ({e})"),
    };
    let mut present: Vec<&str> = Vec::new();
    if message.group_call_message.is_some() {
        present.push("group_call_message");
    }
    if message.ring_intention.is_some() {
        present.push("ring_intention");
    }
    if message.ring_response.is_some() {
        present.push("ring_response");
    }
    if present.is_empty() {
        return "a signaling CallMessage with no field set".to_string();
    }
    let Some(device) = message.group_call_message.as_ref() else {
        // A ring intention names its group in its own field, so say that rather
        // than implying nothing was identified.
        if let Some(ring) = message.ring_intention.as_ref() {
            return match ring.group_id.as_ref() {
                None => "a ring_intention with no group_id".to_string(),
                Some(id) => format!(
                    "a ring_intention for a {} byte group id{}",
                    id.len(),
                    match ring.r#type {
                        Some(1) => " (cancelled)",
                        _ => " (ring)",
                    }
                ),
            };
        }
        return format!("a signaling CallMessage with {present:?} and no group_call_message");
    };
    let mut inner: Vec<&str> = Vec::new();
    if device.media_key.is_some() {
        inner.push("media_key");
    }
    if device.heartbeat.is_some() {
        inner.push("heartbeat");
    }
    if device.leaving.is_some() {
        inner.push("leaving");
    }
    if device.reaction.is_some() {
        inner.push("reaction");
    }
    if device.remote_mute_request.is_some() {
        inner.push("remote_mute_request");
    }
    match device.group_id.as_ref() {
        None => format!("a group_call_message with no group_id (fields: {inner:?})"),
        Some(id) if id.len() != GROUP_CALL_GROUP_ID_LEN => format!(
            "a group_id of {} bytes, expected {GROUP_CALL_GROUP_ID_LEN} (fields: {inner:?})",
            id.len()
        ),
        Some(_) => format!("a group_call_message with {inner:?}"),
    }
}

/// The ZK group identifier carried inside a RingRTC group call signal, as hex.
///
/// RingRTC does not create a group client when signaling arrives: it routes a
/// message to an existing, active client for that group and otherwise drops it
/// with "unknown group ID". So the host has to read the group out of the payload
/// itself before it can create a client to receive on. Signal's own carrier puts
/// it in `signaling::CallMessage.group_call_message.group_id`.
///
/// `None` for a payload that is not group call signaling, or whose group id is
/// not the expected length. [`describe_group_call_signal`] says which of those it
/// was.
pub fn group_id_hex_from_ringrtc_signal(payload: &[u8]) -> Option<String> {
    use ringrtc::protobuf::signaling::CallMessage as SignalCallMessage;
    use prost::Message as _;

    let message = SignalCallMessage::decode(payload).ok()?;
    // Three different fields can name a group, and reading only the first is why
    // inbound ring intentions were invisible: a `ring_intention` carries no
    // `group_call_message` at all, so a payload that names a group perfectly well
    // read as carrying none. Verified against RingRTC, which routes each of these
    // to a different handler.
    let candidate = message
        .group_call_message
        .as_ref()
        .and_then(|m| m.group_id.as_deref())
        .or_else(|| {
            message
                .ring_intention
                .as_ref()
                .and_then(|r| r.group_id.as_deref())
        })
        .or_else(|| {
            message
                .ring_response
                .as_ref()
                .and_then(|r| r.group_id.as_deref())
        })?;
    if candidate.len() != GROUP_CALL_GROUP_ID_LEN {
        return None;
    }
    Some(hex_encode(candidate))
}

/// A group ring request carried in a `ring_intention`.
///
/// This is Signal's group *ring*: a lightweight "someone is calling this group"
/// that arrives before anybody has joined the SFU, which is why it is the only
/// notification that can ring a device. Distinct from a group call signal, and
/// handled by RingRTC through `start_group_ring` rather than by a call client.
pub struct GroupRing {
    pub group_id_hex: String,
    /// `RING` or `CANCELLED`.
    pub cancelled: bool,
    /// Correlates the ring with its response and any later cancellation, so a
    /// stale ring cannot cancel a newer one.
    pub ring_id: i64,
}

/// Read a group ring out of a payload, if it is one.
pub fn group_ring_from_signal(payload: &[u8]) -> Option<GroupRing> {
    use ringrtc::protobuf::signaling::{call_message::RingIntention, CallMessage as SignalCallMessage};
    use prost::Message as _;

    let message = SignalCallMessage::decode(payload).ok()?;
    let ring = message.ring_intention?;
    let group_id = ring.group_id?;
    let ring_id = ring.ring_id?;
    if group_id.len() != GROUP_CALL_GROUP_ID_LEN {
        return None;
    }
    use ringrtc::protobuf::signaling::call_message::ring_intention::Type as IntentionType;
    let cancelled = ring
        .r#type
        .and_then(|t| IntentionType::try_from(t).ok())
        == Some(IntentionType::Cancelled);
    Some(GroupRing {
        group_id_hex: hex_encode(&group_id),
        cancelled,
        ring_id,
    })
}

/// RingRTC builds and sends the group ring itself.
///
/// **There is deliberately no `wrap_group_ring` here.** An earlier version
/// composed the `ring_intention` by hand and it was wrong in two ways that only
/// showed up against real clients: the `ring_id` has to be the SFU's `era_id`
/// (a value that never leaves RingRTC, since `Joined.era_id` is private), and
/// whether this client may ring at all is the SFU's decision via `joined.creator`.
/// Getting either wrong left RingRTC's `outgoing_ring_state` claiming someone
/// else had started the call, which it logs as "ringing is not permitted".
///
/// The ring is now requested through `CallManager::ring_group` — a small addition
/// to the vendored ringrtc — so it goes through RingRTC's own state machine. This
/// function does not exist so the mistake cannot be made again by someone reading
/// the file and concluding a ring is just a message to assemble.

/// The ZK group identifier for a hex-encoded group master key.
///
/// The host has group master keys (they are what a group thread id is made of)
/// but RingRTC is keyed on the derived identifier, so this bridges the two.
pub fn group_id_hex_from_master_key(master_key_hex: &str) -> Result<String, GroupCallError> {
    let normalized = master_key_hex.trim().to_ascii_lowercase();
    let bytes = hex::decode(&normalized).map_err(|_| GroupCallError::InvalidMasterKey)?;
    Ok(hex_encode(&group_id_for_master_key(&bytes)?))
}

/// The RingRTC member identities for a group, as JSON.
///
/// The SFU maps the opaque participant id it reports in call traffic back to a
/// group member through these, so a call with no member list has no roster and
/// no way to attribute who is speaking. Each entry carries the bare 16-byte
/// service id and this group's encrypted-UID ciphertext for the same member.
///
/// `member_acis` is the group's membership, as ACI UUID strings. An entry that
/// is not a valid service id fails the whole call rather than being skipped: a
/// partial roster silently misattributes call traffic.
pub fn member_identities_json(
    master_key_hex: &str,
    member_acis: &[String],
) -> Result<String, GroupCallError> {
    let normalized = master_key_hex.trim().to_ascii_lowercase();
    let bytes = hex::decode(&normalized).map_err(|_| GroupCallError::InvalidMasterKey)?;
    let identity = GroupCallIdentity::from_master_key(&bytes)?;
    let members: Vec<serde_json::Value> = member_acis
        .iter()
        .map(|aci| {
            let member = identity.member(aci)?;
            Ok(serde_json::json!({
                "userId": hex_encode(&member.user_id),
                "memberId": hex_encode(&member.member_id),
            }))
        })
        .collect::<Result<_, GroupCallError>>()?;
    serde_json::to_string(&members).map_err(|_| GroupCallError::Serialization("member identities"))
}

/// One member's identity as RingRTC's SFU client expects it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupMemberIdentity {
    /// Raw 16-byte service id.
    pub user_id: [u8; 16],
    /// Encrypted-UID ciphertext, reserved byte stripped.
    pub member_id: Vec<u8>,
}

/// Lowercase hex, matching the wire format Signal Desktop sends.
pub fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from_digit((byte >> 4) as u32, 16).expect("nibble is < 16"));
        out.push(char::from_digit((byte & 0x0f) as u32, 16).expect("nibble is < 16"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A member id is the *whole* zkgroup `UuidCiphertext`, reserved byte and
    /// all.
    ///
    /// RingRTC derives a participant's opaque id as `hex(sha256(member_id))`, and
    /// the SFU derives the same hash over the member id recorded in the group
    /// credential. Strip zkgroup's leading `ReservedByte` and the two hashes can
    /// never agree, so no participant resolves — and an unresolvable participant
    /// is dropped from RingRTC's device list without a word. An empty device list
    /// reads as "nobody else is here", which switches off audio recording,
    /// outgoing media and playout together, and the call is then silent in both
    /// directions while joining perfectly and reporting no error anywhere.
    ///
    /// This is the bug that made every group call silent, so the length and the
    /// leading byte are pinned rather than left to a comment.
    #[test]
    fn a_member_id_keeps_the_reserved_byte_the_sfu_hashes() {
        let master_key = hex::decode(&"ab".repeat(32)).expect("hex");
        let identity = GroupCallIdentity::from_master_key(&master_key).expect("identity");
        let member = identity
            .member("8c2f1a94-3b7d-4e65-9f01-2a6d5c8e7b40")
            .expect("member");

        assert_eq!(
            member.member_id.len(),
            65,
            "1 reserved byte + 2 Ristretto points; a 64-byte value can never match the SFU"
        );
        assert_eq!(
            member.member_id[0], 0,
            "zkgroup's ReservedByte is VersionByte<0>, serialized as a leading zero"
        );
        assert_eq!(
            member.user_id.len(),
            16,
            "the SFU's user id is the bare service id, not the 17-byte kind-prefixed form"
        );
    }

    /// Encrypting the same member twice must give the same member id.
    ///
    /// The SFU holds one member id per member, hashed. If our encryption were
    /// randomised the two would disagree on every call and the same silent,
    /// faultless failure would appear intermittently — which is much harder to
    /// diagnose than a consistent one, so this is worth pinning.
    #[test]
    fn a_member_id_is_the_same_every_time_it_is_derived() {
        let master_key = hex::decode(&"cd".repeat(32)).expect("hex");
        let identity = GroupCallIdentity::from_master_key(&master_key).expect("identity");
        let first = identity
            .member("8c2f1a94-3b7d-4e65-9f01-2a6d5c8e7b40")
            .expect("first");
        let second = identity
            .member("8c2f1a94-3b7d-4e65-9f01-2a6d5c8e7b40")
            .expect("second");
        assert_eq!(
            first.member_id, second.member_id,
            "uid encryption is deterministic, so a repeated derivation must be identical"
        );
    }

    /// Two members must not collide, or one could be attributed to the other.
    #[test]
    fn different_members_get_different_member_ids() {
        let master_key = hex::decode(&"ef".repeat(32)).expect("hex");
        let identity = GroupCallIdentity::from_master_key(&master_key).expect("identity");
        let a = identity.member("8c2f1a94-3b7d-4e65-9f01-2a6d5c8e7b40").expect("a");
        let b = identity.member("1b7d4e65-9f01-2a6d-5c8e-7b408c2f1234").expect("b");
        assert_ne!(a.member_id, b.member_id);
        assert_ne!(a.user_id, b.user_id);
    }

    #[test]
    fn a_group_call_announcement_names_the_group_and_carries_nothing_else() {
        use presage::libsignal_service::proto::CallMessage as ProtoCallMessage;
        use prost::Message as _;

        let group_id = [0x5Au8; GROUP_CALL_GROUP_ID_LEN];
        let bytes = wrap_group_call_announce(&group_id).expect("a 32 byte group id announces");

        // The carrier is `CallMessage.opaque`, which is the only field
        // `CallMessage` has for this: the rest are offer/answer/ice/busy/hangup.
        let outer = ProtoCallMessage::decode(bytes.as_slice()).expect("decodes as a CallMessage");
        assert!(
            outer.offer.is_none()
                && outer.answer.is_none()
                && outer.ice_update.is_empty()
                && outer.busy.is_none()
                && outer.hangup.is_none(),
            "an announcement must not look like a 1:1 call message"
        );
        let opaque = outer.opaque.expect("carried in opaque");
        assert_eq!(
            opaque.urgency.unwrap_or(0),
            0,
            "droppable, like the media key"
        );

        // The payload is RingRTC's own signaling message, and the group id is
        // readable out of it by the same function the receive path uses. That
        // round trip is the point: what we send, we must be able to read back.
        let (payload, immediate) =
            unwrap_group_call_signal(bytes.as_slice()).expect("reads back as a group signal");
        assert!(!immediate);
        assert_eq!(
            group_id_hex_from_ringrtc_signal(&payload).as_deref(),
            Some(hex_encode(&group_id).as_str()),
            "the announce path and the receive path must agree on the group id"
        );

        // A media key is deliberately absent: this is the announcement, not the
        // key exchange, and a key would imply an SFU join that has not happened.
        let inner = ringrtc::protobuf::signaling::CallMessage::decode(payload.as_slice())
            .expect("inner is a signaling CallMessage");
        let d2d = inner.group_call_message.expect("carries a group_call_message");
        assert!(d2d.media_key.is_none(), "no media key before the SFU join");
        assert!(d2d.heartbeat.is_none());
        assert!(d2d.leaving.is_none());
    }

    #[test]
    fn an_unidentifiable_group_call_signal_says_what_it_was() {
        use prost::Message as _;
        use ringrtc::protobuf::{
            group_call::{DeviceToDevice, device_to_device::MediaKey},
            signaling::CallMessage as SignalCallMessage,
        };

        let group_id = [0x11u8; GROUP_CALL_GROUP_ID_LEN];

        // A well-formed announcement is identified, and the description agrees.
        let announce = wrap_group_call_announce(&group_id).expect("announce");
        let (payload, _) = unwrap_group_call_signal(announce.as_slice()).expect("opaque");
        assert_eq!(
            group_id_hex_from_ringrtc_signal(&payload).as_deref(),
            Some(hex_encode(&group_id).as_str())
        );
        assert!(describe_group_call_signal(&payload).contains("group_call_message"));

        // A media key with no group id: the shape that produced "inbound signal
        // had no group id" with no further explanation.
        let no_group = SignalCallMessage {
            group_call_message: Some(DeviceToDevice {
                media_key: Some(MediaKey {
                    ratchet_counter: Some(3),
                    secret: Some(vec![0u8; 32]),
                    demux_id: Some(1),
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
        .encode_to_vec();
        assert!(group_id_hex_from_ringrtc_signal(&no_group).is_none());
        let described = describe_group_call_signal(&no_group);
        assert!(described.contains("no group_id"), "{described}");
        assert!(described.contains("media_key"), "{described}");
        // Field names, never the secret it carries.
        assert!(!described.contains("secret"), "{described}");

        // A group id of the wrong length names its length rather than just failing.
        let short = SignalCallMessage {
            group_call_message: Some(DeviceToDevice {
                group_id: Some(vec![0u8; 16]),
                ..Default::default()
            }),
            ..Default::default()
        }
        .encode_to_vec();
        assert!(describe_group_call_signal(&short).contains("16 bytes"));

        // Something that is not this message at all, and an empty one.
        assert!(describe_group_call_signal(&[0xff, 0xff, 0xff]).contains("not a signaling"));
        assert!(describe_group_call_signal(&[])
            .contains("no field set"));
    }

    /// A ring *received* must be readable, and the two halves must agree.
    ///
    /// The receive half is still ours: RingRTC owns sending, but the host has to
    /// turn an inbound `ring_intention` into a group id before it can show a
    /// banner, and it has to name the same group the sender did. This is built
    /// here by hand because it is a *test fixture* — the production path is
    /// RingRTC's own `ring_inner`, and composing a ring in production code is
    /// exactly the mistake this fixture is not.
    #[test]
    fn a_group_ring_is_readable_and_names_its_group() {
        use prost::Message as _;
        use ringrtc::protobuf::signaling::{
            call_message::{RingIntention, ring_intention::Type as IntentionType},
            CallMessage as SignalCallMessage,
        };
        use presage::libsignal_service::proto::{
            call_message::Opaque as ProtoOpaque, CallMessage as ProtoCallMessage,
        };

        let group_id = [0x7Bu8; GROUP_CALL_GROUP_ID_LEN];
        let fixture = SignalCallMessage {
            ring_intention: Some(RingIntention {
                group_id: Some(group_id.to_vec()),
                r#type: Some(IntentionType::Ring as i32),
                ring_id: Some(-4242),
            }),
            ..Default::default()
        }
        .encode_to_vec();
        let bytes = ProtoCallMessage {
            opaque: Some(ProtoOpaque {
                data: Some(fixture.clone()),
                urgency: Some(1),
            }),
            ..Default::default()
        }
        .encode_to_vec();

        // A ring is `ring_intention`, not `group_call_message`. That was the bug:
        // the group id was read only from `group_call_message`, so a payload that
        // named its group perfectly well read as naming none.
        let (payload, immediate) =
            unwrap_group_call_signal(bytes.as_slice()).expect("carried in opaque");
        assert!(immediate, "a ring must interrupt, not be dropped");

        let inner = SignalCallMessage::decode(payload.as_slice()).expect("decodes");
        assert!(inner.group_call_message.is_none(), "a ring is not a group call message");

        // Readable by the same function the receive path uses, and as a ring.
        assert_eq!(
            group_id_hex_from_ringrtc_signal(&payload).as_deref(),
            Some(hex_encode(&group_id).as_str())
        );
        let read = group_ring_from_signal(&payload).expect("reads as a ring");
        assert_eq!(read.group_id_hex, hex_encode(&group_id));
        assert!(!read.cancelled);
        assert_eq!(read.ring_id, -4242);
    }

    #[test]
    fn a_cancelled_ring_is_distinguished_from_a_requested_one() {
        use prost::Message as _;
        use ringrtc::protobuf::signaling::{
            call_message::{RingIntention, ring_intention::Type as IntentionType},
            CallMessage as SignalCallMessage,
        };

        let group_id = [0x22u8; GROUP_CALL_GROUP_ID_LEN];
        let cancelled = SignalCallMessage {
            ring_intention: Some(RingIntention {
                group_id: Some(group_id.to_vec()),
                r#type: Some(IntentionType::Cancelled as i32),
                ring_id: Some(9),
            }),
            ..Default::default()
        }
        .encode_to_vec();

        let read = group_ring_from_signal(&cancelled).expect("reads as a ring");
        assert!(read.cancelled, "a cancellation must not look like a call");
        // Still routable: the group id is there, so a cancellation can end the
        // right call.
        assert_eq!(read.group_id_hex, hex_encode(&group_id));
    }

    #[test]
    fn something_that_is_not_a_ring_is_not_read_as_one() {
        use prost::Message as _;
        use ringrtc::protobuf::{
            group_call::DeviceToDevice,
            signaling::CallMessage as SignalCallMessage,
        };

        // A group call signal names a group but is not a ring.
        let call = SignalCallMessage {
            group_call_message: Some(DeviceToDevice {
                group_id: Some(vec![0x33u8; GROUP_CALL_GROUP_ID_LEN]),
                ..Default::default()
            }),
            ..Default::default()
        }
        .encode_to_vec();
        assert!(group_ring_from_signal(&call).is_none());
        // But it is still identified, which is the other half of the fix.
        assert_eq!(
            group_id_hex_from_ringrtc_signal(&call).as_deref(),
            Some(hex_encode(&[0x33u8; GROUP_CALL_GROUP_ID_LEN]).as_str())
        );

        // A ring with no ring id cannot be correlated, so it is not a ring.
        let incomplete = SignalCallMessage {
            ring_intention: Some(ringrtc::protobuf::signaling::call_message::RingIntention {
                group_id: Some(vec![0x44u8; GROUP_CALL_GROUP_ID_LEN]),
                r#type: Some(0),
                ring_id: None,
            }),
            ..Default::default()
        }
        .encode_to_vec();
        assert!(group_ring_from_signal(&incomplete).is_none());

        assert!(group_ring_from_signal(&[]).is_none());
    }

    #[test]
    fn a_ringrtc_recipient_id_becomes_the_thread_it_is_addressed_by() {
        // A `UserId` is 16 fixed-width bytes and a thread is that uuid in text.
        // Getting the byte order wrong addresses the wrong person, and a message
        // to the wrong person fails silently - so this is pinned rather than
        // assumed.
        let uuid = uuid::Uuid::parse_str("11111111-2222-3333-4444-555555555555").expect("uuid");
        let bytes = uuid.as_bytes().to_vec();
        assert_eq!(
            crate::call::recipient_uuid_text_for_test(&bytes).as_deref(),
            Some("11111111-2222-3333-4444-555555555555")
        );
        // And the inverse, which is what a wrong order would produce.
        assert_eq!(
            crate::call::recipient_uuid_text_for_test(
                uuid.as_bytes().iter().rev().copied().collect::<Vec<u8>>().as_slice()
            )
            .as_deref(),
            Some("55555555-5555-4444-3333-222211111111"),
            "reversed bytes must not produce the same thread"
        );
        // Any other length is refused rather than padded into some address.
        assert!(crate::call::recipient_uuid_text_for_test(&[]).is_none());
        assert!(crate::call::recipient_uuid_text_for_test(&[0u8; 8]).is_none());
        assert!(crate::call::recipient_uuid_text_for_test(&[0u8; 32]).is_none());
    }

    #[test]
    fn a_targeted_group_signal_is_carried_in_the_same_opaque_envelope() {
        use prost::Message as _;
        use ringrtc::protobuf::{
            group_call::DeviceToDevice,
            signaling::CallMessage as SignalCallMessage,
        };

        let group_id = [0x91u8; GROUP_CALL_GROUP_ID_LEN];
        // A media key, which is what actually travels this way.
        let media = SignalCallMessage {
            group_call_message: Some(DeviceToDevice {
                group_id: Some(group_id.to_vec()),
                media_key: Some(ringrtc::protobuf::group_call::device_to_device::MediaKey {
                    ratchet_counter: Some(1),
                    secret: Some(vec![0u8; 32]),
                    demux_id: Some(9),
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
        .encode_to_vec();

        let bytes =
            wrap_group_call_signal(&media, false).expect("a targeted signal wraps the same way");
        let (payload, immediate) = unwrap_group_call_signal(bytes.as_slice()).expect("reads back");
        assert!(!immediate, "a media key is droppable, not an interruption");
        // Byte-identical: the recipient is the addressing, and the group id inside
        // is the receiver's routing key, not something to rewrite.
        assert_eq!(payload, media, "the payload must survive the envelope unchanged");
    }

    #[test]
    fn a_group_call_announcement_refuses_a_group_id_of_the_wrong_length() {
        // A group id that is not 32 bytes names a room that cannot exist, and
        // would be sent to every member of the group regardless.
        assert!(matches!(
            wrap_group_call_announce(&[0x5A; 16]),
            Err(GroupCallError::InvalidGroupIdLength(16))
        ));
        assert!(matches!(
            wrap_group_call_announce(&[]),
            Err(GroupCallError::InvalidGroupIdLength(0))
        ));
    }

    fn master_key(byte: u8) -> Vec<u8> {
        vec![byte; GROUP_MASTER_KEY_LEN]
    }

    #[test]
    fn group_id_is_deterministic_and_key_dependent() {
        let a = GroupCallIdentity::from_master_key(&master_key(1)).expect("valid key");
        let b = GroupCallIdentity::from_master_key(&master_key(1)).expect("valid key");
        let c = GroupCallIdentity::from_master_key(&master_key(2)).expect("valid key");

        assert_eq!(a.group_id(), b.group_id(), "same key must derive the same id");
        assert_ne!(a.group_id(), c.group_id(), "different keys must not collide");
        assert_eq!(a.group_id().len(), GROUP_CALL_GROUP_ID_LEN);
    }

    #[test]
    fn rejects_malformed_master_keys() {
        assert!(matches!(
            GroupCallIdentity::from_master_key(&[0u8; 31]),
            Err(GroupCallError::InvalidMasterKey)
        ));
        assert!(matches!(
            GroupCallIdentity::from_master_key(&[0u8; 33]),
            Err(GroupCallError::InvalidMasterKey)
        ));
    }

    #[test]
    fn public_params_are_stable_across_instances() {
        let a = GroupCallIdentity::from_master_key(&master_key(7)).expect("valid key");
        let b = GroupCallIdentity::from_master_key(&master_key(7)).expect("valid key");
        assert_eq!(a.public_params_bytes(), b.public_params_bytes());
        assert!(!a.public_params_bytes().is_empty());
    }

    #[test]
    fn member_identity_encrypts_per_group() {
        let a = GroupCallIdentity::from_master_key(&master_key(3)).expect("valid key");
        let b = GroupCallIdentity::from_master_key(&master_key(4)).expect("valid key");
        let aci = "11111111-1111-1111-1111-111111111111";

        let member_a = a.member(aci).expect("valid aci");
        let member_a_again = a.member(aci).expect("valid aci");
        let member_b = b.member(aci).expect("valid aci");

        assert_eq!(member_a.user_id, member_a_again.user_id);
        assert_eq!(member_a.member_id, member_a_again.member_id, "must be stable");
        assert_ne!(
            member_a.member_id, member_b.member_id,
            "the same ACI must encrypt differently under different groups"
        );
        assert!(!member_a.member_id.is_empty());
    }

    #[test]
    fn member_identity_rejects_bad_service_ids() {
        let id = GroupCallIdentity::from_master_key(&master_key(5)).expect("valid key");
        assert!(matches!(
            id.member("not-a-uuid"),
            Err(GroupCallError::InvalidServiceId(_))
        ));
    }

    #[test]
    fn hex_encoding_is_lowercase_and_padded() {
        assert_eq!(hex_encode(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
        assert_eq!(hex_encode(&[]), "");
    }

    // ---- credential response decoding ----

    /// Seconds in a day, which is the unit the service actually uses.
    const DAY_SECS: u64 = 86_400;
    /// A `redemptionTime` captured from a real response, for 2026-09-25. Taken
    /// from the live service rather than derived, because the whole point is to
    /// pin the wire format and a test built from an assumption only proves the
    /// assumption is self-consistent.
    const OBSERVED_REDEMPTION_TIME: u64 = 1_790_294_400;
    const OBSERVED_DAY: u64 = 20_721;

    fn response_json(entries: &[(u64, &str)]) -> String {
        let items: Vec<String> = entries
            .iter()
            .map(|(redemption_time, credential)| {
                format!(r#"{{"credential":"{credential}","redemptionTime":{redemption_time}}}"#)
            })
            .collect();
        format!(
            r#"{{"pni":"PNI:abc","credentials":[{}],"callLinkAuthCredentials":[]}}"#,
            items.join(",")
        )
    }

    #[test]
    fn decodes_a_credential_response() {
        let day = 19_000u64;
        let json = response_json(&[(day * DAY_SECS, "QUJD")]);
        let parsed: GroupAuthCredentialsResponse =
            serde_json::from_str(&json).expect("valid credential response");
        assert_eq!(parsed.pni.as_deref(), Some("PNI:abc"));
        assert_eq!(parsed.credentials.len(), 1);
        assert_eq!(parsed.credential_for_day(day).map(|c| c.credential.as_str()), Some("QUJD"));
        assert_eq!(parsed.days(), vec![day]);
    }

    #[test]
    fn a_day_without_a_credential_yields_none() {
        let day = 19_000u64;
        let json = response_json(&[(day * DAY_SECS, "QUJD")]);
        let parsed: GroupAuthCredentialsResponse = serde_json::from_str(&json).expect("valid");
        // A neighbouring day must not borrow tomorrow's credential.
        assert!(parsed.credential_for_day(day + 1).is_none());
        assert!(parsed.credential_for_day(day - 1).is_none());
    }

    #[test]
    fn redemption_time_is_read_as_seconds() {
        // The value is taken from a real response. Reading it as milliseconds
        // gives day 20 for every entry, which is a valid day and so fails
        // silently: that mistake is what kept this from working, because the
        // tests built on the wrong assumption agreed with the wrong assumption.
        let parsed: GroupAuthCredentialsResponse =
            serde_json::from_str(&response_json(&[(OBSERVED_REDEMPTION_TIME, "QUJD")]))
                .expect("valid");
        assert_eq!(parsed.days(), vec![OBSERVED_DAY]);
        assert!(parsed.credential_for_day(OBSERVED_DAY).is_some());
        // A millisecond reading would land on day 20, which is not this day.
        assert!(parsed.credential_for_day(20).is_none());
    }

    #[test]
    fn a_redemption_time_in_milliseconds_is_rejected_rather_than_presented() {
        // The unit error is caught where it happens instead of surfacing as an
        // unexplained verification failure. A millisecond value divided by the
        // second constant lands a thousand days out, which is the signature of
        // this exact mistake.
        let as_millis = OBSERVED_REDEMPTION_TIME * 1_000;
        let wrong_day = redemption_day_of(as_millis);
        assert_eq!(wrong_day, OBSERVED_DAY * 1_000);
        assert!(
            check_redemption_time_is_current(as_millis, OBSERVED_DAY).is_err(),
            "a millisecond value must never be presented"
        );
        assert!(matches!(
            check_redemption_time_is_current(as_millis, OBSERVED_DAY),
            Err(GroupCallError::ImplausibleRedemptionTime(_))
        ));
        // The real value passes.
        assert!(check_redemption_time_is_current(OBSERVED_REDEMPTION_TIME, OBSERVED_DAY).is_ok());
    }

    #[test]
    fn a_redemption_time_within_the_requested_window_is_accepted() {
        // The window brackets today, so neighbouring days are legitimate.
        for day in [
            OBSERVED_DAY - CREDENTIAL_DAYS_BEFORE,
            OBSERVED_DAY,
            OBSERVED_DAY + CREDENTIAL_DAYS_AFTER,
        ] {
            assert!(
                check_redemption_time_is_current(day * DAY_SECS, OBSERVED_DAY).is_ok(),
                "day {day} is inside the requested window"
            );
        }
        // Well outside it is not.
        assert!(check_redemption_time_is_current(
            (OBSERVED_DAY + 30) * DAY_SECS,
            OBSERVED_DAY
        )
        .is_err());
    }

    #[test]
    fn tolerates_a_response_with_no_credentials() {
        let parsed: GroupAuthCredentialsResponse =
            serde_json::from_str(r#"{"credentials":[]}"#).expect("valid");
        assert!(parsed.credential_for_day(19_000).is_none());
        assert!(parsed.days().is_empty());
        assert!(parsed.pni.is_none());
    }

    #[test]
    fn rejects_malformed_responses() {
        for bad in [
            "",
            "not json",
            r#"{"credentials":{}}"#,
            r#"{"credentials":[{"credential":123}]}"#,
            r#"{"credentials":[{"credential":"QUJD"}]}"#, // missing redemptionTime
        ] {
            assert!(
                serde_json::from_str::<GroupAuthCredentialsResponse>(bad).is_err(),
                "expected {bad} to be rejected"
            );
        }
    }

    #[test]
    fn the_credential_window_is_requested_in_seconds_not_days() {
        // The parameters are `redemptionStartSeconds`/`redemptionEndSeconds`.
        // A day index there asks the service for a window in 1970, which returns
        // no credential and leaves the join unable to proceed.
        let (start, end) = credential_window_seconds(19_675);
        assert_eq!(start, 19_675 * 86_400);
        assert_eq!(end, 19_676 * 86_400);
        // Well past 1970, and one day wide.
        assert!(start > 1_600_000_000, "start must be a real timestamp");
        assert_eq!(end - start, 86_400);
        // The window must be derived from the day, not the other way round: a
        // start that falls on a day boundary is what the response's
        // `redemptionTime` is measured against.
        assert_eq!(start / 86_400, 19_675);
    }

    #[test]
    fn the_window_covers_todays_credential_and_not_tomorrows() {
        // Half-open, so a credential for the next day is never requested. It
        // is not usable yet and presenting it would be rejected.
        let now_secs = 19_675 * 86_400 + 3_600;
        let day = current_redemption_day(now_secs);
        let (start, end) = credential_window_seconds(day);
        assert!(now_secs >= start, "today's credential is inside the window");
        assert!(now_secs < end);
    }

    #[test]
    fn an_absurd_day_saturates_rather_than_wrapping() {
        // Wrapping would produce a start *before* the end, asking for a window
        // that cannot exist.
        let (start, end) = credential_window_seconds(u64::MAX);
        assert!(start <= end, "the window must stay ordered");
    }

    #[test]
    fn current_day_matches_wall_clock_math() {
        assert_eq!(current_redemption_day(0), 0);
        assert_eq!(current_redemption_day(DAY_SECS * 2), 2);
    }

    // ---- identifier -> master key ----

    #[test]
    fn group_id_round_trips_through_the_master_key() {
        // Signaling names a group by identifier but the store keys it by master
        // key, so the two must be the same value.
        let key = master_key(9);
        let identity = GroupCallIdentity::from_master_key(&key).expect("valid key");
        let derived = group_id_for_master_key(&key).expect("valid key");
        assert_eq!(derived, *identity.group_id());
    }

    #[test]
    fn different_groups_resolve_to_different_identifiers() {
        assert_ne!(
            group_id_for_master_key(&master_key(1)).expect("valid"),
            group_id_for_master_key(&master_key(2)).expect("valid"),
        );
    }

    #[test]
    fn identifier_lookup_rejects_malformed_master_keys() {
        assert!(matches!(
            group_id_for_master_key(&[0u8; 31]),
            Err(GroupCallError::InvalidMasterKey)
        ));
    }

    // ---- opaque signaling carrier ----

    /// `CallMessage.opaque` is field 10, wire type 2, so its tag byte is
    /// `(10 << 3) | 2` = 0x52. Getting this wrong produces a message that
    /// decodes cleanly here and is ignored by every other Signal client.
    const OPAQUE_FIELD_TAG: u8 = (10 << 3) | 2;

    #[test]
    fn group_signal_uses_the_opaque_carrier_field() {
        let payload = [0xde, 0xad, 0xbe, 0xef];
        let encoded = wrap_group_call_signal(&payload, true).expect("wraps");
        assert_eq!(encoded.first().copied(), Some(OPAQUE_FIELD_TAG));
        let (data, immediate) = unwrap_group_call_signal(&encoded).expect("unwraps");
        assert_eq!(data, payload);
        assert!(immediate);
    }

    #[test]
    fn group_signal_round_trips_droppable_urgency() {
        let payload = vec![0x01, 0x02, 0x03];
        let encoded = wrap_group_call_signal(&payload, false).expect("wraps");
        let (data, immediate) = unwrap_group_call_signal(&encoded).expect("unwraps");
        assert_eq!(data, payload);
        assert!(!immediate, "droppable must not be read as immediate");
    }

    #[test]
    fn a_message_with_no_opaque_payload_is_not_a_group_signal() {
        // This is how a 1:1 call message is told apart from a group call
        // message on the receive path: a 1:1 message carries an offer or
        // answer and no opaque payload, so it unwraps to nothing.
        use presage::libsignal_service::proto::CallMessage as ProtoCallMessage;
        use prost::Message as _;

        let no_opaque = ProtoCallMessage {
            destination_device_id: Some(1),
            ..Default::default()
        };
        assert!(unwrap_group_call_signal(&no_opaque.encode_to_vec()).is_none());
        // An empty message has no opaque field either.
        assert!(unwrap_group_call_signal(&[]).is_none());
    }

    #[test]
    fn an_empty_ringrtc_payload_is_refused() {
        assert!(matches!(
            wrap_group_call_signal(&[], true),
            Err(GroupCallError::Serialization(_))
        ));
    }

    #[test]
    fn garbage_is_not_decoded_as_a_group_signal() {
        assert!(unwrap_group_call_signal(&[0xff, 0xff, 0xff, 0xff]).is_none());
    }

    // ---- membership proof construction ----
    //
    // A local ZK server issues credentials with the same code path the real
    // service uses, so the whole chain (deserialize, bind, present, format the
    // CDN authorization) is verified here without a network or a real account.
    // This is the closest thing to an end-to-end check available offline.

    use presage::libsignal_service::protocol::Pni;
    use presage::libsignal_service::zkgroup::api::{
        auth::{AuthCredentialWithPniResponse, AuthCredentialWithPniZkcResponse},
        server_params::ServerSecretParams,
    };
    use presage::libsignal_service::zkgroup::Timestamp;
    use base64::Engine as _;

    const ACI: &str = "11111111-1111-1111-1111-111111111111";
    const PNI: &str = "22222222-2222-2222-2222-222222222222";
    /// A fixed day boundary, which is what the service issues credentials for.
    const REDEMPTION_DAY: u64 = 19_675;
    const REDEMPTION_SECS: u64 = REDEMPTION_DAY * DAY_SECS;

    fn aci(text: &str) -> Aci {
        Aci::from(text.parse::<Uuid>().expect("uuid"))
    }

    fn pni(text: &str) -> Pni {
        Pni::from(text.parse::<Uuid>().expect("uuid"))
    }

    /// A local server plus a credential it issued for (ACI, PNI) on the given
    /// day, and the `GET /v1/certificate/auth/group` JSON that would carry it.
    fn issued_credential(for_aci: &str, for_pni: &str, day: u64) -> (ServerPublicParams, String) {
        let server_secret = ServerSecretParams::generate([1u8; 32]);
        let server_public = server_secret.get_public_params();
        let response = AuthCredentialWithPniResponse::Zkc(
            AuthCredentialWithPniZkcResponse::issue_credential(
                aci(for_aci),
                pni(for_pni),
                Timestamp::from_epoch_seconds(day * DAY_SECS),
                &server_secret,
                [2u8; 32],
            ),
        );
        let encoded = base64::engine::general_purpose::STANDARD.encode(serialize(&response));
        let json = format!(
            r#"{{"pni":"PNI:{for_pni}","credentials":[{{"credential":"{encoded}","redemptionTime":{}}}]}}"#,
            day * DAY_SECS
        );
        (server_public, json)
    }

    #[test]
    fn a_millisecond_redemption_time_is_refused() {
        // A response reporting milliseconds instead of seconds is refused rather
        // than presented. It is caught by the day lookup, which finds no
        // credential for the requested day, and the error says so rather than
        // letting a mismatched unit through to a verification failure.
        let (server_public, json) = issued_credential(ACI, PNI, REDEMPTION_DAY);
        let json = json.replace(
            &format!("\"redemptionTime\":{}", REDEMPTION_SECS),
            &format!("\"redemptionTime\":{}", REDEMPTION_SECS * 1_000),
        );
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            REDEMPTION_DAY,
        );
        assert!(
            matches!(result, Err(GroupCallError::NoCredentialForDay { .. })),
            "a millisecond redemptionTime must be refused, got {result:?}"
        );
    }

    #[test]
    fn a_membership_proof_is_built_from_a_real_credential() {        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(ACI, PNI, day);
        let key = master_key(7);
        let identity = GroupCallIdentity::from_master_key(&key).expect("valid key");

        let authorization =
            build_proof_authorization(&key, &json, &server_public, ServiceId::Aci(aci(ACI)), day)
                .expect("a server-issued credential produces a proof");

        // The shape is exactly what the CDN basic-auth header needs: the group's
        // public params, then the presentation, hex encoded and colon separated.
        let (public_hex, presentation_hex) = authorization
            .split_once(':')
            .expect("authorization is params:presentation");
        assert_eq!(
            public_hex,
            hex_encode(&identity.public_params_bytes()),
            "the proof must be for the group it was asked about"
        );
        assert!(
            presentation_hex.len() > 32,
            "a presentation is not an empty or stub value, got {presentation_hex:?}"
        );
        assert!(
            presentation_hex.chars().all(|c| c.is_ascii_hexdigit()),
            "presentation must be hex, got {presentation_hex:?}"
        );
    }

    #[test]
    fn a_credential_issued_to_another_account_is_refused() {
        // Presenting someone else's credential produces an SFU rejection with no
        // useful diagnostic, so it is caught here instead.
        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(
            "33333333-3333-3333-3333-333333333333",
            PNI,
            day,
        );
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day,
        );
        assert!(matches!(result, Err(GroupCallError::CredentialRejected)));
    }

    #[test]
    fn the_request_window_brackets_today() {
        // Asking for today alone can come back empty on a day a credential does
        // exist, which looks identical to never having been issued one.
        let (start, end) = credential_request_window_seconds(19_675);
        assert_eq!(start, (19_675 - CREDENTIAL_DAYS_BEFORE) * 86_400);
        assert_eq!(end, (19_675 + CREDENTIAL_DAYS_AFTER) * 86_400);
        // Today is strictly inside the requested window.
        assert!(start < 19_675 * 86_400);
        assert!(end > 19_676 * 86_400);
    }

    #[test]
    fn the_request_window_does_not_invert_at_the_epoch() {
        // Saturating subtraction keeps the window ordered at day zero.
        let (start, end) = credential_request_window_seconds(0);
        assert!(start <= end);
    }

    #[test]
    fn a_credential_for_another_day_is_not_borrowed() {
        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(ACI, PNI, day);
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day + 1,
        );
        assert!(matches!(
            result,
            Err(GroupCallError::NoCredentialForDay { day: d, .. }) if d == day + 1
        ));
    }

    #[test]
    fn a_credential_from_another_server_is_refused() {
        // A credential from a different ZK server must not verify, otherwise any
        // issuer could mint a proof.
        let day = REDEMPTION_DAY;
        let (_, json) = issued_credential(ACI, PNI, day);
        let other_server = ServerSecretParams::generate([9u8; 32]).get_public_params();
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &other_server,
            ServiceId::Aci(aci(ACI)),
            day,
        );
        assert!(matches!(result, Err(GroupCallError::CredentialRejected)));
    }

    #[test]
    fn a_proof_needs_a_pni_to_bind_the_credential_to() {
        let day = REDEMPTION_DAY;
        let (server_public, mut json) = issued_credential(ACI, PNI, day);
        json = json.replace(&format!(r#""pni":"PNI:{PNI}""#), r#""pni":null"#);
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day,
        );
        assert!(matches!(result, Err(GroupCallError::CredentialMissingPni)));
    }

    #[test]
    fn a_malformed_credential_body_is_refused() {
        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(ACI, PNI, day);
        // Valid base64, not a valid credential.
        let json = json.replace(&"\"credential\":\"", "\"credential\":\"!!!!");
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day,
        );
        assert!(matches!(result, Err(GroupCallError::Serialization(_))));
    }

    #[test]
    fn a_pni_cannot_stand_in_for_the_aci() {
        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(ACI, PNI, day);
        let result = build_proof_authorization(
            &master_key(7),
            &json,
            &server_public,
            ServiceId::Pni(pni(ACI)),
            day,
        );
        assert!(matches!(result, Err(GroupCallError::NotAnAci)));
    }

    #[test]
    fn a_proof_needs_a_32_byte_group_master_key() {
        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(ACI, PNI, day);
        let result = build_proof_authorization(
            &[0u8; 16],
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day,
        );
        assert!(matches!(result, Err(GroupCallError::InvalidMasterKey)));
    }

    // ---- host-facing derivations ----

    #[test]
    fn the_group_id_is_readable_out_of_an_inbound_signal() {
        // RingRTC drops signaling for a group it has no client for, so the host
        // has to learn the group from the payload to create one.
        use ringrtc::protobuf::{
            group_call::DeviceToDevice, signaling::CallMessage as SignalCallMessage,
        };
        use prost::Message as _;

        let identity = GroupCallIdentity::from_master_key(&master_key(8)).expect("valid");
        let expected = hex_encode(identity.group_id());
        let payload = SignalCallMessage {
            group_call_message: Some(DeviceToDevice {
                group_id: Some(identity.group_id().to_vec()),
                ..Default::default()
            }),
            ..Default::default()
        }
        .encode_to_vec();
        assert_eq!(
            group_id_hex_from_ringrtc_signal(&payload).as_deref(),
            Some(expected.as_str())
        );
    }

    #[test]
    fn a_signal_with_no_group_id_yields_nothing() {
        // A 1:1-shaped payload inside the opaque carrier is not a group signal.
        assert_eq!(group_id_hex_from_ringrtc_signal(&[]), None);
        assert_eq!(group_id_hex_from_ringrtc_signal(&[0xff, 0xff, 0xff]), None);
        use ringrtc::protobuf::{
            group_call::DeviceToDevice, signaling::CallMessage as SignalCallMessage,
        };
        use prost::Message as _;
        let no_group = SignalCallMessage {
            group_call_message: Some(DeviceToDevice::default()),
            ..Default::default()
        }
        .encode_to_vec();
        assert_eq!(group_id_hex_from_ringrtc_signal(&no_group), None);
    }

    #[test]
    fn a_wrong_length_group_id_is_not_accepted() {
        // Accepting a short id would make the host create a client for a room
        // that cannot exist, and the call would fail with no explanation.
        use ringrtc::protobuf::{
            group_call::DeviceToDevice, signaling::CallMessage as SignalCallMessage,
        };
        use prost::Message as _;
        for length in [0usize, 16, 33] {
            let payload = SignalCallMessage {
                group_call_message: Some(DeviceToDevice {
                    group_id: Some(vec![0x11u8; length]),
                    ..Default::default()
                }),
                ..Default::default()
            }
            .encode_to_vec();
            assert_eq!(group_id_hex_from_ringrtc_signal(&payload), None, "length {length}");
        }
    }

    #[test]
    fn the_group_id_is_reachable_from_a_group_master_key() {
        // A group thread id is the master key, and RingRTC is keyed on the
        // derived identifier, so the host has to be able to get from one to the
        // other without native help of another kind.
        let key = master_key(3);
        let hex = hex_encode(&key);
        let expected = hex_encode(
            GroupCallIdentity::from_master_key(&key).expect("valid").group_id(),
        );
        assert_eq!(group_id_hex_from_master_key(&hex).expect("derives"), expected);
        assert_eq!(expected.len(), GROUP_CALL_GROUP_ID_LEN * 2);
        // Case and surrounding whitespace come from wherever the thread id was
        // read, so they must not change the answer.
        assert_eq!(
            group_id_hex_from_master_key(&hex.to_uppercase()).expect("derives"),
            expected
        );
        assert_eq!(group_id_hex_from_master_key(&format!("  {hex}\n")).expect("derives"), expected);
    }

    #[test]
    fn a_malformed_group_master_key_has_no_identifier() {
        // A wrong-length key would otherwise scan the whole group list and
        // report "no local group matches", which points at the wrong thing.
        assert!(matches!(
            group_id_hex_from_master_key("nothex"),
            Err(GroupCallError::InvalidMasterKey)
        ));
        assert!(matches!(
            group_id_hex_from_master_key("aabb"),
            Err(GroupCallError::InvalidMasterKey)
        ));
    }

    #[test]
    fn member_identities_are_hex_and_pair_up() {
        let key = hex_encode(&master_key(4));
        let json = member_identities_json(&key, &[ACI.to_string(), PNI.to_string()])
            .expect("builds member identities");
        let parsed: Vec<serde_json::Value> = serde_json::from_str(&json).expect("valid JSON");
        assert_eq!(parsed.len(), 2);
        for entry in &parsed {
            let user_id = entry["userId"].as_str().expect("userId");
            let member_id = entry["memberId"].as_str().expect("memberId");
            // 16 bytes of service id, and a variable-length ciphertext that must
            // not be empty.
            assert_eq!(user_id.len(), 32, "user id is 16 bytes");
            assert!(user_id.chars().all(|c| c.is_ascii_hexdigit()));
            assert!(member_id.len() > 0);
            assert!(member_id.chars().all(|c| c.is_ascii_hexdigit()));
        }
        // Two different members must not share a ciphertext, or the SFU could
        // not tell them apart.
        assert_ne!(parsed[0]["memberId"], parsed[1]["memberId"]);
    }

    #[test]
    fn an_invalid_member_fails_the_whole_roster() {
        // A partial roster silently misattributes call traffic, so one bad
        // service id fails the request instead of being skipped.
        let key = hex_encode(&master_key(4));
        assert!(matches!(
            member_identities_json(&key, &[ACI.to_string(), "not-a-uuid".to_string()]),
            Err(GroupCallError::InvalidServiceId(_))
        ));
    }

    #[test]
    fn an_empty_group_has_an_empty_roster() {
        // A group of one is a valid state: the roster is just empty.
        let key = hex_encode(&master_key(4));
        let json = member_identities_json(&key, &[]).expect("builds");
        assert_eq!(json, "[]");
    }

    #[test]
    fn two_presents_of_one_credential_differ() {        // Fresh randomness per presentation: reusing one value would let an
        // observer link two calls to the same credential.
        let day = REDEMPTION_DAY;
        let (server_public, json) = issued_credential(ACI, PNI, day);
        let key = master_key(7);
        let first = build_proof_authorization(
            &key,
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day,
        )
        .expect("first presentation");
        let second = build_proof_authorization(
            &key,
            &json,
            &server_public,
            ServiceId::Aci(aci(ACI)),
            day,
        )
        .expect("second presentation");
        assert_ne!(first, second, "each presentation must use fresh randomness");
        // The group half is the same, because it identifies the group.
        assert_eq!(
            first.split_once(':').map(|(a, _)| a),
            second.split_once(':').map(|(a, _)| a)
        );
    }
}

