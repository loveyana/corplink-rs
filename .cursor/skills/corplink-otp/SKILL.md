---
name: corplink-otp
description: >-
  Generate Feilian/CorpLink VPN TOTP codes from macOS Keychain via the
  corplink-otp CLI. Use when the user or workflow needs a飞连 OTP, 2FA code,
  VPN verification code, or corplink one-time password.
---

# CorpLink OTP (Keychain)

## When to use

Invoke this skill when:

- User asks for 飞连 / CorpLink / Feilian **OTP** or **2FA code**
- Automation needs a 6-digit VPN verification code
- `corplink-rs` connect flow would prompt for `input your 2fa code`

**Do not** read `*_otp_secret.json` or `config.json` for secrets — the secret lives in **macOS Keychain** only.

## Command (preferred)

```bash
corplink-otp
```

Output: 6-digit code on stdout; `expires in N seconds` on stderr.

### JSON (for scripts / agents)

```bash
corplink-otp --json
```

Example output:

```json
{"code":"123456","expires_in":18}
```

Parse with `jq -r .code` if needed.

## Setup (one-time)

Install binary to `~/.local/bin` (must be on `PATH`):

```bash
./corplink-otp/scripts/install.sh
```

Import secret file into Keychain:

```bash
corplink-otp import config/corplink_otp_secret.json
```

Re-install after code changes:

```bash
./corplink-otp/scripts/install.sh
```

## Keychain entry

| Field | Value |
|-------|-------|
| Service | `corplink-rs-otp` |
| Account | `corplink` (override: `$CORPLINK_OTP_ACCOUNT`) |

Verify (shows metadata only, not secret):

```bash
security find-generic-password -s corplink-rs-otp -a corplink
```

## Agent workflow

1. Run `corplink-otp --json`
2. Use `code` field as the OTP (valid ~30s; check `expires_in`)
3. If command fails with keychain not found → tell user to run `corplink-otp import ...` once
4. **Never** print, log, or commit the TOTP secret or full Keychain password field

## Fallbacks

| Flag | Use |
|------|-----|
| `--file path.json` | Read secret from file instead of Keychain |
| `--secret BASE32` | Inline secret (debug only; avoid in chat) |
| `$CORPLINK_OTP_SECRET_FILE` | Default file path when not using Keychain |

Default behavior (no flags): **Keychain only**.

## Refresh secret

After re-login / new `corplink-rs otp fetch`:

```bash
corplink-otp import config/corplink_otp_secret.json
```

## Troubleshooting

| Error | Fix |
|-------|-----|
| `no TOTP secret in Keychain` | Run `import` subcommand |
| Wrong code / rejected by server | Re-import latest secret; check system clock (NTP) |
| `security: command not found` | macOS only; use `--file` on other OS |
