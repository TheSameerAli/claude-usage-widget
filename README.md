# Claude Usage (menu bar)

A tiny native macOS menu bar app that shows your Claude plan usage at a glance:

- **Menu bar:** `◔ 11% · 91%` (5-hour session · weekly, all models)
- **Click it:** a panel listing each limit with a bar, % used, and when it resets (session, weekly, and per-model weekly limits)

It reads the OAuth login that Claude Code already stores in your Keychain (`Claude Code-credentials`) and calls the same usage endpoint that `/usage` uses. It refreshes every 5 minutes, each time you open the panel (at most once a minute), and on wake from sleep. The token is never refreshed, copied, or written anywhere.

## Install

```sh
./scripts/install.sh     # builds, copies to ~/Applications, launches at login
./scripts/uninstall.sh   # removes it
```

Or build only: `./scripts/build-app.sh`, then `open build/ClaudeUsage.app`.

Requires macOS 14+ and the Swift toolchain (`xcode-select --install`).

## Notes

- If the panel says the token has expired, open Claude Code once. Claude Code refreshes the token itself.
- The usage endpoint is undocumented and may change. The decoder ignores unknown fields and falls back to the older `five_hour`/`seven_day` shape.
