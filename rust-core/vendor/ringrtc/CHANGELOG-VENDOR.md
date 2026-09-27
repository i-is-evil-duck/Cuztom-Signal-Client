# Vendored ringrtc — local changes

Source: `https://github.com/signalapp/ringrtc` @
`a1d2ffed1de6ac5b22458a3dced8374513cc44f8`

Vendored because group calls could not ring at all without one small addition.
The crate is consumed as a path dependency at `vendor/ringrtc/src/rust` (the
repository root is a virtual workspace manifest, not a package).

`out/` and `out-arm/` are build output and gitignored upstream, so they are not
vendored.

## 1. `src/rust/src/core/call_manager.rs`

One method added to `impl CallManager`.

### `ring_group`

```rust
pub fn ring_group(&mut self, client_id: group_call::ClientId) -> Result<()>
```

Finds the group call client for `client_id` and calls `Client::ring(None)` on it.

**Why it is needed.** `group_call::Client::ring` is the intended entry point for
starting a group call's ring, but `group_call_by_client_id` is private and there
was no public way to reach a client from a client id. So the host could not ring at
all, and the only alternative was composing the `ring_intention` by hand.

**Why that alternative is wrong**, and this is the reason the change is a real
patch rather than a workaround:

- The `ring_id` must be `RingId::from_era_id(&joined.era_id)`. `era_id` is a
  private `String` on the internal `Joined` struct and never leaves RingRTC, so a
  host cannot derive it.
- Whether the client may ring at all is the SFU's decision: after the join,
  `joined.creator` is compared against our own uuid to produce `PermittedToRing`
  or `NotPermittedToRing`.
- `outgoing_ring_state` has to agree with reality, or the client concludes
  someone else started the call — which RingRTC logs as `ringing is not permitted
  (client_id: N); most likely someone else started the call first`. That message
  was observed against a real client while the hand-built ring was in use.

All three live behind `ring_inner`. `Client::ring` sets `WantsToRing`, and the
SFU join completion consumes it once `PermittedToRing` is known.

`recipient` is not a parameter: a group ring is always group-wide, and `ring_inner`
asserts that anyway.

## Re-applying after an upstream update

1. Replace `vendor/ringrtc` with the new rev, excluding `out/`, `out-arm/`,
   `target/` and `.gradle/`.
2. Re-apply `CallManager::ring_group` above. If upstream has added a public way
   to reach a group call client by id, use that instead and drop this method.
3. `PATH="$PWD/scripts:$PATH" cargo test --all-targets` in `rust-core/`.
4. `sh scripts/check-ffi-parity.sh`.

If `ring_group` becomes unnecessary, the host-side fallback in
`src/call.rs::ring_group` is the only thing to remove; it exists solely to call
this.

## 2. `src/rust/src/native.rs`

One method added to `impl NativePlatform`.

### `set_microphone_warmup`

```rust
pub fn set_microphone_warmup(&mut self, enabled: bool) -> Result<()>
```

Forwards to `PeerConnectionFactory::set_audio_warmup`, which is already public but
unreachable: the factory is a private field and `CallManager` exposes no path to
it beyond the platform.

**Why it is needed.** `audio_device_module.rs` only ever calls `init_recording`
from `set_audio_warmup` and from `update_recording_device` — and the latter does so
only `if was_initialized`, which it cannot be on the first call. `start_recording`
then fails outright:

```
Cannot start recording without an input stream -- did you forget init_recording?
```

So a host that selects a recording device but never warms the microphone ends up
with a live outgoing audio track carrying nothing. The symptom is deceptive rather
than loud: incoming audio initialises on a separate path, so such a client
**receives perfectly and transmits silence** while reporting itself joined,
ICE-connected, unmuted, and holding a media key it has already sent. RingRTC logs a
warning, through a logger this build does not surface.

**Why it is a vendor change and not a workaround.** There is no host-side
alternative. The device module is reached only through the factory, the factory is
private to the platform, and the one function that opens the input is not called
from anywhere else in the crate. Signal's own clients call the equivalent
(`setMicrophoneWarmupEnabled`) before connecting a call, so this restores intended
behaviour rather than adding any.

**Re-applying after a re-vendor.** Add the method verbatim to `impl NativePlatform`
in `src/rust/src/native.rs`. It has no dependencies beyond the existing
`PeerConnectionFactory` import.
