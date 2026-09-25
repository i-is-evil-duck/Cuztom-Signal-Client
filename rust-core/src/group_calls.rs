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
}
