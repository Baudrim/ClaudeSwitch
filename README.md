# ClaudeSwitch

A minimalist macOS menu bar app for saving and switching between accounts in the **Claude desktop app** (`Claude.app`, `com.anthropic.claudefordesktop`) -- the Electron-based chat client, not the Claude Code CLI.

## How it works

Claude desktop stores its login (OAuth tokens + session cookies) under `~/Library/Application Support/Claude/`, encrypted at rest with a per-machine key kept in the login Keychain (`Claude Safe Storage`). ClaudeSwitch never decrypts any of it -- it just:

1. Quits Claude.
2. Copies (or restores) the encrypted identity fragment of `config.json`, the `Cookies` database, and web storage folders into a per-account snapshot.
3. Relaunches Claude.

Because Claude keeps these files open in memory while running, switching **always** quits and relaunches the app -- there's no way to hot-swap accounts in a running Electron app, unlike the Claude Code CLI which re-reads its credentials on every invocation.

See [`ClaudeSwitch/Services/ProfileStore.swift`](ClaudeSwitch/Services/ProfileStore.swift) and [`ClaudeSwitch/Services/ClaudeDesktopService.swift`](ClaudeSwitch/Services/ClaudeDesktopService.swift) for the implementation.

## Adding an account

Sign into Claude with the account you want to save, then click **+** in the menu bar dropdown and give it a label. There's no separate login flow to build here -- Claude's own UI handles login; ClaudeSwitch just captures the result.

## Building

`project.yml` is the only source of truth for the Xcode project (via [XcodeGen](https://github.com/yonaskolb/XcodeGen)); `ClaudeSwitch.xcodeproj` is disposable and git-ignored.

```bash
brew install xcodegen   # once
xcodegen generate
open ClaudeSwitch.xcodeproj
```

## Status

Early prototype. Not code-signed for distribution; scope, error handling, and UI polish are expected to evolve.
