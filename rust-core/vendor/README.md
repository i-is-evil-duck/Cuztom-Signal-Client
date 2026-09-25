# Vendored dependencies

## `presage/`

Copied from `https://github.com/whisperfish/presage` at rev
`33dd1491130793390e356e15a5711f1e6ca14fdb`, the same revision that
`Cargo.toml` pinned before vendoring.

### Why it is vendored

Group calls need a Signal ZK group **auth credential** to derive a membership
proof. The credential is only reachable through an authenticated chat-service
request, and `presage::manager::Registered` does not expose one: its
`groups_manager()` is private, and it never handles group credentials at all.

The capability already exists one layer down — `PushService::request` performs
generic authenticated requests and presage builds that service itself — so the
change is a single new method rather than a new dependency. Carrying it here
keeps the change auditable and reproducible instead of depending on a fork.

`presage` **and** `presage-store-sqlite` are both vendored and both patched.
Patching only `presage` would put two copies of the crate in the dependency
graph, because `presage-store-sqlite` depends on `presage` by relative path
inside the upstream workspace. Both must point at the same local tree.

### What was changed

See `presage/CHANGELOG-VENDOR.md` for the exact patch. In summary, one new
public method on `Registered` that issues
`GET /v1/certificate/auth/group?redemptionStartSeconds=…&redemptionEndSeconds=…&zkcCredential=true`
using the account's existing identified websocket.

### Updating

1. Copy the new upstream rev over this tree, keeping the file list identical.
2. Re-apply the changes listed in `presage/CHANGELOG-VENDOR.md`.
3. Update the `rev` in the `presage` and `presage-store-sqlite` entries in
   `../Cargo.toml` comments and the `[patch]` section so the provenance stays
   recorded even though the build now uses the local path.
4. Run `cargo test --all-targets` and `scripts/check-ffi-parity.sh`.
