# CorpLink RS GUI

Simple macOS wrapper around `corplink-rs`.

## Features

- Connect / Disconnect (admin password per action)
- Route mode + node switch (window + **menu bar**)
- Live **飞连 OTP** with Copy (window + menu bar ⌘⇧C)
- **Global OTP hotkey** (default `⌃⌘O`, configurable in menu / `config/gui_settings.json`; skips register on conflict)
- SSO as a **step sheet** (not always-on URL dump); log collapsed by default
- Auto-open SSO disabled; Confirm gate before tunnel continues
- App icon via AEye (`gui/Resources/AppIcon.icns`)

## Build

```bash
# 1) VPN binary (with request signature + CORPLINK_GUI SSO poll)
cd /Users/bytedance/myGolang/corplink-rs
cargo build --release

# 2) GUI
cd gui
./build.sh
open CorplinkGUI.app
```

Or:

```bash
cd gui/CorplinkGUI
swift build -c release
# then run via ../build.sh which wraps it into an .app
```

## Env overrides (optional)

| Variable | Default |
|----------|---------|
| `CORPLINK_BIN` | `../target/release/corplink-rs` |
| `CORPLINK_CFG` | `../config/config.json` |
| `CORPLINK_LOG` | `/tmp/corplink-gui.log` |

## GUI settings (`config/gui_settings.json`)

```json
{
  "otp_global_hotkey": "ctrl+cmd+o"
}
```

Allowed values: `off`, `ctrl+cmd+o`, `ctrl+cmd+c`, `option+cmd+o`, `ctrl+option+cmd+o`.  
If the chosen combo is already taken (`RegisterEventHotKey` conflict), the app will **not** arm it and asks you to pick another under **OTP Hotkey** in the menu bar.

## Notes

- Needs admin because WireGuard TUN requires root.
- Set `CORPLINK_GUI=1` is handled by `gui/scripts/vpn-start.sh` so SSO no longer waits for Enter.
- Keep official CorpLink app/service disabled to avoid conflicts.
