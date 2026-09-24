// M2: GroupsV2 (zkgroup) support
// Exposes presage's GroupsManager functionality via FFI

use presage::{
    libsignal_service::groups_v2::{
        Group, GroupMasterKey, GroupSecretParams, ServerPublicParams,
    },
    manager::RegisteredManager,
    store::StateStore,
};
use std::sync::Arc;

/// Fetch an encrypted group by its master key bytes (32 bytes hex)
/// Returns the decrypted group as JSON, or null on error
pub async fn get_group(
    manager: &mut RegisteredManager,
    master_key_hex: &str,
) -> Result<String, String> {
    let master_key_bytes = hex::decode(master_key_hex)
        .map_err(|_| "invalid master key hex".to_string())?;
    if master_key_bytes.len() != 32 {
        return Err("master key must be 32 bytes".to_string());
    }
    
    let mut groups_mgr = manager.groups_manager().await
        .map_err(|e| format!("groups manager: {e}"))?;
    
    let mut csprng = rand::rng();
    let proto_group = groups_mgr.fetch_encrypted_group(&mut csprng, &master_key_bytes).await
        .map_err(|e| format!("fetch group: {e}"))?;
    
    let group: Group = proto_group.try_into()
        .map_err(|e| format!("decode group: {e}"))?;
    
    serde_json::to_string(&group)
        .map_err(|e| format!("serialize group: {e}"))
}

/// Fetch group avatar by master key and avatar path
pub async fn get_group_avatar(
    manager: &mut RegisteredManager,
    master_key_hex: &str,
    avatar_path: &str,
) -> Result<Vec<u8>, String> {
    let master_key_bytes = hex::decode(master_key_hex)
        .map_err(|_| "invalid master key hex".to_string())?;
    if master_key_bytes.len() != 32 {
        return Err("master key must be 32 bytes".to_string());
    }
    
    let mut groups_mgr = manager.groups_manager().await
        .map_err(|e| format!("groups manager: {e}"))?;
    
    let mut csprng = rand::rng();
    let master_key = GroupMasterKey::new(
        master_key_bytes.try_into().map_err(|_| "invalid master key length")?
    );
    let secret_params = GroupSecretParams::derive_from_master_key(master_key);
    
    groups_mgr.retrieve_avatar(avatar_path, secret_params).await
        .map_err(|e| format!("retrieve avatar: {e}"))
}

/// Get the server public params for zkgroup (for generating invite links, etc.)
pub async fn get_zkgroup_params(
    manager: &mut RegisteredManager,
) -> Result<String, String> {
    let groups_mgr = manager.groups_manager().await
        .map_err(|e| format!("groups manager: {e}"))?;
    
    let params = groups_mgr.server_public_params();
    let bytes = zkgroup::serialize(&params)
        .map_err(|e| format!("serialize params: {e}"))?;
    
    Ok(hex::encode(bytes))
}

/// List all groups known to the local store
pub async fn list_groups(
    manager: &mut RegisteredManager,
) -> Result<String, String> {
    // This would require access to the store's group listing
    // For now, return empty array - groups are discovered via sync
    Ok("[]".to_string())
}