# Vendored presage — local changes

Source: `https://github.com/whisperfish/presage` @
`33dd1491130793390e356e15a5711f1e6ca14fdb`

Only two files differ from upstream. Keep this list accurate when updating.

## 1. `presage/Cargo.toml`

Added one dependency:

```toml
reqwest = { version = "0.13", default-features = false }
```

Needed for `reqwest::Method` in the new request. `reqwest` was already in the
dependency graph through `libsignal-service`, at the same version, so this
adds no new crate — only a new direct edge. `default-features = false` keeps
the TLS/cookie features that libsignal-service already enables.

## 2. `presage/src/manager/registered.rs`

Added one method to `impl Registered`:

```rust
pub async fn group_auth_credentials_raw(
    &self,
    start_day: u64,
    end_day: u64,
) -> Result<String, Error<S::Error>>
```

It issues:

```
GET /v1/certificate/auth/group
      ?redemptionStartSeconds=<start_day>
      &redemptionEndSeconds=<end_day>
      &zkcCredential=true
```

using the account's existing identified push service, and returns the response
body as raw JSON.

Design notes:

- **The body is returned unparsed.** The response shape belongs to the group-call
  protocol, not to presage, so decoding lives in
  `cuztom-signal-core/src/group_calls.rs` where it is unit tested.
- **Non-2xx becomes an error** and the response body is dropped, because it can
  echo request material and the status is what a caller acts on.
- `reqwest::Error` is mapped to `Error::IoError` because presage's `Error` has
  no `From<reqwest::Error>`.

This is the minimum needed. The alternative — reaching the same endpoint without
touching presage — is not available: `groups_manager()` is private, presage
never handles group credentials, and the authenticated service is only
constructible from inside `Registered`.

## Re-applying after an upstream update

1. Replace the tree with the new rev.
2. Re-apply both changes above.
3. `cargo test --all-targets` in `rust-core/`.
4. `scripts/check-ffi-parity.sh`.
