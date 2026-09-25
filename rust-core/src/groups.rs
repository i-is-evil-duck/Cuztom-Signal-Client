// M2: GroupsV2 (zkgroup) support - STUB
// Exposes presage's GroupsManager functionality via FFI
// TODO: Implement actual group management once groups_manager() is accessible

use libsignal_service::prelude::{
    Group as ProtoGroup, GroupMasterKey, GroupSecretParams,
    Member, AccessControl, Timer,
    PendingMember, RequestingMember,
};
use libsignal_service::groups_v2::{
    GroupsManager, InMemoryCredentialsCache, decrypt_group,
};
use libsignal_service::protocol::Aci;
use libsignal_service::zkgroup;
use presage::manager::Manager;
use presage::manager::Registered;
use presage::model::groups::Group;
use presage::store::ContentsStore;
use presage_store_sqlite::SqliteStore;
use rand;

/// Fetch an encrypted group by its master key bytes (32 bytes hex)
/// Returns the decrypted group as JSON, or null on error
pub async fn get_group(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
) -> Result<String, String> {
    Err("not implemented".to_string())
}

/// Fetch group avatar by master key and avatar path
pub async fn get_group_avatar(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _avatar_path: &str,
) -> Result<Vec<u8>, String> {
    Err("not implemented".to_string())
}

/// Get the server public params for zkgroup (for generating invite links, etc.)
pub async fn get_zkgroup_params(
    _manager: &mut Manager<SqliteStore, Registered>,
) -> Result<String, String> {
    Err("not implemented".to_string())
}

/// List all groups known to the local store
pub async fn list_groups(
    _manager: &mut Manager<SqliteStore, Registered>,
) -> Result<String, String> {
    Ok("[]".to_string())
}

/// The group facts a group call needs: a display name and the member ACIs.
///
/// Returned as JSON so the host can render a roster and hand the ACIs to the
/// native member-identity builder without a second round trip. Membership is
/// needed because the SFU maps the opaque participant ids in call traffic back
/// to people through this group's encrypted-UID ciphertexts, so a call with no
/// roster connects but nobody can be identified.
///
/// A group this device is not an active member of is refused rather than
/// reported as empty: an empty roster reads as "you are alone in this group",
/// which is a different statement and the wrong one.
pub async fn group_roster(
    manager: &mut Manager<SqliteStore, Registered>,
    master_key_hex: &str,
) -> Result<String, String> {
    let group = active_group(manager, master_key_hex).await?;
    let members: Vec<String> = group
        .members
        .iter()
        .map(|member| member.aci.service_id_string())
        .collect();
    serde_json::to_string(&serde_json::json!({
        "title": group.title,
        "memberAciUUIDs": members,
    }))
    .map_err(|e| format!("group roster json: {e}"))
}

/// Map each ZK group id this device belongs to back to its master key.
///
/// An inbound group call names a ZK group id, and RingRTC will not create a
/// client for a group it has no client for, so the host needs this to turn an
/// inbound id into a group it can join. Groups this device has left are omitted
/// rather than mapped: a call for one is not receivable.
pub async fn group_id_map(
    manager: &mut Manager<SqliteStore, Registered>,
) -> Result<String, String> {
    let groups = manager
        .store()
        .groups()
        .await
        .map_err(|e| format!("group lookup: {e}"))?;
    let mut mapped: Vec<serde_json::Value> = Vec::new();
    for entry in groups {
        let Ok((master_key, group)) = entry else { continue };
        if group.members.is_empty() {
            continue;
        }
        let Ok(group_id) = crate::group_calls::group_id_hex_from_master_key(&hex::encode(master_key))
        else {
            continue;
        };
        mapped.push(serde_json::json!({
            "groupIdHex": group_id,
            "masterKeyHex": hex::encode(master_key),
        }));
    }
    serde_json::to_string(&mapped).map_err(|e| format!("group id map json: {e}"))
}

/// Look up a group by master key, refusing one this device has left.
async fn active_group(
    manager: &mut Manager<SqliteStore, Registered>,
    master_key_hex: &str,
) -> Result<Group, String> {
    let normalized = master_key_hex.trim().to_ascii_lowercase();
    let bytes: [u8; 32] = hex::decode(&normalized)
        .map_err(|_| "group master key must be hex".to_string())?
        .try_into()
        .map_err(|_| "group master key must be 32 bytes".to_string())?;
    let group = manager
        .store()
        .group(bytes)
        .await
        .map_err(|_| "no group with that master key".to_string())?
        .ok_or("no group with that master key".to_string())?;
    if group.members.is_empty() {
        return Err("this device is not a member of that group".to_string());
    }
    Ok(group)
}

/// Get group info by master key hex
pub async fn get_group_info(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
) -> Result<String, String> {
    Err("not implemented".to_string())
}

/// Update group title
pub async fn update_group_title(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _new_title: &str,
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Update group avatar
pub async fn update_group_avatar(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _avatar_data: &[u8],
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Add members to group
pub async fn add_group_members(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _member_acis: &[String],
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Remove members from group
pub async fn remove_group_members(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _member_acis: &[String],
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Promote member to admin
pub async fn promote_group_member(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _member_aci: &str,
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Demote member from admin
pub async fn demote_group_member(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
    _member_aci: &str,
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Get group invite link
pub async fn get_group_invite_link(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
) -> Result<String, String> {
    Err("not implemented".to_string())
}

/// Revoke group invite link
pub async fn revoke_group_invite_link(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
) -> Result<(), String> {
    Err("not implemented".to_string())
}

/// Leave group
pub async fn leave_group(
    _manager: &mut Manager<SqliteStore, Registered>,
    _master_key_hex: &str,
) -> Result<(), String> {
    Err("not implemented".to_string())
}