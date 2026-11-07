# Claude Usage (menu bar)

A tiny native macOS menu bar app that shows your Claude and Codex plan usage at a glance:

- **Menu bar:** `◔ 11% · 91% │ 40% · 46%` (Claude session · weekly │ Codex session · weekly)
- **Click it:** a panel with a section per tool, listing each limit with a bar, % used, and when it resets (session, weekly, and per-model weekly limits)

**Claude:** it reads the OAuth login that Claude Code already stores in your Keychain (`Claude Code-credentials`) and calls the same usage endpoint that `/usage` uses.

**Codex:** it reads the ChatGPT login that Codex stores in `~/.codex/auth.json` (or `$CODEX_HOME`) and calls the same endpoint that Codex's `/status` uses. If that fails (offline, expired token), it shows the last rate-limit snapshot from Codex's session logs and says so. The Codex section only appears if `~/.codex` exists.

It refreshes every 5 minutes, each time you open the panel (at most once a minute), and on wake from sleep. Tokens are never refreshed, copied, or written anywhere.

## Install

```sh
./scripts/install.sh     # builds, copies to ~/Applications, launches at login
./scripts/uninstall.sh   # removes it
```

Or build only: `./scripts/build-app.sh`, then `open build/ClaudeUsage.app`.

Requires macOS 14+ and the Swift toolchain (`xcode-select --install`).

## Notes

- If the panel says a token has expired, open Claude Code (or Codex) once. Each tool refreshes its own token.
- Both usage endpoints are undocumented and may change. The decoder ignores unknown fields and falls back to the older `five_hour`/`seven_day` shape.
