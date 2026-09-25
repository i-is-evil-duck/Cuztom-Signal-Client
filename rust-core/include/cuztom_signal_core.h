#ifndef CUZTOM_SIGNAL_CORE_H
#define CUZTOM_SIGNAL_CORE_H

/*
 * Versioned C ABI for cuztom-signal-core.
 *
 * Keep this file in sync with the #[no_mangle] functions in src/lib.rs.
 * `scripts/check-ffi-parity.sh` verifies that every exported core_* symbol is
 * represented here. Strings returned by the library must be released with
 * core_free_string().
 */

#include <stddef.h>
#include <stdint.h>

#define CUZTOM_SIGNAL_CORE_ABI_VERSION 4u

#ifdef __cplusplus
extern "C" {
#endif

uint32_t core_abi_version(void);

/* Legacy plaintext initializer is intentionally fail-closed. */
int32_t core_cmd_init(const char *db_path);
int32_t core_cmd_init_encrypted(const char *db_path, const char *passphrase);

char *core_cmd_begin_link(const char *device_name);
int32_t core_cmd_poll_link(void);
int32_t core_cmd_is_linked(void);
char *core_cmd_whoami(void);
int32_t core_cmd_request_contacts(void);
int32_t core_cmd_start_sync(void);
char *core_cmd_poll_event(void);
char *core_cmd_roster(void);
int64_t core_cmd_send(const char *thread, const char *body);
int32_t core_cmd_logout(void);
int32_t core_cmd_wipe(void);
char *core_cmd_thread(const char *thread, uint64_t limit, uint64_t before_ts);
char *core_cmd_fetch_attachment(const char *thread, uint64_t ts, uint64_t index);
int64_t core_cmd_send_attachment(const char *thread, const char *path, const char *caption);
int64_t core_cmd_send_reply(const char *thread, const char *body, uint64_t quote_ts,
                            const char *quote_author, const char *quote_body);
int64_t core_cmd_send_delete(const char *thread, uint64_t target_ts);
int64_t core_cmd_send_reaction(const char *thread, uint64_t target_sts,
                               const char *target_author, const char *emoji,
                               int32_t remove);
int32_t core_cmd_delete_local(const char *thread, uint64_t sts);
int32_t core_cmd_send_receipt(const char *thread, const uint64_t *timestamps,
                              size_t timestamps_len, const char *kind);
int64_t core_cmd_send_message_edit(const char *thread, uint64_t target_ts,
                                   const char *new_body);
int32_t core_cmd_send_typing(const char *thread, int32_t started);

char *core_cmd_group_get_info(const char *master_key_hex);
int32_t core_cmd_group_update_title(const char *master_key_hex, const char *title);
int32_t core_cmd_group_update_avatar(const char *master_key_hex,
                                     const uint8_t *avatar_data, size_t avatar_len);
int32_t core_cmd_group_add_members(const char *master_key_hex,
                                   const char *const *member_acis,
                                   size_t member_acis_len);
int32_t core_cmd_group_remove_members(const char *master_key_hex,
                                      const char *const *member_acis,
                                      size_t member_acis_len);
int32_t core_cmd_group_promote_member(const char *master_key_hex, const char *member_aci);
int32_t core_cmd_group_demote_member(const char *master_key_hex, const char *member_aci);
char *core_cmd_group_get_invite_link(const char *master_key_hex);
int32_t core_cmd_group_revoke_invite_link(const char *master_key_hex);
int32_t core_cmd_group_leave(const char *master_key_hex);

uint64_t core_cmd_call_start(const char *thread, const char *media_type);
int32_t core_cmd_call_accept(uint64_t call_id);
int32_t core_cmd_call_hangup(void);
int32_t core_cmd_call_set_muted(int32_t muted);

/* Fetch today's ZK group auth credentials as raw JSON. Group calls derive a
 * membership proof from one of these. Returns a malloc'd JSON string to be
 * released with core_free_string(), or NULL on error. */
char *core_cmd_group_auth_credentials(void);

/* Build the CDN authorization for a group call membership proof.
 * `group_id` is the 32-byte ZK group identifier RingRTC reports. Returns a
 * malloc'd "hex(groupPublicParams):hex(presentation)" string to be released
 * with core_free_string(), or NULL on error. Nothing is synthesized: with no
 * server-issued credential there is no proof, and the join is refused. */
char *core_cmd_group_call_proof_authorization(const uint8_t *group_id,
                                             uint32_t group_id_len);

/* Derive the ZK group identifier for a group master key. Returns the 32-byte
 * identifier in hex, malloc'd, or NULL. Pure and offline; separate from
 * core_cmd_group_call_start so a host can learn a group's id without a call. */
char *core_cmd_group_call_group_id(const char *master_key_hex);

/* Build the RingRTC member identities for a group, so the SFU can attribute
 * call traffic to members. `member_acis_json` is a JSON array of ACI UUIDs.
 * Returns a JSON array of {"userId":"hex","memberId":"hex"}, malloc'd, or NULL.
 * One invalid service id fails the whole request: a partial roster misattributes
 * traffic silently rather than failing visibly. */
char *core_cmd_group_call_member_identities(const char *master_key_hex,
                                            const char *member_acis_json);

/* Group call lifecycle. `group_id_hex` is the group's 32-byte ZK identifier in
 * hex; `sfu_url` may be NULL to use the production SFU and is never inferred.
 * group_call_start returns the RingRTC client id plus one, so zero means
 * failure, and UINT64_MAX on error. Every later group-call command addresses a
 * client by that id. */
uint64_t core_cmd_group_call_start(const char *group_id_hex, const char *sfu_url);

/* Ask the SFU to admit a group call client. Raises the
 * `request_membership_proof` update the host answers. 0 ok, -1 error. */
int32_t core_cmd_group_call_join(uint32_t client_id);

/* Leave the SFU but keep the client so a call can be rejoined.
 * 0 ok, -1 error. */
int32_t core_cmd_group_call_leave(uint32_t client_id);

/* Leave if needed, then delete the client and forget it.
 * 0 ok, -1 error. */
int32_t core_cmd_group_call_end(uint32_t client_id);

/* Hand a group-call membership proof to RingRTC. RingRTC asks for this via a
 * `request_membership_proof` group update and will not send its SFU join request
 * until one arrives. Returns 0 on success, -1 on error. */
int32_t core_cmd_group_call_set_membership_proof(
    uint32_t client_id,
    const uint8_t *proof,
    size_t proof_len);

/* Supply the member identities the SFU needs to attribute call traffic.
 * `user_ids` is `count` concatenated 16-byte service ids, `member_lens` is
 * `count` u32 byte lengths, and `member_ids` holds the concatenated encrypted-UID
 * ciphertexts. Returns 0 on success, -1 on error. */
int32_t core_cmd_group_call_set_group_members(
    uint32_t client_id,
    uint32_t count,
    const uint8_t *user_ids,
    const uint32_t *member_lens,
    const uint8_t *member_ids,
    uint32_t member_count);

/* Deliver an SFU HTTP response that the host performed for RingRTC.
 * RingRTC raises SFU requests as `http_request` events and stalls until this
 * is called with the matching request id. A `status` of 0 reports that the
 * request could not be performed at all, which RingRTC treats differently from
 * an HTTP error status. Returns 0 on success, -1 on error. */
int32_t core_cmd_http_response(
    uint32_t request_id,
    uint32_t status,
    const uint8_t *body,
    size_t body_len);
int32_t core_cmd_send_call_offer(const char *call_id, const char *to,
                                 const char *media_type, const char *sdp);
int32_t core_cmd_send_call_answer(const char *call_id, const char *sdp);
int32_t core_cmd_send_call_ice(const char *call_id, const char *candidate,
                               const char *sdp_mid, uint32_t sdp_m_line_index);
int32_t core_cmd_send_call_hangup(const char *call_id, const char *reason);
int32_t core_cmd_send_call_signal(const char *thread, const char *call_message_json);
char *core_cmd_build_call_offer(const char *call_id, const char *media_type,
                                const char *opaque);
char *core_cmd_build_call_answer(const char *call_id, const char *opaque);
char *core_cmd_build_call_ice(const char *call_id, const char *opaque);
char *core_cmd_build_call_hangup(const char *call_id, uint32_t hangup_type,
                                 uint32_t device_id);
char *core_cmd_build_call_busy(const char *call_id);
char *core_cmd_parse_call_message(const char *call_message_json);
char *core_cmd_call_end_reason_to_string(int32_t reason);
char *core_cmd_profile(const char *uuid);

const char *core_last_error(void);
void core_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif /* CUZTOM_SIGNAL_CORE_H */
