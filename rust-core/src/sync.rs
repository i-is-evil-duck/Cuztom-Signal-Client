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

use presage::libsignal_service::content::{Content, ContentBody};
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

/// Convert one decrypted `Content` into a wire message. Returns `None` for
/// non-chat traffic (receipts, typing, calls… — M3/M4 territory).
pub fn content_event(
    content: &Content,
    self_aci: &str,
    names: &HashMap<String, String>,
) -> Option<serde_json::Value> {
    let meta = &content.metadata;
    let sender = service_uuid(&meta.sender);
    let ts = meta.server_timestamp.timestamp_millis().max(0) as u64;
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
            Some(message_json(&thread_id, &sender, names, &body, ts, outgoing))
        }
        ContentBody::SynchronizeMessage(s) => {
            let body = match &s.content {
                Some(SyncContent::Sent(sent)) => sent
                    .message
                    .as_ref()
                    .and_then(|m| m.body.clone())
                    .unwrap_or_default(),
                _ => return None,
            };
            // Canonical thread derivation (sync-sent, group, 1:1).
            let thread = Thread::try_from(content).ok()?;
            let thread_id = match &thread {
                Thread::Contact(sid) => format!("contact:{}", service_uuid(sid)),
                Thread::Group(key) => format!("group:{}", hex::encode(key)),
            };
            Some(message_json(&thread_id, self_aci, names, &body, ts, true))
        }
        _ => None,
    }
}

fn message_json(
    thread: &str,
    sender: &str,
    names: &HashMap<String, String>,
    body: &str,
    ts: u64,
    outgoing: bool,
) -> serde_json::Value {
    serde_json::json!({
        "key": format!("{thread}/{ts}/{sender}"),
        "thread": thread,
        "sender": sender,
        "sender_name": display_name(names, sender),
        "body": body,
        "ts": ts,
        "outgoing": outgoing,
    })
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
        let mut thread_msgs: Vec<Content> = store
            .messages(&thread, ..)
            .await
            .map_err(|e| format!("messages: {e}"))?
            .filter_map(|m| m.ok())
            .collect();
        thread_msgs.sort_by_key(|m| m.metadata.server_timestamp);
        for m in thread_msgs.iter().rev().take(50).rev() {
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
    let ts = now_millis();
    let msg = DataMessage {
        body: Some(body.to_string()),
        timestamp: Some(ts),
        ..Default::default()
    };
    let content_body: ContentBody = msg.into();
    if let Some(hexkey) = thread.strip_prefix("group:") {
        let bytes = hex::decode(hexkey).map_err(|_| "bad group id".to_string())?;
        manager
            .send_message_to_group(&bytes, content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else if let Some(uuid) = thread.strip_prefix("contact:") {
        // Our wire ids are bare uuids; tolerate a "PNI:" prefix defensively.
        let bare = uuid.strip_prefix("PNI:").unwrap_or(uuid);
        let parsed: uuid::Uuid = bare.parse().map_err(|_| "bad contact id".to_string())?;
        manager
            .send_message(ServiceId::Aci(Aci::from(parsed)), content_body, ts)
            .await
            .map(|_| ts)
            .map_err(|e| format!("send: {e}"))
    } else {
        Err("bad thread id".to_string())
    }
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
