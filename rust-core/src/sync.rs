//! M1b: roster / receive / send helpers shared by the FFI loop.
//!
//! Wire format to Swift (all JSON, UTF-8):
//!   roster: {"self":{"aci","number"},"contacts":[{"id","name","phone"}],
//!            "groups":[{"id","title"}],"messages":[message…]}
//!   message: {"key","thread","sender","sender_name","body","ts","outgoing"}
//!     thread = "contact:<uuid>" | "group:<hex master key>"
//!     key    = stable dedupe key "thread/ts/sender"
//!   event: {"type":"message","message":message}
//!          {"type":"contacts_synced"} | {"type":"queue_empty"}
//!          {"type":"sync_error","error":…} | {"type":"sync_ended"}

use std::collections::HashMap;

use presage::libsignal_service::content::{AttachmentPointer, Content, ContentBody};
use presage::libsignal_service::proto::sync_message::Content as SyncContent;
use presage::libsignal_service::protocol::{Aci, ServiceId};
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

fn display_name(names: &HashMap<String, String>, uuid: &str) -> String {
    if let Some(n) = names.get(uuid) {
        if !n.is_empty() {
            return n.clone();
        }
    }
    uuid.chars().take(8).collect()
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
    let store_ts = meta.client_timestamp.timestamp_millis().max(0) as u64;
    match &content.body {
        ContentBody::DataMessage(m) => {
            let body = m.body.clone().unwrap_or_default();
            let outgoing = sender == self_aci;
            // Canonical thread derivation (group via master key, else 1:1).
            let thread = Thread::try_from(content).ok()?;
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
            Some((message_json(&thread_id, &sender, names, &body, ts, outgoing, &pointers, store_ts), pointers))
        }
        ContentBody::SynchronizeMessage(s) => {
            let (body, pointers) = match &s.content {
                Some(SyncContent::Sent(sent)) => (
                    sent.message.as_ref().and_then(|m| m.body.clone()).unwrap_or_default(),
                    sent.message.as_ref().map(|m| m.attachments.clone()).unwrap_or_default(),
                ),
                _ => return None,
            };
            // Canonical thread derivation (sync-sent, group, 1:1).
            let thread = Thread::try_from(content).ok()?;
            let thread_id = match &thread {
                Thread::Contact(sid) => format!("contact:{}", service_uuid(sid)),
                Thread::Group(key) => format!("group:{}", hex::encode(key)),
            };
            Some((message_json(&thread_id, self_aci, names, &body, ts, true, &pointers, store_ts), pointers))
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

fn message_json(
    thread: &str,
    sender: &str,
    names: &HashMap<String, String>,
    body: &str,
    ts: u64,
    outgoing: bool,
    pointers: &[AttachmentPointer],
    store_ts: u64,
) -> serde_json::Value {
    serde_json::json!({
        "key": format!("{thread}/{ts}/{sender}"),
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
    })
}

/// Metadata-only attachment descriptor (`path` filled after download).
fn attachment_meta(p: &AttachmentPointer) -> serde_json::Value {
    serde_json::json!({
        "name": p.file_name.clone().unwrap_or_else(|| "attachment".to_string()),
        "mime": p.content_type.clone().unwrap_or_else(|| "application/octet-stream".to_string()),
        "size": p.size.unwrap_or(0),
        "path": null,
    })
}

/// Max auto-download per attachment (25 MB); larger stay metadata-only.
pub const MAX_AUTO_DOWNLOAD_BYTES: u32 = 25_000_000;

fn caches_dir() -> std::path::PathBuf {
    std::env::var("HOME")
        .map(|h| std::path::PathBuf::from(h).join("Library/Caches/CuztomSignal"))
        .unwrap_or_else(|_| std::env::temp_dir().join("CuztomSignal"))
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
    let size = ptr.size.unwrap_or(0);
    if size > MAX_AUTO_DOWNLOAD_BYTES {
        return Ok(None);
    }
    let name = ptr.file_name.clone().unwrap_or_else(|| "attachment".to_string());
    let dest = attachment_path(thread_id, ts, index, &name);
    if dest.exists() {
        return Ok(Some(dest.to_string_lossy().into_owned()));
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("cache dir: {e}"))?;
    }
    let bytes = manager
        .get_attachment(ptr)
        .await
        .map_err(|e| format!("download: {e}"))?;
    eprintln!("[core] attachment downloaded bytes={} -> {}", bytes.len(), dest.display());
    std::fs::write(&dest, &bytes).map_err(|e| format!("cache write: {e}"))?;
    Ok(Some(dest.to_string_lossy().into_owned()))
}

/// Parse a wire thread id back into a store `Thread`.
pub fn parse_thread(thread_id: &str) -> Result<Thread, String> {
    if let Some(hexkey) = thread_id.strip_prefix("group:") {
        let bytes = hex::decode(hexkey).map_err(|_| "bad group id".to_string())?;
        let arr: [u8; 32] = bytes.try_into().map_err(|_| "bad group id".to_string())?;
        Ok(Thread::Group(arr))
    } else if let Some(uuid) = thread_id.strip_prefix("contact:") {
        let bare = uuid.strip_prefix("PNI:").unwrap_or(uuid);
        let parsed: uuid::Uuid = bare.parse().map_err(|_| "bad contact id".to_string())?;
        Ok(Thread::Contact(ServiceId::Aci(Aci::from(parsed))))
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
    let mut msgs: Vec<Content> = store
        .messages(&thread, ..before_sts)
        .await
        .map_err(|e| format!("messages: {e}"))?
        .filter_map(|m| m.ok())
        .collect();
    msgs.sort_by_key(|m| m.metadata.server_timestamp);
    let page: Vec<serde_json::Value> = msgs
        .iter()
        .rev()
        .take(limit)
        .rev()
        .filter_map(|m| content_event(m, &self_aci, &names))
        .collect();
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
        .find(|m| {
            let t = m.metadata.client_timestamp.timestamp_millis().max(0) as u64;
            t <= sts
        })
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
            c.phone_number.as_ref().map(|p| p.to_string()).unwrap_or(id.clone())
        } else {
            c.name.clone()
        };
        map.insert(id, label);
    }
    map
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
        thread_msgs.sort_by_key(|m| m.metadata.server_timestamp);
        for m in thread_msgs.iter().rev().take(SEED_WINDOW).rev() {
            if let Some(ev) = content_event(m, &self_aci, &names) {
                // content_event derives the thread from the envelope; it must
                // agree with the queried thread or the row is misfiled.
                if ev.get("thread").and_then(|t| t.as_str()) == Some(thread_id.as_str()) {
                    messages.push(ev);
                }
            }
        }
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

/// Send a text to "contact:<uuid>" or "group:<hex>". Returns sent timestamp.
pub async fn do_send(manager: &mut StoredManager, thread: &str, body: &str) -> Result<u64, String> {
    use presage::libsignal_service::content::DataMessage;
    eprintln!("[core] send start thread={thread} body_len={}", body.len());
    let ts = now_millis();
    let msg = DataMessage {
        body: Some(body.to_string()),
        timestamp: Some(ts),
        ..Default::default()
    };
    let content_body: ContentBody = msg.into();
    let result = if let Some(hexkey) = thread.strip_prefix("group:") {
        let bytes = hex::decode(hexkey).map_err(|_| "bad group id".to_string())?;
        eprintln!("[core] send group key_len={}", bytes.len());
        manager
            .send_message_to_group(&bytes, content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else if let Some(uuid) = thread.strip_prefix("contact:") {
        // Our wire ids are bare uuids; tolerate a "PNI:" prefix defensively.
        let bare = uuid.strip_prefix("PNI:").unwrap_or(uuid);
        eprintln!("[core] send contact id={bare}");
        let parsed: uuid::Uuid = bare.parse().map_err(|_| "bad contact id".to_string())?;
        manager
            .send_message(ServiceId::Aci(Aci::from(parsed)), content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else {
        Err("bad thread id".to_string())
    };
    match &result {
        Ok(sent_ts) => eprintln!("[core] send ok ts={sent_ts}"),
        Err(e) => eprintln!("[core] send failed: {e}"),
    }
    result
}

pub fn received_event(r: &Received, self_aci: &str, names: &HashMap<String, String>) -> Option<String> {
    let v = match r {
        Received::Content(c) => {
            let m = content_event(c, self_aci, names)?;
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
