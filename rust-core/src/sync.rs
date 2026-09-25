//! M1b: roster / receive / send helpers shared by the FFI loop.
//!
//! Wire format to Swift (all JSON, UTF-8):
//!   roster: {"self":{"aci","number"},"contacts":[{"id","name","phone"}],
//!            "groups":[{"id","title"}],"messages":[message…]}
//!   message: {"key","thread","sender","sender_name","body","ts","outgoing"}
//!     thread = "contact:<uuid>" | "group:<hex master key>"
//!     key    = stable dedupe key "thread/client_ts/sender"
//!   event: {"type":"message","message":message}
//!          {"type":"contacts_synced"} | {"type":"queue_empty"}
//!          {"type":"sync_error","error":…} | {"type":"sync_ended"}

use std::collections::HashMap;

use presage::libsignal_service::content::{AttachmentPointer, Content, ContentBody};
use presage::libsignal_service::proto::sync_message::Content as SyncContent;
use presage::libsignal_service::proto::GroupContextV2;
use presage::libsignal_service::prelude::ProfileKey;
use presage::libsignal_service::protocol::{Aci, Pni, ServiceId};
use presage::manager::Registered;
use presage::model::messages::Received;
use presage::store::{ContentsStore, StateStore, Thread};

use presage::Manager;
use presage_store_sqlite::SqliteStore;

pub type StoredManager = Manager<SqliteStore, Registered>;

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn service_uuid(sid: &ServiceId) -> String {
    match sid {
        ServiceId::Aci(aci) => aci.service_id_string(),
        other => other.service_id_string(),
    }
}

pub(crate) fn parse_service_id(value: &str) -> Result<ServiceId, String> {
    let (is_pni, bare) = value
        .strip_prefix("PNI:")
        .map(|v| (true, v))
        .unwrap_or((false, value));
    let parsed: uuid::Uuid = bare.parse().map_err(|_| "bad contact id".to_string())?;
    Ok(if is_pni {
        ServiceId::Pni(Pni::from(parsed))
    } else {
        ServiceId::Aci(Aci::from(parsed))
    })
}

fn display_name(names: &HashMap<String, String>, uuid: &str) -> String {
    if let Some(n) = names.get(uuid) {
        if !n.is_empty() {
            return n.clone();
        }
    }
    "Unknown".to_string()
}

fn content_store_timestamp(content: &Content) -> u64 {
    if let ContentBody::SynchronizeMessage(sync) = &content.body {
        if let Some(SyncContent::Sent(sent)) = &sync.content {
            if let Some(timestamp) = sent.timestamp {
                return timestamp;
            }
        }
    }
    content.metadata.client_timestamp.timestamp_millis().max(0) as u64
}

fn has_chat_content(body: &str, attachments: &[AttachmentPointer], has_quote: bool) -> bool {
    !body.is_empty() || !attachments.is_empty() || has_quote
}

fn group_key_from_content(content: &Content) -> Option<&[u8]> {
    match &content.body {
        ContentBody::DataMessage(message) => message
            .group_v2
            .as_ref()
            .and_then(|group| group.master_key.as_deref()),
        ContentBody::EditMessage(edit) => edit.data_message.as_ref()?.group_v2.as_ref()?.master_key.as_deref(),
        ContentBody::SynchronizeMessage(sync) => {
            let sent = match &sync.content {
                Some(SyncContent::Sent(sent)) => sent,
                _ => return None,
            };
            sent.message
                .as_ref()
                .and_then(|message| message.group_v2.as_ref())
                .and_then(|group| group.master_key.as_deref())
                .or_else(|| {
                    sent.edit_message
                        .as_ref()
                        .and_then(|edit| edit.data_message.as_ref())
                        .and_then(|message| message.group_v2.as_ref())
                        .and_then(|group| group.master_key.as_deref())
                })
        }
        _ => None,
    }
}

/// `presage::store::Thread::try_from` panics on a malformed group key in
/// one group-edit branch. Validate group context before delegating so hostile
/// wire data becomes a dropped/error event, never a worker panic.
fn safe_thread_of_content(content: &Content) -> Option<Thread> {
    if let Some(key) = group_key_from_content(content) {
        let key: [u8; 32] = key.try_into().ok()?;
        return Some(Thread::Group(key));
    }
    Thread::try_from(content).ok()
}

/// Convert one decrypted `Content` into a wire message plus its raw
/// attachment pointers (downloaded separately by the caller).
/// Returns `None` for non-chat traffic (receipts, typing, calls…).
pub fn content_parts(
    content: &Content,
    self_aci: &str,
    names: &HashMap<String, String>,
) -> Option<(serde_json::Value, Vec<AttachmentPointer>)> {
    let meta = &content.metadata;
    let sender = service_uuid(&meta.sender);
    let ts = meta.server_timestamp.timestamp_millis().max(0) as u64;
    let store_ts = content_store_timestamp(content);
    match &content.body {
        ContentBody::DataMessage(m) => {
            let body = m.body.clone().unwrap_or_default();
            let outgoing = sender == self_aci;
            // Canonical thread derivation (group via master key, else 1:1).
            let thread = safe_thread_of_content(content)?;
            let thread_id = match &thread {
                Thread::Contact(sid) => {
                    // Outgoing envelope from this device: thread by recipient.
                    if outgoing {
                        format!("contact:{}", service_uuid(&meta.destination))
                    } else {
                        format!("contact:{}", service_uuid(sid))
                    }
                }
                Thread::Group(key) => format!("group:{}", hex::encode(key)),
            };
            let pointers = m.attachments.clone();
            if !has_chat_content(&body, &pointers, m.quote.is_some()) {
                return None;
            }
            Some((message_json(
                &thread_id,
                &sender,
                names,
                &body,
                ts,
                outgoing,
                &pointers,
                store_ts,
                m.quote.as_ref(),
            ), pointers))
        }
        ContentBody::SynchronizeMessage(s) => {
            let (body, pointers, quote) = match &s.content {
                Some(SyncContent::Sent(sent)) => (
                    sent.message.as_ref().and_then(|m| m.body.clone()).unwrap_or_default(),
                    sent.message.as_ref().map(|m| m.attachments.clone()).unwrap_or_default(),
                    sent.message.as_ref().and_then(|m| m.quote.as_ref()),
                ),
                _ => return None,
            };
            if !has_chat_content(&body, &pointers, quote.is_some()) {
                return None;
            }
            // Canonical thread derivation (sync-sent, group, 1:1). A
            // synchronized message authored by this account uses its
            // destination, just like an ordinary outgoing DataMessage.
            let thread_id = thread_of_content_for(content, self_aci)?;
            Some((message_json(
                &thread_id,
                self_aci,
                names,
                &body,
                ts,
                true,
                &pointers,
                store_ts,
                quote,
            ), pointers))
        }
        _ => None,
    }
}

/// Backwards-compatible single-value form (roster snapshots: metadata only).
pub fn content_event(
    content: &Content,
    self_aci: &str,
    names: &HashMap<String, String>,
) -> Option<serde_json::Value> {
    content_parts(content, self_aci, names).map(|(v, _)| v)
}

fn content_protocol_timestamp(content: &Content) -> u64 {
    match &content.body {
        ContentBody::DataMessage(message) => message.timestamp.unwrap_or(0),
        ContentBody::SynchronizeMessage(sync) => match &sync.content {
            Some(SyncContent::Sent(sent)) => sent
                .message
                .as_ref()
                .and_then(|message| message.timestamp)
                .unwrap_or(sent.timestamp.unwrap_or(0)),
            _ => 0,
        },
        _ => 0,
    }
}

fn reaction_details(content: &Content) -> Option<(u64, String, String, bool)> {
    let message = match &content.body {
        ContentBody::DataMessage(message) => message,
        ContentBody::SynchronizeMessage(sync) => match &sync.content {
            Some(SyncContent::Sent(sent)) => sent.message.as_ref()?,
            _ => return None,
        },
        _ => return None,
    };
    let reaction = message.reaction.as_ref()?;
    let target = reaction.target_sent_timestamp?;
    let emoji = reaction.emoji.clone().unwrap_or_default();
    if emoji.is_empty() {
        return None;
    }
    Some((
        target,
        service_uuid(&content.metadata.sender),
        emoji,
        reaction.remove.unwrap_or(false),
    ))
}

/// Aggregate the reaction envelopes stored for one thread. The presentation
/// model intentionally stores emoji values, so removals are applied per
/// sender/emoji while the result remains a compact display list.
fn reaction_summaries(contents: &[Content]) -> HashMap<u64, Vec<String>> {
    let mut ordered = contents.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|content| content_store_timestamp(content));
    let mut active: HashMap<u64, Vec<(String, String)>> = HashMap::new();
    for content in ordered {
        let Some((target, sender, emoji, remove)) = reaction_details(content) else {
            continue;
        };
        let entries = active.entry(target).or_default();
        if remove {
            entries.retain(|(existing_sender, existing_emoji)| {
                existing_sender != &sender || existing_emoji != &emoji
            });
        } else if !entries
            .iter()
            .any(|(existing_sender, existing_emoji)| existing_sender == &sender && existing_emoji == &emoji)
        {
            entries.push((sender, emoji));
        }
    }
    active
        .into_iter()
        .map(|(target, entries)| (target, entries.into_iter().map(|(_, emoji)| emoji).collect()))
        .collect()
}

fn add_reaction_summary(
    event: &mut serde_json::Value,
    content: &Content,
    summaries: &HashMap<u64, Vec<String>>,
) {
    for target in [content_store_timestamp(content), content_protocol_timestamp(content)] {
        if target != 0 {
            if let Some(emojis) = summaries.get(&target) {
                if !emojis.is_empty() {
                    event["reactions"] = serde_json::json!(emojis);
                }
                return;
            }
        }
    }
}

fn message_json(
    thread: &str,
    sender: &str,
    names: &HashMap<String, String>,
    body: &str,
    ts: u64,
    outgoing: bool,
    pointers: &[AttachmentPointer],
    store_ts: u64,
    quote: Option<&Quote>,
) -> serde_json::Value {
    // The client/store timestamp is stable across roster pagination, live
    // delivery, and linked-device sync. Server timestamps can differ between
    // those paths and must not create a second UUID for the same message.
    let identity_ts = if store_ts != 0 { store_ts } else { ts };
    let mut value = serde_json::json!({
        "key": format!("{thread}/{identity_ts}/{sender}"),
        "thread": thread,
        "sender": sender,
        "sender_name": display_name(names, sender),
        "body": body,
        // ts = server clock (display/sort). sts = store clock
        // (client_timestamp, the `ts` column) — the ONLY correct basis for
        // paging ranges and attachment lookups.
        "ts": ts,
        "sts": store_ts,
        "outgoing": outgoing,
        "attachments": pointers.iter().map(attachment_meta).collect::<Vec<_>>(),
    });
    if let Some(reply) = quote {
        value["reply_to"] = serde_json::json!({
            "target_sts": reply.id,
            "author": reply.author_aci,
            "body": reply.text,
        });
    }
    value
}

/// Metadata-only attachment descriptor (`path` filled after download).
fn attachment_meta(p: &AttachmentPointer) -> serde_json::Value {
    let mime = normalized_attachment_mime(p);
    let name = effective_attachment_name(p, &mime);
    serde_json::json!({
        "name": name,
        "mime": mime,
        "size": p.size.unwrap_or(0),
        "path": null,
    })
}

/// Signal occasionally reports a generic content type for CDN attachments.
/// Infer the type from the filename so GIF/image/audio previews are not
/// stranded behind a download button.
fn normalized_attachment_mime(p: &AttachmentPointer) -> String {
    let provided = p
        .content_type
        .as_deref()
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if provided.is_empty()
        || provided == "application/octet-stream"
        || provided == "binary/octet-stream"
    {
        guess_mime(std::path::Path::new(p.file_name.as_deref().unwrap_or("")))
    } else {
        provided
    }
}

fn mime_extension(mime: &str) -> Option<&'static str> {
    match mime {
        "image/gif" => Some("gif"),
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/webp" => Some("webp"),
        "image/heic" => Some("heic"),
        "video/mp4" => Some("mp4"),
        "video/quicktime" => Some("mov"),
        "video/webm" => Some("webm"),
        "audio/mpeg" => Some("mp3"),
        "audio/mp4" => Some("m4a"),
        "audio/aac" => Some("aac"),
        "audio/wav" => Some("wav"),
        "application/pdf" => Some("pdf"),
        _ => None,
    }
}

#[allow(dead_code)]
pub fn is_media_attachment(p: &AttachmentPointer) -> bool {
    let mime = normalized_attachment_mime(p);
    mime.starts_with("image/") || mime.starts_with("video/")
}

fn effective_attachment_name(p: &AttachmentPointer, mime: &str) -> String {
    let supplied = p.file_name.as_deref().unwrap_or("").trim();
    let base = if supplied.is_empty() {
        "attachment".to_string()
    } else {
        std::path::Path::new(supplied)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("attachment")
            .to_string()
    };
    if std::path::Path::new(&base).extension().is_some() {
        return base;
    }
    match mime_extension(mime) {
        Some(ext) => format!("{base}.{ext}"),
        None => base,
    }
}

/// Max auto-download per attachment (25 MB); larger stay metadata-only.
pub const MAX_AUTO_DOWNLOAD_BYTES: u32 = 25_000_000;
/// Keep the media cache bounded even when a user downloads many files.
pub const MAX_ATTACHMENT_CACHE_BYTES: u64 = 500_000_000;

fn caches_dir() -> std::path::PathBuf {
    std::env::var("HOME")
        .map(|h| std::path::PathBuf::from(h).join("Library/Caches/CuztomSignal"))
        .unwrap_or_else(|_| std::env::temp_dir().join("CuztomSignal"))
}

fn enforce_attachment_cache_quota() {
    let root = caches_dir();
    let Ok(entries) = std::fs::read_dir(&root) else { return };
    let mut files: Vec<(std::path::PathBuf, std::time::SystemTime, u64)> = Vec::new();
    let mut total = 0u64;
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(metadata) = std::fs::symlink_metadata(&path) else { continue };
        if !metadata.is_file() { continue; }
        let modified = metadata.modified().unwrap_or(std::time::UNIX_EPOCH);
        total = total.saturating_add(metadata.len());
        files.push((path, modified, metadata.len()));
    }
    if total <= MAX_ATTACHMENT_CACHE_BYTES { return; }
    files.sort_by_key(|(_, modified, _)| *modified);
    for (path, _, size) in files {
        if total <= MAX_ATTACHMENT_CACHE_BYTES { break; }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(size);
        }
    }
}

fn attachment_path(thread_id: &str, ts: u64, index: usize, name: &str) -> std::path::PathBuf {
    let safe_thread: String = thread_id
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect();
    let safe_name: String = std::path::Path::new(name)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("attachment")
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '.' || c == '-' || c == '_' { c } else { '_' })
        .collect();
    caches_dir().join(format!("{safe_thread}-{ts}-{index}-{safe_name}"))
}

/// Download one attachment through the live manager, store under Caches,
/// return the absolute path. Skips oversized bodies.
pub async fn download_attachment(
    manager: &mut StoredManager,
    ptr: &AttachmentPointer,
    thread_id: &str,
    ts: u64,
    index: usize,
) -> Result<Option<String>, String> {
    let Some(size) = ptr.size else {
        // Unknown-size CDN objects are not safe to auto-buffer. Keep them
        // metadata-only until a future streaming transfer can enforce a cap.
        return Ok(None);
    };
    if size > MAX_AUTO_DOWNLOAD_BYTES {
        return Ok(None);
    }
    let mime = normalized_attachment_mime(ptr);
    let name = effective_attachment_name(ptr, &mime);
    let dest = attachment_path(thread_id, ts, index, &name);
    if dest.exists() {
        enforce_attachment_cache_quota();
        return Ok(Some(dest.to_string_lossy().into_owned()));
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("cache dir: {e}"))?;
    }
    let bytes = manager
        .get_attachment(ptr)
        .await
        .map_err(|e| format!("download: {e}"))?;
    if bytes.len() as u64 > MAX_AUTO_DOWNLOAD_BYTES as u64 {
        return Err("downloaded attachment exceeds the auto-download limit".to_string());
    }
    eprintln!("[core] attachment downloaded bytes={} -> {}", bytes.len(), dest.display());
    std::fs::write(&dest, &bytes).map_err(|e| format!("cache write: {e}"))?;
    enforce_attachment_cache_quota();
    Ok(Some(dest.to_string_lossy().into_owned()))
}

/// Parse a wire thread id back into a store `Thread`.
pub fn parse_thread(thread_id: &str) -> Result<Thread, String> {
    if let Some(hexkey) = thread_id.strip_prefix("group:") {
        let bytes = hex::decode(hexkey).map_err(|_| "bad group id".to_string())?;
        let arr: [u8; 32] = bytes.try_into().map_err(|_| "bad group id".to_string())?;
        Ok(Thread::Group(arr))
    } else if let Some(uuid) = thread_id.strip_prefix("contact:") {
        Ok(Thread::Contact(parse_service_id(uuid)?))
    } else {
        Err("bad thread id".to_string())
    }
}

/// Page of messages for one thread (newest `limit` with store-clock ts
/// below `before_sts`; `u64::MAX` = latest). Metadata only — attachments
/// fetch on demand via `fetch_attachment`.
pub async fn thread_page(
    store: &SqliteStore,
    thread_id: &str,
    limit: usize,
    before_sts: u64,
) -> Result<String, String> {
    let reg = store
        .load_registration_data()
        .await
        .map_err(|e| format!("registration: {e}"))?
        .ok_or_else(|| "not linked".to_string())?;
    let self_aci = reg.service_ids.aci.to_string();
    let names = load_names(store).await;
    let thread = parse_thread(thread_id)?;
    // The store casts bounds to i64: clamp u64::MAX ("latest") or it wraps
    // to -1 and matches nothing. Real timestamps always fit in i64.
    let before = before_sts.min(i64::MAX as u64);
    if limit == 0 {
        return serde_json::to_string(&serde_json::json!({ "messages": [] }))
            .map_err(|e| format!("encode thread: {e}"));
    }
    let mut msgs: Vec<Content> = store
        .messages(&thread, ..before)
        .await
        .map_err(|e| format!("messages: {e}"))?
        .filter_map(|m| m.ok())
        .collect();
    // Paging is based on the store clock. Filter control envelopes before
    // applying the limit so a page of receipts/typing cannot hide older chat.
    msgs.sort_by_key(|m| content_store_timestamp(m));
    let reaction_summaries = reaction_summaries(&msgs);
    let mut page: Vec<serde_json::Value> = Vec::with_capacity(limit);
    for message in msgs.iter().rev() {
        if let Some(mut event) = content_event(message, &self_aci, &names) {
            if event.get("thread").and_then(|value| value.as_str()) != Some(thread_id) {
                continue;
            }
            add_reaction_summary(&mut event, message, &reaction_summaries);
            page.push(event);
            if page.len() == limit { break; }
        }
    }
    page.reverse();
    serde_json::to_string(&serde_json::json!({ "messages": page }))
        .map_err(|e| format!("encode thread: {e}"))
}

/// Download attachment `index` of the message with store-clock ts `sts`
/// in `thread_id`.
pub async fn fetch_attachment(
    manager: &mut StoredManager,
    thread_id: &str,
    sts: u64,
    index: usize,
) -> Result<String, String> {
    let thread = parse_thread(thread_id)?;
    let store = manager.store().clone();
    let mut msgs: Vec<Content> = store
        .messages(&thread, ..=sts)
        .await
        .map_err(|e| format!("messages: {e}"))?
        .filter_map(|m| m.ok())
        .collect();
    msgs.sort_by_key(|m| m.metadata.server_timestamp);
    // The store range is over the client (store-clock) timestamp; match the
    // newest row at or below the requested mark.
    let content = msgs
        .iter()
        .rev()
        .find(|m| content_store_timestamp(m) <= sts)
        .ok_or_else(|| "message not found".to_string())?;
    let pointers: Vec<AttachmentPointer> = match &content.body {
        ContentBody::DataMessage(m) => m.attachments.clone(),
        ContentBody::SynchronizeMessage(s) => match &s.content {
            Some(SyncContent::Sent(sent)) => sent
                .message
                .as_ref()
                .map(|m| m.attachments.clone())
                .unwrap_or_default(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    };
    let ptr = pointers.get(index).ok_or_else(|| "no such attachment".to_string())?;
    download_attachment(manager, ptr, thread_id, sts, index)
        .await?
        .ok_or_else(|| "attachment too large to auto-fetch".to_string())
}

/// uuid-string -> display name for every synced contact.
pub async fn load_names(store: &SqliteStore) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let contacts: Vec<_> = match store.contacts().await {
        Ok(iter) => iter.filter_map(|c| c.ok()).collect(),
        Err(_) => Vec::new(),
    };
    for c in contacts {
        let id = c.uuid.to_string();
        let label = if c.name.is_empty() {
            c.phone_number
                .as_ref()
                .map(|p| p.to_string())
                .unwrap_or_else(|| "Unknown".to_string())
        } else {
            c.name.clone()
        };
        map.insert(id, label);
    }
    map
}

/// Find the group master key for a ZK group identifier.
///
/// Group call signaling names a group by its 32-byte identifier, but the local
/// store and the send path are both keyed by master key. Each known group's
/// identifier is derived and compared; no result is cached, so a stale entry
/// can never route a signal to the wrong group.
pub async fn group_master_key_for_id(
    manager: &StoredManager,
    group_id: &[u8],
) -> Result<[u8; 32], String> {
    if group_id.is_empty() {
        return Err("group call signal had no group id".to_string());
    }
    let groups = manager
        .store()
        .groups()
        .await
        .map_err(|e| format!("group lookup: {e}"))?;
    for entry in groups {
        let Ok((master_key, _)) = entry else { continue };
        let bytes: [u8; 32] = match master_key.as_slice().try_into() {
            Ok(bytes) => bytes,
            Err(_) => continue,
        };
        let derived = crate::group_calls::group_id_for_master_key(&bytes)
            .map_err(|e| format!("group id derivation: {e}"))?;
        if derived.as_slice() == group_id {
            return Ok(bytes);
        }
    }
    Err("no local group matches that identifier".to_string())
}

async fn group_member_profile_key(manager: &StoredManager, aci: Aci) -> Option<ProfileKey> {    let groups = manager.store().groups().await.ok()?;
    for entry in groups {
        let Ok((_, group)) = entry else { continue };
        if let Some(member) = group.members.iter().find(|member| member.aci == aci) {
            return Some(member.profile_key);
        }
    }
    None
}

/// Display name from the Signal profile (for contacts added by phone
/// number, whose synced contact row has no name). Needs the contact's
/// profile key, which only exists after at least one message exchange —
/// otherwise errors and the caller keeps the fallback label.
pub async fn profile_name(manager: &mut StoredManager, uuid: &str) -> Result<String, String> {
    let sid = parse_service_id(uuid)?;
    let aci = match sid {
        ServiceId::Aci(aci) => aci,
        ServiceId::Pni(_) => return Err("PNI profile lookup needs an ACI alias".to_string()),
    };
    let key = match manager.store().profile_key(&ServiceId::Aci(aci)).await {
        Ok(Some(key)) => key,
        Ok(None) => group_member_profile_key(manager, aci)
            .await
            .ok_or_else(|| "no profile key yet".to_string())?,
        Err(e) => return Err(format!("profile key: {e}")),
    };
    let profile = manager
        .retrieve_profile_by_uuid(aci, key)
        .await
        .map_err(|e| format!("profile: {e}"))?;
    let name = profile.name.ok_or_else(|| "no name set".to_string())?;
    Ok(name.to_string())
}

/// Offline snapshot: self + contacts + groups + last 50 messages per thread.
pub async fn build_roster(store: &SqliteStore) -> Result<String, String> {
    let reg = store
        .load_registration_data()
        .await
        .map_err(|e| format!("registration: {e}"))?
        .ok_or_else(|| "not linked".to_string())?;
    let self_aci = reg.service_ids.aci.to_string();
    let number = reg.phone_number.to_string();

    let contacts: Vec<_> = store
        .contacts()
        .await
        .map_err(|e| format!("contacts: {e}"))?
        .filter_map(|c| c.ok())
        .collect();
    let groups: Vec<_> = store
        .groups()
        .await
        .map_err(|e| format!("groups: {e}"))?
        .filter_map(|g| g.ok())
        .collect();

    let names = load_names(store).await;
    let mut messages = Vec::new();
    // Threads are exactly the synced contacts + groups: no separate thread
    // index exists in the store, and this also makes fresh contacts visible.
    let mut threads: Vec<Thread> = Vec::with_capacity(contacts.len() + groups.len());
    for c in &contacts {
        threads.push(Thread::Contact(ServiceId::Aci(Aci::from(c.uuid))));
    }
    for (key, _) in &groups {
        threads.push(Thread::Group(*key));
    }
    for thread in threads {
        let thread_id = match &thread {
            Thread::Contact(sid) => format!("contact:{}", service_uuid(sid)),
            Thread::Group(key) => format!("group:{}", hex::encode(key)),
        };
        // Seed window per thread (older history pages via `thread_page`).
        const SEED_WINDOW: usize = 100;
        let mut thread_msgs: Vec<Content> = store
            .messages(&thread, ..)
            .await
            .map_err(|e| format!("messages: {e}"))?
            .filter_map(|m| m.ok())
            .collect();
        thread_msgs.sort_by_key(content_store_timestamp);
        let reaction_summaries = reaction_summaries(&thread_msgs);
        let seed: Vec<serde_json::Value> = thread_msgs
            .iter()
            .rev()
            .filter_map(|m| {
                let mut event = content_event(m, &self_aci, &names)?;
                // content_event derives the thread from the envelope; it must
                // agree with the queried thread or the row is misfiled.
                if event.get("thread").and_then(|t| t.as_str()) != Some(thread_id.as_str()) {
                    return None;
                }
                add_reaction_summary(&mut event, m, &reaction_summaries);
                Some(event)
            })
            .take(SEED_WINDOW)
            .collect();
        messages.extend(seed.into_iter().rev());
    }

    let roster = serde_json::json!({
        "self": {"aci": self_aci, "number": number},
        "contacts": contacts.iter().map(|c| serde_json::json!({
            "id": c.uuid.to_string(),
            "name": c.name,
            "phone": c.phone_number.as_ref().map(|p| p.to_string()).unwrap_or_default(),
        })).collect::<Vec<_>>(),
        "groups": groups.iter().map(|(key, g)| serde_json::json!({
            "id": hex::encode(key),
            "title": g.title,
        })).collect::<Vec<_>>(),
        "messages": messages,
    });
    serde_json::to_string(&roster).map_err(|e| format!("encode roster: {e}"))
}

/// Offline identity probe (no network).
pub async fn whoami(store: &SqliteStore) -> Result<String, String> {
    let reg = store
        .load_registration_data()
        .await
        .map_err(|e| format!("registration: {e}"))?
        .ok_or_else(|| "not linked".to_string())?;
    serde_json::to_string(&serde_json::json!({
        "aci": reg.service_ids.aci.to_string(),
        "number": reg.phone_number.to_string(),
    }))
    .map_err(|e| format!("encode whoami: {e}"))
}

pub fn received_event(r: &Received, self_aci: &str, names: &HashMap<String, String>) -> Option<String> {
    let v = match r {
        Received::Content(c) => {
            if let Some(event) = receipt_part(c, names, self_aci) {
                return Some(event.to_string());
            }
            if let Some(event) = call_signal_part(c, names) {
                return Some(event.to_string());
            }
            if let Some(event) = reaction_part(c, names, self_aci) {
                return Some(event.to_string());
            }
            if let Some(event) = edit_part(c, names, self_aci) {
                return Some(event.to_string());
            }
            if let Some(event) = delete_part(c, names, self_aci) {
                return Some(event.to_string());
            }
            if let Some(event) = typing_part(c, names) {
                return Some(event.to_string());
            }
            let (m, _) = content_parts(c, self_aci, names)?;
            serde_json::json!({"type": "message", "message": m})
        }
        Received::Contacts => serde_json::json!({"type": "contacts_synced"}),
        Received::QueueEmpty => serde_json::json!({"type": "queue_empty"}),
        Received::DecryptionError(sid) => {
            serde_json::json!({"type": "decryption_error", "sender": service_uuid(sid)})
        }
    };
    Some(v.to_string())
}

/// Reaction envelope → {"type":"reaction","thread","target_sts","emoji",
/// "remove","sender","sender_name"}. `target_sts` is the store-clock ts of
/// the targeted message.
pub fn reaction_part(
    content: &Content,
    names: &HashMap<String, String>,
    self_aci: &str,
) -> Option<serde_json::Value> {
    let (reaction, thread_id) = match &content.body {
        ContentBody::DataMessage(m) => (m.reaction.as_ref()?, thread_of_content_for(content, self_aci)?),
        ContentBody::SynchronizeMessage(s) => match &s.content {
            Some(SyncContent::Sent(sent)) => {
                let dm = sent.message.as_ref()?;
                (dm.reaction.as_ref()?, thread_of_content_for(content, self_aci)?)
            }
            _ => return None,
        },
        _ => return None,
    };
    let sender = service_uuid(&content.metadata.sender);
    Some(serde_json::json!({
        "type": "reaction",
        "thread": thread_id,
        "target_sts": reaction.target_sent_timestamp.unwrap_or(0),
        "emoji": reaction.emoji.clone().unwrap_or_default(),
        "remove": reaction.remove.unwrap_or(false),
        "sender": sender,
        "sender_name": display_name(names, &sender),
    }))
}

/// Edit envelope → a normalized event for the Swift presentation store.
pub fn edit_part(
    content: &Content,
    names: &HashMap<String, String>,
    self_aci: &str,
) -> Option<serde_json::Value> {
    let edit = match &content.body {
        ContentBody::EditMessage(edit) => edit,
        ContentBody::SynchronizeMessage(sync) => match &sync.content {
            Some(SyncContent::Sent(sent)) => sent.edit_message.as_ref()?,
            _ => return None,
        },
        _ => return None,
    };
    let target = edit.target_sent_timestamp?;
    let data = edit.data_message.as_ref()?;
    let sender = service_uuid(&content.metadata.sender);
    let thread = thread_of_content_for(content, self_aci)?;
    Some(serde_json::json!({
        "type": "edit",
        "thread": thread,
        "target_sts": target,
        "body": data.body.clone().unwrap_or_default(),
        "sender": sender,
        "sender_name": display_name(names, &sender),
        "ts": content.metadata.server_timestamp.timestamp_millis().max(0) as u64,
    }))
}

/// Delete-for-everyone envelope → a normalized event for the Swift store.
pub fn delete_part(
    content: &Content,
    names: &HashMap<String, String>,
    self_aci: &str,
) -> Option<serde_json::Value> {
    let target = match &content.body {
        ContentBody::DataMessage(message) => message.delete.as_ref()?.target_sent_timestamp?,
        ContentBody::SynchronizeMessage(sync) => match &sync.content {
            Some(SyncContent::Sent(sent)) => {
                sent.message.as_ref()?.delete.as_ref()?.target_sent_timestamp?
            }
            _ => return None,
        },
        _ => return None,
    };
    let sender = service_uuid(&content.metadata.sender);
    let thread = thread_of_content_for(content, self_aci)?;
    Some(serde_json::json!({
        "type": "delete",
        "thread": thread,
        "target_sts": target,
        "sender": sender,
        "sender_name": display_name(names, &sender),
        "ts": content.metadata.server_timestamp.timestamp_millis().max(0) as u64,
    }))
}

/// Reconcile an edit into the native store so a later roster refresh cannot
/// restore the pre-edit body. The Swift presentation store is updated by the
/// emitted event; this keeps the native source of truth consistent as well.
pub async fn reconcile_edit(
    store: &SqliteStore,
    thread_id: &str,
    target_sts: u64,
    body: &str,
    author_id: &str,
) -> Result<(), String> {
    let thread = parse_thread(thread_id)?;
    let mut content = store
        .message(&thread, target_sts)
        .await
        .map_err(|e| format!("edit target: {e}"))?
        .ok_or_else(|| "edit target not found".to_string())?;
    if !author_id.is_empty()
        && author_id != "?"
        && service_uuid(&content.metadata.sender) != author_id
    {
        return Err("edit author does not match target".to_string());
    }
    match &mut content.body {
        ContentBody::DataMessage(message) => message.body = Some(body.to_string()),
        ContentBody::SynchronizeMessage(sync) => {
            if let Some(SyncContent::Sent(sent)) = &mut sync.content {
                if let Some(message) = sent.message.as_mut() {
                    message.body = Some(body.to_string());
                }
            }
        }
        _ => return Err("edit target is not a chat message".to_string()),
    }
    store
        .save_message(&thread, content)
        .await
        .map_err(|e| format!("save edited message: {e}"))
}

/// Remove a delete target from the native store after validating that it
/// exists. This prevents a stale target from being reintroduced by a later
/// history query.
pub async fn reconcile_delete(
    store: &mut SqliteStore,
    thread_id: &str,
    target_sts: u64,
    author_id: &str,
) -> Result<(), String> {
    let thread = parse_thread(thread_id)?;
    if !author_id.is_empty() && author_id != "?" {
        if let Some(content) = store
            .message(&thread, target_sts)
            .await
            .map_err(|e| format!("delete target: {e}"))?
        {
            if service_uuid(&content.metadata.sender) != author_id {
                return Err("delete author does not match target".to_string());
            }
        }
    }
    store
        .delete_message(&thread, target_sts)
        .await
        .map_err(|e| format!("delete target: {e}"))?;
    Ok(())
}

/// Typing envelope → a normalized event for the Swift UI.
pub fn typing_part(
    content: &Content,
    names: &HashMap<String, String>,
) -> Option<serde_json::Value> {
    let ContentBody::TypingMessage(typing) = &content.body else { return None };
    let sender = service_uuid(&content.metadata.sender);
    let thread = if let Some(group_id) = &typing.group_id {
        if group_id.len() != 32 { return None; }
        format!("group:{}", hex::encode(group_id))
    } else {
        thread_of_content(content)?
    };
    Some(serde_json::json!({
        "type": "typing",
        "thread": thread,
        "typing_sender": sender,
        "sender": sender,
        "sender_name": display_name(names, &sender),
        "started": typing.action.unwrap_or(1) == 0,
        "ts": content.metadata.server_timestamp.timestamp_millis().max(0) as u64,
    }))
}

/// Call signaling envelope → {"type":"call_signal", …}.
///
/// Signal carries call offer/answer/ICE/hangup/busy as a `CallMessage`
/// content body (not a `DataMessage`), so it never reaches `content_parts`.
/// This lifts those envelopes out of the receive stream and onto the event
/// channel so the call state machine on the Swift side can drive ringing,
/// answer, ICE and hangup.
///
/// `opaque` is the RingRTC protobuf blob (base64 here) — Signal's call
/// protocol does not carry raw SDP on the wire.
pub fn call_signal_part(
    content: &Content,
    names: &HashMap<String, String>,
) -> Option<serde_json::Value> {
    let call = match &content.body {
        ContentBody::CallMessage(c) => c,
        _ => return None,
    };
    let sender = service_uuid(&content.metadata.sender);
    let thread = thread_of_content(content)?;
    let ts = content.metadata.server_timestamp.timestamp_millis().max(0) as u64;
    let sender_device_id: u32 = content.metadata.sender_device.into();

    use base64::Engine as _;
    let b64 = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);

    // Group call signaling is an opaque payload inside a CallMessage with no
    // offer/answer/ice/hangup/busy field. It is a distinct event rather than a
    // 1:1 "kind" because RingRTC has to be handed the raw bytes, and a group
    // call message must never be rendered as a chat row or as 1:1 signaling.
    if let Some(opaque) = &call.opaque {
        let data = opaque.data.as_ref()?;
        if data.is_empty() {
            return None;
        }
        // RingRTC will not create a group client for an inbound signal; it routes
        // the message to an existing client for that group and drops it
        // otherwise. The host therefore has to be told which group this is in
        // order to create a client to receive on.
        return Some(serde_json::json!({
            "type": "group_call_signal",
            "sender": sender,
            "sender_device_id": sender_device_id,
            "message_b64": b64(data),
            "immediate": opaque.urgency.unwrap_or(0) == 1,
            "group_id": crate::group_calls::group_id_hex_from_ringrtc_signal(data),
            "ts": ts,
        }));
    }

    // Signal may put several ICE candidates in one CallMessage. Keep the
    // first value in `opaque` for compatibility and expose the complete list
    // in `opaques` so RingRTC does not lose candidates.
    let (kind, call_id, media_type, opaque, opaques, hangup_type, device_id) =
        if let Some(offer) = &call.offer {
            let media = match offer.r#type.unwrap_or(0) {
                1 => "video",
                _ => "audio",
            };
            let value = offer.opaque.clone().unwrap_or_default();
            (
                "offer",
                offer.id.unwrap_or(0),
                Some(media),
                Some(b64(&value)),
                Vec::<String>::new(),
                None,
                None,
            )
        } else if let Some(answer) = &call.answer {
            let value = answer.opaque.clone().unwrap_or_default();
            (
                "answer",
                answer.id.unwrap_or(0),
                None,
                Some(b64(&value)),
                Vec::<String>::new(),
                None,
                None,
            )
        } else if let Some(ice) = call.ice_update.first() {
            let values: Vec<String> = call
                .ice_update
                .iter()
                .filter_map(|candidate| candidate.opaque.as_ref())
                .map(|value| b64(value))
                .collect();
            let first = values.first().cloned();
            (
                "ice",
                ice.id.unwrap_or(0),
                None,
                first,
                values,
                None,
                None,
            )
        } else if let Some(hangup) = &call.hangup {
            (
                "hangup",
                hangup.id.unwrap_or(0),
                None,
                None,
                Vec::<String>::new(),
                Some(hangup.r#type.unwrap_or(0)),
                hangup.device_id,
            )
        } else if let Some(busy) = &call.busy {
            (
                "busy",
                busy.id.unwrap_or(0),
                None,
                None,
                Vec::<String>::new(),
                None,
                None,
            )
        } else {
            return None;
        };

    Some(serde_json::json!({
        "type": "call_signal",
        "kind": kind,
        "thread": thread,
        "sender": sender,
        "destination": service_uuid(&content.metadata.destination),
        "sender_name": display_name(names, &sender),
        "sender_device_id": sender_device_id,
        "destination_device_id": call.destination_device_id,
        "call_id": call_id,
        "media_type": media_type,
        "opaque": opaque,
        "opaques": opaques,
        "hangup_type": hangup_type,
        "device_id": device_id,
        "ts": ts,
    }))
}

/// Read/delivery receipt → {"type":"receipt","thread","sender",
/// "sender_name","kind":"read"|"delivered","timestamps":[…]}. Timestamps are
/// store clocks of the messages being acknowledged.
pub fn receipt_part(
    content: &Content,
    names: &HashMap<String, String>,
    self_aci: &str,
) -> Option<serde_json::Value> {
    let receipt = match &content.body {
        ContentBody::ReceiptMessage(r) => r,
        _ => return None,
    };
    // Proto enum: 0 = delivered, 1 = read (stable numbering; Viewed skips).
    let kind = match receipt.r#type.unwrap_or(-1) {
        1 => "read",
        0 => "delivered",
        _ => return None,
    };
    let sender = service_uuid(&content.metadata.sender);
    let thread = thread_of_content_for(content, self_aci);
    Some(serde_json::json!({
        "type": "receipt",
        "thread": thread,
        "sender": sender,
        "sender_name": display_name(names, &sender),
        "kind": kind,
        "timestamps": receipt.timestamp,
        "ambiguous": false,
    }))
}

/// Resolve receipt scope against the native store. ReceiptMessage itself has
/// no thread field; matching its target timestamps is the only reliable way
/// to distinguish colliding 1:1/group conversations.
pub async fn receipt_part_scoped(
    store: &SqliteStore,
    content: &Content,
    self_aci: &str,
    names: &HashMap<String, String>,
) -> Option<serde_json::Value> {
    let mut event = receipt_part(content, names, self_aci)?;
    let receipt = match &content.body {
        ContentBody::ReceiptMessage(receipt) => receipt,
        _ => return None,
    };
    let timestamps: std::collections::HashSet<u64> = receipt.timestamp.iter().copied().collect();
    if timestamps.is_empty() {
        return Some(event);
    }

    let mut threads: Vec<Thread> = store
        .contacts()
        .await
        .ok()?
        .filter_map(|contact| contact.ok())
        .map(|contact| Thread::Contact(ServiceId::Aci(Aci::from(contact.uuid))))
        .collect();
    threads.extend(
        store
            .groups()
            .await
            .ok()?
            .filter_map(|group| group.ok())
            .map(|(key, _)| Thread::Group(key)),
    );

    let mut matches = std::collections::HashSet::new();
    for thread in threads {
        let thread_id = match &thread {
            Thread::Contact(sid) => format!("contact:{}", service_uuid(sid)),
            Thread::Group(key) => format!("group:{}", hex::encode(key)),
        };
        let rows = match store.messages(&thread, ..).await {
            Ok(rows) => rows,
            Err(_) => continue,
        };
        for row in rows.filter_map(|row| row.ok()) {
            let store_ts = content_store_timestamp(&row);
            let protocol_ts = content_protocol_timestamp(&row);
            if timestamps.contains(&store_ts) || timestamps.contains(&protocol_ts) {
                matches.insert(thread_id.clone());
            }
        }
    }

    if matches.len() == 1 {
        event["thread"] = serde_json::json!(matches.into_iter().next().unwrap());
    } else if matches.len() > 1 {
        // Never let the Swift fallback scan every conversation and apply a
        // colliding timestamp to the wrong peer.
        event["thread"] = serde_json::Value::Null;
        event["ambiguous"] = serde_json::json!(true);
    }
    Some(event)
}

fn thread_of_content_for(content: &Content, self_aci: &str) -> Option<String> {
    let thread = safe_thread_of_content(content)?;
    Some(match &thread {
        Thread::Contact(sid) => {
            let sender = service_uuid(&content.metadata.sender);
            // Envelopes emitted by another linked device carry this account as
            // sender, while the destination is the actual conversation. Using
            // the destination prevents self-authored reactions/edits/typing
            // from being misfiled under contact:<self>.
            if !self_aci.is_empty()
                && sender == self_aci
                && content.metadata.destination != content.metadata.sender
            {
                format!("contact:{}", service_uuid(&content.metadata.destination))
            } else {
                format!("contact:{}", service_uuid(sid))
            }
        }
        Thread::Group(key) => format!("group:{}", hex::encode(key)),
    })
}

fn thread_of_content(content: &Content) -> Option<String> {
    thread_of_content_for(content, "")
}

use presage::libsignal_service::content::DataMessage;
use presage::libsignal_service::proto::data_message::{Delete, Quote};
use presage::libsignal_service::sender::AttachmentSpec;

/// Optional extras for an outgoing message.
#[derive(Default)]
pub struct SendExtras {
    pub quote: Option<Quote>,
    pub delete_ts: Option<u64>,
}

/// Full send: text + uploaded attachments + quote/ref + delete tombstone.
pub async fn do_send_full(
    manager: &mut StoredManager,
    thread: &str,
    body: &str,
    uploads: Vec<AttachmentPointer>,
    extras: SendExtras,
) -> Result<u64, String> {
    let ts = now_millis();
    let msg = DataMessage {
        body: Some(body.to_string()),
        timestamp: Some(ts),
        attachments: uploads,
        quote: extras.quote,
        delete: extras.delete_ts.map(|t| Delete { target_sent_timestamp: Some(t) }),
        ..Default::default()
    };
    let content_body: ContentBody = msg.into();
    send_content(manager, thread, content_body, ts).await
}

pub(crate) async fn send_content(
    manager: &mut StoredManager,
    thread: &str,
    mut content_body: ContentBody,
    ts: u64,
) -> Result<u64, String> {
    if let Some(hexkey) = thread.strip_prefix("group:") {
        let bytes = hex::decode(hexkey).map_err(|_| "bad group id".to_string())?;
        let key: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| "bad group id length".to_string())?;
        let revision = manager
            .store()
            .group(key)
            .await
            .map_err(|e| format!("group metadata: {e}"))?
            .ok_or_else(|| "group metadata not found".to_string())?
            .revision;

        // Presage's group sender broadcasts to each member, but it does not
        // add GroupsV2 context to the DataMessage itself. Without this field
        // Signal clients legitimately classify the message as a 1:1 message
        // from the sender (often the first/only visible member). Set the
        // canonical master-key context on every group-capable payload before
        // handing it to the sender.
        let group_context = GroupContextV2 {
            master_key: Some(bytes.clone()),
            revision: Some(revision),
            group_change: None,
        };
        match &mut content_body {
            ContentBody::DataMessage(message) => message.group_v2 = Some(group_context),
            ContentBody::EditMessage(edit) => {
                if let Some(data_message) = edit.data_message.as_mut() {
                    data_message.group_v2 = Some(group_context);
                }
            }
            _ => {}
        }

        eprintln!(
            "[core] send group key_len={} revision={} with_group_context",
            bytes.len(),
            revision
        );
        manager
            .send_message_to_group(&bytes, content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else if let Some(uuid) = thread.strip_prefix("contact:") {
        eprintln!("[core] send contact id={uuid}");
        let recipient = parse_service_id(uuid)?;
        manager
            .send_message(recipient, content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else {
        Err("bad thread id".to_string())
    }
}

/// Send a text to "contact:<uuid>" or "group:<hex>". Returns sent timestamp.
pub async fn do_send(manager: &mut StoredManager, thread: &str, body: &str) -> Result<u64, String> {
    eprintln!("[core] send start thread={thread} body_len={}", body.len());
    let result = do_send_full(manager, thread, body, Vec::new(), SendExtras::default()).await;
    match &result {
        Ok(sent_ts) => eprintln!("[core] send ok ts={sent_ts}"),
        Err(e) => eprintln!("[core] send failed: {e}"),
    }
    result
}

/// Reply prefabs: quote block pointing at a previous message.
pub fn make_quote(ts: u64, author_aci: &str, body: &str) -> Result<Quote, String> {
    // Signal's quote field carries the service-id string. Validate the
    // service-id shape but preserve a PNI prefix instead of silently routing
    // a reply to the wrong ACI.
    parse_service_id(author_aci)?;
    Ok(Quote {
        id: Some(ts),
        author_aci: Some(author_aci.to_string()),
        text: Some(body.chars().take(200).collect()),
        ..Default::default()
    })
}

/// Guess a content-type from a file extension (upload metadata).
pub fn guess_mime(path: &std::path::Path) -> String {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase().as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "heic" => "image/heic",
        "webp" => "image/webp",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "pdf" => "application/pdf",
        "txt" | "md" => "text/plain",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Max outbound attachment (100 MB, Signal's CDN cap neighborhood).
pub const MAX_UPLOAD_BYTES: u64 = 100_000_000;

/// Read + upload a local file, returning its attachment pointer.
pub async fn upload_file(
    manager: &mut StoredManager,
    path: &std::path::Path,
) -> Result<AttachmentPointer, String> {
    let metadata = std::fs::metadata(path).map_err(|e| format!("stat file: {e}"))?;
    if !metadata.is_file() {
        return Err("attachment path is not a regular file".to_string());
    }
    if metadata.len() > MAX_UPLOAD_BYTES {
        return Err("file exceeds 100 MB".to_string());
    }
    let bytes = std::fs::read(path).map_err(|e| format!("read file: {e}"))?;
    if bytes.len() as u64 > MAX_UPLOAD_BYTES {
        return Err("file exceeds 100 MB".to_string());
    }
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("attachment")
        .to_string();
    let spec = AttachmentSpec {
        content_type: guess_mime(path),
        length: bytes.len(),
        file_name: Some(name),
        preview: None,
        voice_note: None,
        borderless: None,
        width: None,
        height: None,
        caption: None,
        blur_hash: None,
    };
    manager
        .upload_attachment(spec, bytes)
        .await
        .map_err(|e| format!("upload: {e}"))?
        .map_err(|e| format!("upload rejected: {e:?}"))
}

/// Send a read/delivery receipt for the given message timestamps (store clocks).
/// `kind` is "read" or "delivered".
pub async fn send_receipt(
    manager: &mut StoredManager,
    thread: &str,
    timestamps: &[u64],
    kind: &str,
) -> Result<(), String> {
    use presage::libsignal_service::proto::ReceiptMessage;
    use presage::libsignal_service::content::ContentBody;
    use presage::store::Thread;

    let receipt_type = match kind {
        "read" => 1i32,
        "delivered" => 0i32,
        _ => return Err("invalid receipt kind".to_string()),
    };

    let receipt_msg = ReceiptMessage {
        r#type: Some(receipt_type),
        timestamp: timestamps.iter().map(|&ts| ts as u64).collect(),
    };

    let content_body: ContentBody = ContentBody::ReceiptMessage(receipt_msg);
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("time error: {e}"))?
        .as_millis() as u64;

    // Receipts are direct 1:1 acknowledgements. A group receipt must be sent
    // separately to each message author; broadcasting it to the group is not
    // equivalent and can disclose/read-state to the wrong recipients.
    let recipient = match parse_thread(thread)? {
        Thread::Contact(service_id) => service_id,
        Thread::Group(_) => {
            return Err("group receipts require per-author delivery".to_string());
        }
    };
    manager
        .send_message(recipient, content_body, timestamp)
        .await
        .map_err(|e| format!("send receipt: {e}"))?;

    Ok(())
}

/// Legacy SDP-shaped call commands are intentionally disabled. The native
/// RingRTC path (`core_cmd_call_start`/accept/hangup) owns call signaling.
pub async fn send_call_offer_inner(
    _manager: &mut StoredManager,
    _call_id: &str,
    _to: &str,
    _media_type: &str,
    _sdp: &str,
) -> Result<(), String> {
    Err("legacy SDP calls are disabled; use the native call API".to_string())
}

pub async fn send_call_answer_inner(
    _manager: &mut StoredManager,
    _call_id: &str,
    _sdp: &str,
) -> Result<(), String> {
    Err("legacy SDP calls are disabled; use the native call API".to_string())
}

pub async fn send_call_ice_inner(
    _manager: &mut StoredManager,
    _call_id: &str,
    _candidate: &str,
    _sdp_mid: &str,
    _sdp_m_line_index: u32,
) -> Result<(), String> {
    Err("legacy SDP calls are disabled; use the native call API".to_string())
}

pub async fn send_call_hangup_inner(
    _manager: &mut StoredManager,
    _call_id: &str,
    _reason: &str,
) -> Result<(), String> {
    Err("legacy SDP calls are disabled; use the native call API".to_string())
}

/// Send a message edit to the remote peer via Signal's websocket.
pub async fn send_message_edit(
    manager: &mut StoredManager,
    thread: &str,
    target_ts: u64,
    new_body: &str,
) -> Result<u64, String> {
    use presage::libsignal_service::content::ContentBody;
    let timestamp = now_millis();
    let edit_msg = presage::proto::EditMessage {
        target_sent_timestamp: Some(target_ts),
        data_message: Some(presage::proto::DataMessage {
            body: Some(new_body.to_string()),
            ..Default::default()
        }),
        ..Default::default()
    };
    let content_body: ContentBody = ContentBody::EditMessage(edit_msg);
    send_content(manager, thread, content_body, timestamp).await
}

/// Send a typing indicator to the remote peer via Signal's websocket.
pub async fn send_typing(
    manager: &mut StoredManager,
    thread: &str,
    started: bool,
) -> Result<(), String> {
    use presage::libsignal_service::content::ContentBody;
    use presage::libsignal_service::proto::TypingMessage;

    let group_id = match parse_thread(thread)? {
        Thread::Group(key) => Some(key.to_vec()),
        Thread::Contact(_) => None,
    };
    let typing_msg = TypingMessage {
        action: if started { Some(0) } else { Some(1) },
        group_id,
        timestamp: Some(now_millis()),
    };
    let content_body: ContentBody = ContentBody::TypingMessage(typing_msg);
    send_content(manager, thread, content_body, now_millis())
        .await
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_control_envelopes_are_not_chat_content() {
        assert!(!has_chat_content("", &[], false));
        assert!(has_chat_content("", &[], true));
        let pointer = AttachmentPointer {
            content_type: Some("image/gif".to_string()),
            ..Default::default()
        };
        assert!(has_chat_content("", &[pointer], false));
        assert!(has_chat_content("hello", &[], false));
    }

    /// Build a `Content` carrying a `CallMessage` with only an opaque payload,
    /// which is how group call signaling arrives.
    fn group_call_content(opaque: Option<Vec<u8>>, urgency: Option<i32>) -> Content {
        use libsignal_service::proto::{
            call_message::Opaque, CallMessage as ProtoCallMessage,
        };
        let message = ProtoCallMessage {
            opaque: opaque.map(|data| Opaque { data: Some(data), urgency }),
            ..Default::default()
        };
        let ts = chrono::DateTime::from_timestamp_millis(1_700_000_000_000)
            .expect("valid timestamp");
        Content {
            metadata: libsignal_service::content::Metadata {
                sender: ServiceId::Aci(
                    uuid::Uuid::parse_str("11111111-1111-1111-1111-111111111111")
                        .expect("sender uuid")
                        .into(),
                ),
                destination: ServiceId::Aci(
                    uuid::Uuid::parse_str("22222222-2222-2222-2222-222222222222")
                        .expect("destination uuid")
                        .into(),
                ),
                sender_device: presage::libsignal_service::protocol::DeviceId::new(1)
                    .expect("device id in range"),
                pni_verified: None,
                client_timestamp: ts,
                server_timestamp: ts,
                needs_receipt: false,
                unidentified_sender: false,
                was_plaintext: false,
                server_guid: None,
            },
            body: ContentBody::CallMessage(message),
        }
    }

    #[test]
    fn a_group_call_signal_is_its_own_event_not_1_1_signaling() {
        // Group signaling must not be read as a 1:1 offer/answer/ICE: those go
        // through a different handler with different expectations.
        let event = call_signal_part(
            &group_call_content(Some(vec![0x01, 0x02]), Some(1)),
            &HashMap::new(),
        )
        .expect("group call signal produces an event");
        assert_eq!(event.get("type").and_then(|v| v.as_str()), Some("group_call_signal"));
        assert!(
            event.get("kind").is_none(),
            "a group signal must not claim a 1:1 kind"
        );
        assert!(event.get("message_b64").is_some());
        assert_eq!(event.get("immediate").and_then(|v| v.as_bool()), Some(true));
    }

    #[test]
    fn group_signal_urgency_defaults_to_droppable() {
        // Signal documents a missing urgency as DROPPABLE, so an absent value
        // must not be read as "handle immediately".
        let event = call_signal_part(
            &group_call_content(Some(vec![0x01]), None),
            &HashMap::new(),
        )
        .expect("group call signal produces an event");
        assert_eq!(event.get("immediate").and_then(|v| v.as_bool()), Some(false));
    }

    #[test]
    fn an_empty_group_payload_produces_no_event() {
        assert!(call_signal_part(&group_call_content(Some(Vec::new()), Some(1)), &HashMap::new()).is_none());
        assert!(call_signal_part(&group_call_content(None, Some(1)), &HashMap::new()).is_none());
    }

    #[test]
    fn gif_pointer_without_filename_gets_stable_name_and_mime() {
        let pointer = AttachmentPointer {
            content_type: Some("image/gif".to_string()),
            file_name: None,
            ..Default::default()
        };
        let mime = normalized_attachment_mime(&pointer);
        assert_eq!(mime, "image/gif");
        assert_eq!(effective_attachment_name(&pointer, &mime), "attachment.gif");
        assert!(is_media_attachment(&pointer));
    }

    #[test]
    fn thread_ids_preserve_service_id_type_and_validate_group_keys() {
        let pni = parse_thread("contact:PNI:11111111-1111-1111-1111-111111111111");
        assert!(matches!(pni, Ok(Thread::Contact(ServiceId::Pni(_)))));
        assert!(parse_thread(&format!("group:{}", "ab".repeat(32))).is_ok());
        assert!(parse_thread("group:ab").is_err());
        assert!(parse_thread("contact:not-a-uuid").is_err());
    }

    #[test]
    fn quotes_preserve_pni_service_ids() {
        let quote = make_quote(42, "PNI:11111111-1111-1111-1111-111111111111", "quoted").unwrap();
        assert_eq!(quote.author_aci.as_deref(), Some("PNI:11111111-1111-1111-1111-111111111111"));
        assert!(make_quote(42, "11111111-1111-1111-1111-111111111111", "quoted").is_ok());
        assert!(make_quote(42, "not-a-service-id", "quoted").is_err());
    }

    #[test]
    fn generic_pointer_infers_mime_from_filename() {
        let pointer = AttachmentPointer {
            content_type: Some("application/octet-stream".to_string()),
            file_name: Some("clip.GIF".to_string()),
            ..Default::default()
        };
        let mime = normalized_attachment_mime(&pointer);
        assert_eq!(mime, "image/gif");
        assert!(is_media_attachment(&pointer));
    }
}
