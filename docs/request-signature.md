# CorpLink / FeiLian Request Signature (`sign` header)

> Restored in upstream [PR #99](https://github.com/PinkD/corplink-rs/pull/99) (`restore request signature support`).
> Closes [#93](https://github.com/PinkD/corplink-rs/issues/93). Without this header, newer CorpLink backends return errors such as **`11020003 Request signature is empty`**.

Official Linux client and this Rust port attach an HTTP header:

```http
sign: v1;<base64(protobuf)>
```

Only two APIs are signed today (same rules as the official Linux client):

| API | Path (typical) | `signing_input_params` |
|-----|----------------|------------------------|
| List VPN | `GET /api/vpn/list?...` | `510` (`0b1_1111_1110`) |
| Connect VPN | `POST /vpn/conn?...` | `542` (`0b10_0001_1110`) |

Implementation: `src/client.rs` (`sign_request`, `hkdf_sha256`, `hmac_sha256`, `encode_sign_header`).

---

## Why it exists

CorpLink moved VPN list / connect behind a request integrity check:

1. Derive a per-device key from a shared root secret + `(company_name, device_id)`.
2. Build a **canonical byte string** from selected request fields (method, path, query, body hash, cookies, csrf, vpn-token, …).
3. HMAC-SHA256 that canonical string.
4. Pack `(key_version, input_bitmap, hmac)` into a tiny protobuf, Base64 it, send as `sign: v1;…`.

Servers reject unsigned or incorrectly signed list/connect calls. Login / OTP / ping flows are **not** signed by this bitmap.

---

## Key derivation (HKDF-SHA256)

Constants (from the official client / PR #99):

```text
SIGN_SECRET            = b"TOK@@AoNfRIX+3bla%"
SIGN_ROOT_KEY_VERSION  = 1
SIGN_HASH_BLOCK_SIZE   = 64
SIGN_HASH_OUTPUT_SIZE  = 32
```

```text
info = "{company_name}|{device_id}"
key  = HKDF-SHA256(
         ikm  = SIGN_SECRET,
         salt = empty → treated as 32 zero bytes for Extract,
         info = info,
         L    = 32
       )
```

Notes:

- Empty salt uses the HKDF convention of hashing against a zero-filled salt of hash length (see `hkdf_sha256` in `client.rs`).
- `device_id` must be present in config; missing `device_id` fails signing hard.
- The root secret is embedded in the official client binary (not a per-user password). Changing company or device identity changes the derived key.

---

## Canonical request / field bitmap

Signing fields are indexed **1…9** (index `0` is unused / empty):

| Bit index | Field | Source |
|-----------|-------|--------|
| 1 | HTTP method | `"GET"` / `"POST"` |
| 2 | URL path | e.g. `/api/vpn/list` |
| 3 | Query string | raw query without `?` |
| 4 | Body hash | SHA-256(body) if body non-empty, else empty |
| 5 | Cookie header | full `Cookie` header value |
| 6 | *(reserved / empty)* | always empty in current client |
| 7 | `csrf-token` header | value or empty |
| 8 | *(reserved / empty)* | always empty |
| 9 | `vpn-token` cookie | required for Connect; empty for List |

For each index `i` in `1…9`, if `(signing_input_params & (1 << i)) != 0`, append that field’s bytes to the canonical buffer **in order**.

### Bitmap `510` (List VPN)

```text
510 = 0b1_1111_1110
bits set: 1,2,3,4,5,6,7,8
```

Includes method, path, query, body hash, cookie, (empty bit-6), csrf, (empty bit-8).  
Does **not** include bit 9 (`vpn-token`).

### Bitmap `542` (Connect VPN)

```text
542 = 0b10_0001_1110
bits set: 1,2,3,4,5,9
```

Includes method, path, query, body hash, cookie, and **`vpn-token`**.  
Omits csrf (bit 7) and the empty reserved slots that List uses.

Connect also **requires** a `vpn-token` cookie (set when probing / selecting a VPN endpoint). Missing token → signing error before the HTTP call.

Then:

```text
signing_result = HMAC-SHA256(key, canonical_bytes)   # 32 bytes
```

---

## Wire format of the `sign` header

```text
sign = "v1;" + Base64( protobuf_message )
```

Protobuf fields (proto3 wire encoding, hand-written in `encode_sign_header`):

| Field | Type | Meaning |
|-------|------|---------|
| 1 | varint | `SIGN_ROOT_KEY_VERSION` (= 1) |
| 3 | varint | `signing_input_params` (510 or 542) |
| 4 | bytes | 32-byte HMAC |

Example shape check (from unit test):

```text
encode_sign_header(510, [0x11; 32])
→ hex body: 08 01 18 fe 03 22 20 <32×11>
            │     │        │
            │     │        └─ field 4, len 32, payload
            │     └─ field 3 = 510 (0xfe03 as varint)
            └─ field 1 = 1
```

Header example:

```http
sign: v1;CAEY/gMiIAAAAAAAAAAAAAAAAAAAAA...
```

---

## Request shape that must match official Linux

Signing alone is not enough: path/query must match what the official client sends so the server’s recomputed canonical string matches.

List / Connect URLs include app metadata and a fresh `timestamp` (seconds), for example:

- `app_version`, `build_number`, `client_source=FeiLian`
- `os` / `os_release` / `version` / `soc` / `language` / `brand` / `model`
- `timestamp=<unix_seconds>`

See `src/api.rs` (`ListVpnUrlParam`, `get_api_url` for `ListVPN` / `ConnectVPN`).

User-Agent is also aligned:

```text
CorpLink/{CORPLINK_APP_VERSION} (linux; Linux; en)
```

---

## End-to-end flow

```mermaid
sequenceDiagram
    participant C as corplink-rs
    participant S as CorpLink API

    Note over C: Login / SSO (unsigned)
    C->>S: session cookies + csrf-token

    Note over C: ListVPN (signed, params=510)
    C->>C: key = HKDF(secret, company\|device_id)
    C->>C: canonical = selected fields
    C->>C: sign = v1;b64(pb(1,510,HMAC))
    C->>S: GET /api/vpn/list?... + Cookie + sign
    S-->>C: VPN node list

    Note over C: Probe / pick endpoint (may set vpn-token)
    C->>S: GET /vpn/ping?...

    Note over C: ConnectVPN (signed, params=542)
    C->>C: include vpn-token in canonical
    C->>S: POST /vpn/conn?... + Cookie + csrf + sign + body
    S-->>C: WireGuard peer config
```

---

## Failure modes

| Symptom | Likely cause |
|---------|----------------|
| `11020003 Request signature is empty` | No `sign` header (old client) |
| Signature rejected / auth error on list | Wrong `device_id` / company, stale app metadata, clock skew on `timestamp` |
| Connect signing fails locally | Missing `vpn-token` cookie after probe |
| Cookie / csrf mismatch | Signed with headers that differ from what `reqwest` actually sends |

Debug tips:

1. Confirm `company_name` + `device_id` match the logged-in session.
2. Ensure cookies are loaded from `{interface_name}_cookies.json` next to the config.
3. Compare list URL query keys with official Linux client captures.
4. Unit tests in `client.rs`: HKDF vector + `sign_header_uses_observed_wire_shape`.

---

## Security notes

- `SIGN_SECRET` is a **client-embedded shared secret**, not a user credential. Anyone with the binary can derive the same keys for a known `(company_name, device_id)`.
- The header binds the request to session cookies / csrf / vpn-token and selected URL parts, raising the bar for naive replay or tampering of list/connect.
- Do not treat this as end-to-end authentication by itself; login/session cookies remain authoritative.

---

## References

- Upstream PR: <https://github.com/PinkD/corplink-rs/pull/99>
- Issue: <https://github.com/PinkD/corplink-rs/issues/93>
- Code: `src/client.rs` (`sign_request`, crypto helpers), `src/api.rs` (list/connect URL templates)
