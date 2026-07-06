# ClaudeSwitch

A minimalist macOS menu bar app for saving and switching between accounts in the **Claude desktop app** (`Claude.app`, `com.anthropic.claudefordesktop`) -- the Electron-based chat client, not the Claude Code CLI.

> **Disclaimer:** ClaudeSwitch is an independent, unofficial tool. It is **not affiliated with, endorsed by, or sponsored by Anthropic**. "Claude" and the Claude logo are trademarks of Anthropic; they are referenced here only to identify the app this tool interoperates with (nominative use).

## How it works

Claude desktop stores its login (OAuth tokens + session cookies) under `~/Library/Application Support/Claude/`, encrypted at rest with a per-machine key kept in the login Keychain (`Claude Safe Storage`). ClaudeSwitch never decrypts any of it -- it just:

1. Quits Claude.
2. Copies (or restores) the encrypted identity fragment of `config.json`, the `Cookies` database, and web storage folders into a per-account snapshot.
3. Relaunches Claude.

Because Claude keeps these files open in memory while running, switching **always** quits and relaunches the app -- there's no way to hot-swap accounts in a running Electron app, unlike the Claude Code CLI which re-reads its credentials on every invocation.

Snapshots live under `~/Library/Application Support/ClaudeSwitch/snapshots/<uuid>/`. Account labels are kept in `UserDefaults`; **no tokens are ever stored by ClaudeSwitch itself**. See [`ClaudeSwitch/Services/ProfileStore.swift`](ClaudeSwitch/Services/ProfileStore.swift) and [`ClaudeSwitch/Services/ClaudeDesktopService.swift`](ClaudeSwitch/Services/ClaudeDesktopService.swift) for the implementation.

## Requirements

- **macOS 26** or later (uses Liquid Glass / Icon Composer APIs).
- The [Claude desktop app](https://claude.ai/download) installed.
- To build: **Xcode 26+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Installation

### Option A -- Download a prebuilt build

1. Download `ClaudeSwitch.zip` from the [Releases](../../releases) page and unzip it.
2. Move `ClaudeSwitch.app` to `/Applications`.
3. Because the build is ad-hoc signed (not notarized), macOS Gatekeeper will block it on first launch. Clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeSwitch.app
   ```

   Alternatively: right-click the app > **Open**, then confirm in the dialog, or allow it from **System Settings > Privacy & Security > "Open Anyway"**.
4. Launch it -- ClaudeSwitch lives in the menu bar (there's no Dock icon or main window).

### Option B -- Build from source

`project.yml` is the only source of truth for the Xcode project (via XcodeGen); `ClaudeSwitch.xcodeproj` is disposable and git-ignored.

```bash
brew install xcodegen   # once
git clone https://github.com/Baudrim/ClaudeAppSwitch.git
cd ClaudeAppSwitch
xcodegen generate
open ClaudeSwitch.xcodeproj
```

Then press **Run** in Xcode. Building from source avoids the Gatekeeper quarantine step entirely.

## Usage

1. **First launch:** ClaudeSwitch will ask for **Automation** permission the first time it needs to quit/relaunch Claude (System Settings > Privacy & Security > Automation). This is required to swap the active session.
2. **Add an account:** sign into Claude with the account you want to save, then click **+** in the menu bar dropdown and give it a label. Claude's own UI handles login; ClaudeSwitch just captures the result.
3. **Switch:** click **Switch** on any saved account. ClaudeSwitch quits Claude, restores that account's snapshot, and relaunches. The active account slides to the top.
4. **Refresh:** re-captures the currently active account's session so its snapshot doesn't go stale.

## Packaging a distributable build

`scripts/package.sh` builds a Release `.app`, ad-hoc signs it, and zips it into `dist/`:

```bash
./scripts/package.sh
# override the toolchain location if needed:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/package.sh
```

For friction-free public distribution, swap the ad-hoc signing step for a Developer ID identity + notarization (see the `NOTARIZE` note inside the script).

## Credits & assets

- App icon composed with Xcode's Icon Composer. If you fork this for public distribution, review the icon assets in `Icon/ClaudeSwitch.icon/Assets/` for third-party trademarks and license terms before shipping.

## Status

Early prototype. Distributed unsigned/ad-hoc; scope, error handling, and UI polish are expected to evolve.

## License

MIT -- see [`LICENSE`](LICENSE).
