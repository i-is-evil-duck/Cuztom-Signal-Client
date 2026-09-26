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

#define CUZTOM_SIGNAL_CORE_ABI_VERSION 6u

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

/* Redeem a group membership proof for a call token at the configured CDN.
 * `authorization` is the hex(groupPublicParams):hex(presentation) value from
 * core_cmd_group_call_proof_authorization. Returns malloc'd JSON
 * {"tokenB64":"..."} or NULL.
 *
 * Performed natively because the CDN's certificate comes from Signal's own
 * authority rather than the system roots: a host HTTP client rejects it while
 * this one, already built with the service configuration's certificate
 * authority, accepts it. The proof travels in the Authorization header and is
 * never logged. */
char *core_cmd_group_call_redeem_proof(const char *authorization);

/* The CDN base URLs this account's service configuration declares, as
 * [{"id":0,"url":"https://..."}, ...]. Returns malloc'd JSON, or NULL.
 *
 * A group membership proof is redeemed at a CDN, and the host belongs to the
 * service configuration rather than to the client: a hardcoded host is wrong on
 * staging and presents as an unreachable endpoint rather than a configuration
 * mistake. Fails when no CDN is configured, rather than falling back. */
char *core_cmd_cdn_urls(void);

/* A group's title and member ACIs, which a group call's roster needs. Returns
 * malloc'd JSON, or NULL. A group this device is not a member of is refused
 * rather than reported as empty: an empty roster reads as "you are alone". */
char *core_cmd_group_roster(const char *master_key_hex);

/* Map each ZK group id this device belongs to back to its master key. Returns
 * malloc'd JSON, or NULL. A group call names a group by identifier, and a call
 * for a group this device is not in is not receivable. */
char *core_cmd_group_id_map(void);
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

/* Say whether this device's microphone is muted in a group call.
 *
 * RingRTC begins a group call with the audio-muted heartbeat field unset and
 * reads that as muted, so a host that never calls this is a participant the rest
 * of the call believes has its microphone off. `muted` is 0 or 1. Returns 0 on
 * success, -1 on error. */
int32_t core_cmd_group_call_set_audio_muted(uint32_t client_id, uint32_t muted);

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

/* Perform one of the SFU's own HTTP requests, on RingRTC's behalf.
 *
 * RingRTC raises SFU requests to its host and stalls until they are answered, so
 * this is the only way they can be performed. Done natively because the SFU serves
 * a certificate from Signal's own authority rather than the system roots, which a
 * host HTTP client rejects at the TLS layer.
 *
 *   method, url    - NUL-terminated UTF-8. `url` must be https; a plaintext hop
 *                    would carry the membership proof in the clear.
 *   header_count   - number of headers.
 *   header_names,
 *   header_values  - parallel arrays of `header_count` NUL-terminated UTF-8
 *                    strings. Names and values are passed through untouched.
 *   body, body_len - request body, which may be empty.
 *
 * Returns malloc'd JSON, {"status":<int|null>,"bodyB64":"<base64>"}, or NULL on
 * error (see core_last_error). `status` is null when the request could not be
 * performed at all, which RingRTC distinguishes from an HTTP error status; that
 * is reported in the JSON rather than through the return value, because a
 * transport failure is not the SFU refusing. `bodyB64` is base64 because the body
 * is arbitrary bytes.
 *
 * Nothing about the request is logged. RingRTC puts the membership proof in the
 * Authorization header. */
char *core_cmd_sfu_http_request(
    const char *method,
    const char *url,
    uint32_t header_count,
    const char *const *header_names,
    const char *const *header_values,
    const uint8_t *body,
    size_t body_len);

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
