# Rightly

Smart Hebrew and Arabic right-to-left support for GPT Work / Codex and Claude Desktop on Windows.

Rightly detects RTL characters anywhere in a line, aligns mixed-language content correctly, and keeps code, application controls, and English-only text left-to-right. It also handles lists, tables, the message composer, and mixed Hebrew-English task titles in the sidebar.

## Features

- Hebrew or Arabic anywhere in a line switches that line to RTL, even when it starts in English.
- English-only content and application chrome remain LTR.
- Inline code and code blocks remain LTR.
- Bullets and numbered-list markers stay on the correct side.
- RTL tables are centered and their cells are aligned correctly.
- Mixed Hebrew-English sidebar titles preserve their reading order while remaining left-aligned.
- Long conversations are processed in small idle-time batches to avoid blocking the interface.
- No scheduled task, watcher, persistent Node process, or background repair service is installed.

## Requirements

- Windows 10 or Windows 11.
- The official GPT Work / Codex app and/or Claude Desktop.
- [Node.js LTS](https://nodejs.org/) for the injection runtime and ASAR tooling.
- An internet connection during installation.
- Administrator approval when requested. It is required for Claude patching and legacy-installation cleanup.

## Installation

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/NoamHermos/rightly/main/installer/install-online.ps1 | iex
```

Choose one target from the interactive menu:

1. `GPT Work / Codex`
2. `Claude Desktop / Code`
3. `Both`

Rightly closes and reopens only the selected application. The installer also creates one desktop shortcut named **Repair RTL**, using the Rightly icon.

For a reviewable local installation, download the repository, inspect the scripts, and run `installer/install.bat` instead of executing the online command directly.

## Usage and updates

- The selected app opens with the RTL correction active after installation.
- **Repair RTL** downloads the current `main` snapshot before showing the target menu, so every successful repair uses the latest project code. An internet connection is required.
- After an official app update, run **Repair RTL** and select only the app that was updated.
- GPT injection is applied in memory to the official app. After fully closing GPT or restarting Windows, run **Repair RTL** and select GPT again.
- Claude is patched in place and remains corrected until an official update replaces its files. Run **Repair RTL** again after that update.
- The local repair bundle refreshes itself during each repair. Rightly does not keep an automatic updater or repair process running in the background.

## How it works

### GPT Work / Codex

Rightly launches the official `ChatGPT.exe` with a temporary Chromium DevTools endpoint restricted to `127.0.0.1` and a random port. A small Node process connects to the renderer, injects `codex-rtl-payload.js`, verifies the marker, and disconnects after a bounded 20-second startup window. The official OpenAI package is neither copied nor modified.

### Claude Desktop / Code

Rightly downloads a pinned revision of [`shraga100/claude-desktop-rtl-patch`](https://github.com/shraga100/claude-desktop-rtl-patch), verifies its known SHA-256 digest, replaces its RTL payload, and applies it directly to Claude's official ASAR with backup and rollback support. Rightly does not create a copied Claude application, and it removes known legacy auto-update mechanisms.

> [!WARNING]
> The Claude integration modifies signed application files and uses the upstream patch engine's local self-signed certificate mechanism. This is an unofficial modification, may conflict with Anthropic's terms or future app updates, and is used at your own risk.

### Direction rules

- A line containing a Hebrew or Arabic letter is rendered RTL, regardless of its first word.
- A line without RTL letters remains LTR.
- Inline code and code blocks remain LTR.
- Lists place their markers on the correct side.
- RTL tables stay within the message width and are centered in the content area.
- Sidebar task titles remain left-aligned; titles containing Hebrew receive a hidden `U+200F` mark to preserve word order.
- Long threads are updated in bounded idle-time batches rather than full-page synchronous scans.

## Project structure

| Path | Responsibility |
| --- | --- |
| `installer/` | Online and local entry points, repair wrapper, and shared installation helpers |
| `src/gpt/` | GPT integration, launcher, local injector, and direction payload |
| `src/claude/` | Verified Claude patcher and direction payload |
| `assets/` | Rightly branding used by the repair shortcut |
| `docs/` | Third-party notices and supporting documentation |
| `.github/` | GitHub Actions and the security policy |
| `tests/` | Behavior, structure, and integration verification |

The payloads are intentionally standalone files: each is injected into a renderer as one unit without a bundler or runtime dependency. Installation code is separated by responsibility so each target can be repaired or removed independently.

## Privacy and security

- Rightly does not send conversation content to its own server.
- GPT's DevTools endpoint listens only on the local loopback interface and the injector disconnects after startup.
- The external Claude engine is pinned to an exact commit and verified with SHA-256 before execution.
- No automatic patcher, scheduled task, watcher, or persistent Node process is installed.
- Read the [security policy](.github/SECURITY.md) before reporting a vulnerability.

## Uninstallation

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/NoamHermos/rightly/main/installer/uninstall-online.ps1 | iex
```

Choose GPT, Claude, or both. GPT removal deletes only Rightly's local runtime. Claude removal restores the official backups. Selecting both also removes the repair bundle and desktop shortcut.

## Troubleshooting

- Repair shortcut logs: `%LOCALAPPDATA%\Programs\Rightly\Repair\logs`
- GPT injection log: `%LOCALAPPDATA%\Programs\Rightly\GPT\logs\gpt-runtime.log`
- If an app update changes the interface, run **Repair RTL** for that app.
- If Claude installation fails, do not delete `.bak` files manually; use the uninstaller so the rollback engine can restore them.

## Development

Run the complete local verification suite from PowerShell:

```powershell
node tests/direction.test.js
node tests/claude-direction.test.js
./tests/verify-static.ps1
./tests/verify-package.ps1
./tests/verify-codex.ps1 -SkipInstalledBuild
./tests/verify-claude.ps1 -SkipInstalledBuild
```

Rightly is an independent project and is not affiliated with OpenAI or Anthropic. Product names belong to their respective owners. The project is distributed under the [MIT License](LICENSE); third-party licenses and attribution are listed in [THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).
