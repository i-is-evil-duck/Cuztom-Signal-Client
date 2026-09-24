# Core Polish + Calls Implementation Plan

## Priority Order
1. **Message Edits** - FFI + Swift UI
2. **Typing Indicators** - FFI + Swift UI
3. **Link Previews** - Swift metadata fetching
4. **Read Receipts Polish** - Config + UI
5. **Calls** - RingRTC native + full implementation

---

## 1. Message Edits
### Rust FFI
- [ ] Add `SendMessageEdit` command to lib.rs
- [ ] Implement `send_message_edit_inner` in sync.rs using `ContentBody::EditMessage`
- [ ] Add FFI `core_cmd_send_message_edit(thread, target_ts, new_body)`

### Swift
- [ ] Add "Edit" to message context menu
- [ ] Edit sheet with text field + save/cancel
- [ ] Show "edited" badge on message
- [ ] Update message in store via `updateMessage`

---

## 2. Typing Indicators
### Rust FFI
- [ ] Add `SendTyping` command (thread, started: bool)
- [ ] Implement `send_typing_inner` - send `TypingMessage` via sync
- [ ] FFI `core_cmd_send_typing(thread, started)`

### Swift
- [ ] Debounced typing detection in composer
- [ ] Send typing start on first keystroke
- [ ] Send typing stop after 2s idle
- [ ] Show "X is typing…" in conversation header
- [ ] Handle incoming typing events in drainEvents

---

## 3. Link Previews
### Swift
- [ ] Add `metadata` crate for og:title/og:image/og:description
- [ ] Fetch preview when URL detected in message
- [ ] Preview card UI (image + title + description)
- [ ] Cache previews in SQLite
- [ ] Show in message bubble

---

## 4. Read Receipts Polish
### Swift
- [ ] Settings toggle: "Send Read Receipts" (on/off)
- [ ] Settings toggle: "Send Delivery Receipts" (on/off)
- [ ] Auto-send read receipt on `select()` when enabled
- [ ] Message detail popover: show "Seen by" / "Delivered to" with timestamps
- [ ] Visual indicator: single check = sent, double check = delivered, double check + color = read

---

## 5. Calls (RingRTC Native)
### Rust
- [ ] Enable `ringrtc` with `features = ["native"]` in Cargo.toml
- [ ] Fix cmake + WebRTC prebuilt build
- [ ] Implement `send_call_offer_inner` - real SDP via RingRTC
- [ ] Implement `send_call_answer_inner` - real SDP via RingRTC
- [ ] Implement `send_call_ice_inner` - ICE candidate via RingRTC
- [ ] Implement `send_call_hangup_inner` - BYE via RingRTC
- [ ] Audio: cubeb capture/playback, device picker
- [ ] Video: AVCaptureSession capture/preview

### Swift
- [ ] Audio session config (`.playAndRecord`, `.allowBluetooth`)
- [ ] Audio device picker (input/output)
- [ ] Video preview layer (AVCaptureVideoPreviewLayer)
- [ ] CallKit integration (CXProvider, CXCallController)
- [ ] Lock screen call UI
- [ ] Background call handling

---

## Commands to Add to lib.rs

```rust
// Message Edits
SendMessageEdit { thread: String, target_ts: u64, new_body: String, reply }

// Typing Indicators
SendTyping { thread: String, started: bool, reply }

// Link previews - handled in Swift, no FFI needed

// Read receipts - already have send_receipt, just add config