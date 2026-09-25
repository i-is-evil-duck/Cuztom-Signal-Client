# Implementation Plan: Fix All Issues (Easiest → Hardest)

> **Status for `beta-1.4.0`:** message routing, group context, identity/name
> resolution, logout wiping, attachment rendering, and native 1:1 calls are
> implemented. Group calls are intentionally staged next because they require
> Signal membership-proof and SFU HTTP support in addition to signaling.

## Phase 1: Quick Wins (1-2 hours each) ✅ Start Here

### 1.1 Fix Read Receipts Display - Show Usernames Not IDs
**Files:** `XcodeApp/Sources/Views.swift` (lines 313-331)
**Change:** Map ACI/UUID to display names in receipt popover using conversation peer info

### 1.2 Wire Typing Indicators to ViewModel
**Files:** `Sources/CuztomSignalCore/ChatController.swift`, `XcodeApp/Sources/CuztomSignalApp.swift`
**Change:** Connect `RustCoreService.onTyping` → `ChatViewModel.applyTyping` instead of `ChatController.applyTyping`

### 1.3 Auto-Send Read Receipts on Conversation Select
**Files:** `XcodeApp/Sources/CuztomSignalApp.swift` (line 175-179)
**Change:** Ensure `sendReadReceipts` setting is respected and called automatically

### 1.4 Fix Group Message Sender Name Display
**Files:** `XcodeApp/Sources/Views.swift` (lines 385-398)
**Change:** Use `msg.author.uuidString` to look up display name from roster instead of showing raw ACI

---

## Phase 2: Core Data Fixes (Half day each)

### 2.1 Implement `clearAllData()` for Proper Logout
**Files:**
- `Sources/CuztomSignalCore/ChatController.swift` (logout function)
- `Sources/CuztomSignalCore/RustCoreService.swift` (add clearData method)
- `Sources/CuztomSignalCore/SecretStore.swift` (add clearAll)
- `Sources/CuztomSignalCore/SQLiteMessageStore.swift` (add deleteDatabase)
**Change:** Delete SQLite DB, Keychain entries, attachment caches, path cache on logout

### 2.2 Fix SignalAddress Model - Separate groupId from threadId
**Files:**
- `Sources/CuztomSignalCore/Models.swift` (SignalAddress struct)
- `Sources/CuztomSignalCore/RustCoreService.swift` (chatMessage, applyRoster)
- `Sources/CuztomSignalCore/ChatController.swift` (send, sendReply, etc.)
**Change:** Add `threadId` field, make `groupId` hold only master key hex

### 2.3 Fix Message Deduplication - Persist UUID Mapping
**Files:**
- `Sources/CuztomSignalCore/RustCoreService.swift` (uuidCache persistence)
- `Sources/CuztomSignalCore/SQLiteMessageStore.swift` (store wire key → UUID mapping)
**Change:** Save `uuidCache` to disk, load on startup to prevent re-sync duplicates

### 2.4 Canonicalize Thread ID Parsing
**Files:** New `Sources/CuztomSignalCore/ThreadID.swift` + updates to all files
**Change:** Single source of truth for `threadId` ↔ `SignalAddress` ↔ `groupId` conversions

---

## Phase 3: Message Flow Fixes (Full day each)

### 3.1 Wire Delivery Receipts on Message Receive
**Files:**
- `Sources/CuztomSignalCore/ChatController.swift` (receive function)
- `Sources/CuztomSignalCore/RustCoreService.swift` (sendReceipt)
- `rust-core/src/sync.rs` (send_receipt - add group support)
**Change:** Auto-send "delivered" receipt when message received, "read" when viewed

### 3.2 Fix Group DM Routing (Critical Bug)
**Files:**
- `Sources/CuztomSignalCore/Models.swift`
- `Sources/CuztomSignalCore/RustCoreService.swift` (sendText, chatMessage)
- `rust-core/src/sync.rs` (do_send, parse_thread)
**Change:** Ensure group messages use correct thread parsing and group master key

### 3.3 Centralize Username/Display Name Resolution
**Files:**
- New `Sources/CuztomSignalCore/ContactResolver.swift`
- `Sources/CuztomSignalCore/ChatController.swift` (enrichNames)
- `Sources/CuztomSignalCore/RustCoreService.swift` (profileName)
- `XcodeApp/Sources/Views.swift` (MessageRow)
**Change:** Single service for resolving ACI/UUID → display name, with caching

---

## Phase 4: Major Features (Multiple days each)

### 4.1 Implement Group Management (Rust Side)
**Files:** `rust-core/src/groups.rs`, `rust-core/src/lib.rs`
**Change:** Implement all stub functions using presage's GroupsManager

### 4.2 Implement Group Management (Swift Side)
**Files:**
- `Sources/CuztomSignalCore/RustCoreService.swift` (FFI calls)
- `Sources/CuztomSignalCore/ChatController.swift` (group actions)
- `XcodeApp/Sources/Views.swift` / new GroupManagementView
**Change:** Wire up group creation, member management, settings

### 4.3 Implement Call Signaling (Rust + Swift)
**Files:**
- `rust-core/src/sync.rs` (call functions)
- `rust-core/src/lib.rs` (FFI)
- `Sources/CuztomSignalCore/CallController.swift`
- `XcodeApp/Sources/CallViews.swift`
**Change:** Integrate RingRTC for WebRTC calling

### 4.4 Attachment Cache Lifecycle Management
**Files:**
- `Sources/CuztomSignalCore/RustCoreService.swift` (pathCache, localPaths)
- `Sources/CuztomSignalCore/SQLiteMessageStore.swift`
- New cleanup utility
**Change:** LRU eviction, orphan cleanup, size limits

---

## Phase 5: Polish & Testing

### 5.1 Error Handling & User Feedback
### 5.2 Integration Tests for Send/Receive Flow
### 5.3 Message Search Implementation
### 5.4 Backup/Restore

---

## Execution Order (Start → Finish)

| # | Task | Est. Time | Dependencies |
|---|------|-----------|--------------|
| 1 | Fix read receipts display | 1 hr | None |
| 2 | Wire typing indicators | 1 hr | None |
| 3 | Auto-send read receipts | 30 min | #1 |
| 4 | Fix group sender name display | 1 hr | None |
| 5 | Implement clearAllData() logout | 4 hrs | None |
| 6 | Fix SignalAddress model | 4 hrs | #5 |
| 7 | Persist UUID mapping | 3 hrs | #6 |
| 8 | Canonicalize thread parsing | 3 hrs | #6 |
| 9 | Wire delivery receipts | 4 hrs | #3, #6 |
| 10 | Fix group DM routing | 6 hrs | #6, #8 |
| 11 | Centralize name resolution | 4 hrs | #4, #6 |
| 12 | Group management (Rust) | 2 days | #10 |
| 13 | Group management (Swift) | 1 day | #12 |
| 14 | Call signaling | 3 days | #10 |
| 15 | Attachment cache cleanup | 1 day | #5 |

**Total Estimate: ~2 weeks for Phases 1-3 (core fixes), ~2 more weeks for Phases 4-5**