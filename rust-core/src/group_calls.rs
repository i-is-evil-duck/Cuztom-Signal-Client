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

/// CDNs serve the membership proof at this path. Callers supply the CDN host.
pub const GROUP_TOKEN_PATH: &str = "v2/groups/token";

#[derive(Debug)]
pub enum GroupCallError {
    InvalidMasterKey,
    InvalidServiceId(String),
    Serialization(&'static str),
    EmptyGroupPublicParams,
}

impl std::fmt::Display for GroupCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GroupCallError::InvalidMasterKey => write!(f, "group master key must be 32 bytes"),
            GroupCallError::InvalidServiceId(id) => write!(f, "invalid service id: {id}"),
            GroupCallError::Serialization(what) => write!(f, "failed to serialize {what}"),
            GroupCallError::EmptyGroupPublicParams => {
                write!(f, "group public params serialized to an empty buffer")
            }
        }
    }
}

impl std::error::Error for GroupCallError {}

/// Days since the Unix epoch, the addressing Signal uses for credential
/// redemption.
pub fn current_redemption_day(now_secs: u64) -> u64 {
    now_secs / 86_400
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

/// Signal's `redemptionTime` is milliseconds since the epoch.
fn redemption_day_of(redemption_time_ms: u64) -> u64 {
    redemption_time_ms / 86_400_000
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
        // zkgroup serializes a leading ReservedByte that peers do not send.
        let member_id = serialize(&ciphertext);
        if member_id.len() <= 1 {
            return Err(GroupCallError::Serialization("member uid ciphertext"));
        }
        Ok(GroupMemberIdentity { user_id, member_id: member_id[1..].to_vec() })
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

    const DAY_MS: u64 = 86_400_000;

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
        let json = response_json(&[(day * DAY_MS, "QUJD")]);
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
        let json = response_json(&[(day * DAY_MS, "QUJD")]);
        let parsed: GroupAuthCredentialsResponse = serde_json::from_str(&json).expect("valid");
        // A neighbouring day must not borrow tomorrow's credential.
        assert!(parsed.credential_for_day(day + 1).is_none());
        assert!(parsed.credential_for_day(day - 1).is_none());
    }

    #[test]
    fn redemption_time_is_read_as_milliseconds() {
        // If milliseconds were treated as seconds the day would be off by 1000x.
        let day = 19_000u64;
        let parsed: GroupAuthCredentialsResponse =
            serde_json::from_str(&response_json(&[(day * DAY_MS, "QUJD")])).expect("valid");
        assert_eq!(parsed.days(), vec![day]);
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
    fn current_day_matches_wall_clock_math() {
        assert_eq!(current_redemption_day(0), 0);
        assert_eq!(current_redemption_day(DAY_MS * 2 / 1000), 2);
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
}
