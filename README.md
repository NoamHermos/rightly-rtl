# Rightly

Rightly adds intelligent Hebrew and Arabic right-to-left rendering to the official GPT Work / Codex and Claude Desktop applications on Windows.

It detects RTL letters anywhere in a line, even when the line begins with an English word. Mixed-language messages, lists, tables, task titles, and interactive question panels are rendered in the correct reading direction, while code and English-only interface elements remain left-to-right.

## Requirements

- Windows 10 or Windows 11.
- The official GPT Work / Codex application and/or Claude Desktop.
- [Node.js LTS](https://nodejs.org/) for verified ASAR rebuilding and the protected-package GPT startup injector.
- An internet connection during installation and repair.
- Administrator approval when Windows requests it.

Save active work before installing or repairing. Rightly closes only the application selected in the menu, waits for its files to be released, applies and verifies the correction, and then reopens that application.

## Installation

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/NoamHermos/rightly/main/installer/install-online.ps1 | iex
```

Choose one target:

1. `GPT Work / Codex`
2. `Claude Desktop / Code`
3. `Both`

The installer downloads the current `main` revision, requests elevation when required, removes obsolete Rightly installations, and installs the selected correction. It creates a desktop shortcut named **Repair RTL** using the general Rightly icon.

If Windows protects GPT's Microsoft Store package from verified in-place modification, Rightly automatically installs its protected-package startup mode. In that mode it also creates **Rightly GPT** shortcuts on the desktop and in the Start menu. **Rightly GPT** uses a separate GPT-and-Rightly icon so it is visually distinct from **Repair RTL**.

### Which shortcut should be used?

| Shortcut | Purpose | When to use it |
| --- | --- | --- |
| **Rightly GPT** | Opens the official GPT application with verified RTL support when the Store package is protected | Use for normal GPT startup when this shortcut was created |
| **Repair RTL** | Downloads the latest Rightly code and repairs GPT, Claude, or both | Use after an official application update or when the interface changes |

Claude is patched directly and can be opened from its normal shortcut. GPT can also be opened normally when the installer reports that its persistent in-place patch succeeded. When **Rightly GPT** exists, use it for everyday GPT startup.

## Everyday behavior

The **Rightly GPT** launcher is a small, windowless executable with a branded progress window. It reports the current phase: checking the existing process, opening GPT, applying the payload, and verifying the live renderer.

Its behavior depends on GPT's current state:

| GPT state | Rightly action |
| --- | --- |
| Not running | Opens the official package with a private loopback debugging endpoint, injects the payload, and verifies its marker |
| Open and already corrected | Verifies the live marker and focuses the existing window without restarting it |
| Minimized to the taskbar | Restores and focuses the existing corrected window |
| Running only in the notification area with no window | Preserves the existing process, asks the official package to create a new window, applies Rightly to the new renderer, and verifies it without changing the GPT PID |
| Open without a verified correction | Closes that uncorrected process tree once and reopens GPT with verified Rightly support |
| Launcher clicked twice | A Windows single-instance lock keeps the first startup active; the second click displays that GPT will open shortly and starts no additional injector |

On success, the progress window confirms that Rightly is active and closes automatically. On failure, it remains open with a clear status instead of producing overlapping error dialogs.

After GPT or Claude is updated, run **Repair RTL** and select only the application that was updated. The repair shortcut always downloads the latest `main` snapshot before applying a repair, so it does not keep using installer code from the original installation.

## How it works

### Direction engine

Rightly installs a renderer payload tailored to each application. The payload applies these rules:

- A text line containing a Hebrew or Arabic letter is rendered RTL regardless of its first word.
- A line without RTL letters remains LTR.
- Inline code, code blocks, and technical controls remain LTR.
- Bullets and numbered-list markers stay on the correct side.
- Tables containing RTL text are centered within the message width, use the correct column direction, and align RTL cells correctly.
- Mixed Hebrew-English task titles remain left-aligned in the sidebar while receiving an invisible `U+200F` mark that preserves their reading order.
- Claude interactive question and answer panels receive the same direction rules as normal messages.
- Long conversations are processed in small idle-time batches instead of synchronous full-page scans.

DOM mutations are queued and processed incrementally. This lets Rightly handle newly streamed messages and newly opened chats without repeatedly scanning the complete conversation or blocking the interface.

### GPT Work / Codex

Rightly first attempts a persistent in-place ASAR patch:

1. It locates the current official `OpenAI.Codex` Microsoft Store package.
2. It force-closes only that package's process tree and waits for mapped-file handles to be released.
3. It creates a version-specific backup of the original external `app.asar`.
4. It embeds the Rightly payload in the relevant renderer entry bundles.
5. It rebuilds the ASAR and verifies the original, backup, rebuilt, and installed files with SHA-256.
6. It records the exact package identity and refuses to restore a backup across package versions.

If the installed ASAR hash matches the verified patched hash, Rightly remains active when GPT is opened normally.

Microsoft Store packages can reject replacement even for an administrator. If Windows keeps the ASAR immutable, Rightly verifies that the official file is still original and switches to protected-package startup mode instead of leaving a partial modification.

In protected-package mode:

1. `Rightly GPT.exe` starts a hidden PowerShell controller and displays a branded status window.
2. The controller uses a random local port bound to `127.0.0.1` and activates the official package with Chromium's loopback DevTools endpoint.
3. A short-lived Node.js injector connects only to page-specific local WebSockets.
4. It evaluates the same Rightly renderer payload and checks `globalThis.__RT_AI_CODEX_RTL_PATCH__` inside the live renderer.
5. Startup is reported as successful only after that marker returns `true`.
6. The injector disconnects after its bounded startup window. No persistent Node process is left running.

When GPT remains in the notification area after its last window is closed, its previous renderer may no longer exist. Rightly recognizes the existing process by its loopback address, debugging port, and launch flags. It keeps that process alive, briefly attaches an injector to the same port, activates the official package to create a window, and verifies the new renderer. This is why reopening from the tray does not require a process restart.

### Claude Desktop / Code

Rightly applies the correction to Claude's official installation rather than creating a copied application. It downloads a pinned revision of the upstream Claude patch engine, verifies its expected SHA-256 digest, replaces its direction payload with Rightly's current implementation, and then runs the verified engine with backup and rollback support.

The verified engine applies it directly to Claude, and Rightly does not create a copied Claude application.

The Claude integration removes known legacy automatic patchers and copied-app shortcuts. After installation, Claude can be closed, reopened, or started normally until an official update replaces the modified files.

### Updates and background activity

No scheduled task, watcher, persistent Node process, or background repair service is installed. An official application update may replace patched files, so repair is intentionally user-triggered through **Repair RTL**.

The repair shortcut stores a small local repair bundle under:

```text
%LOCALAPPDATA%\Programs\Rightly\Repair
```

Protected-package GPT runtime files and logs are stored under:

```text
%LOCALAPPDATA%\Programs\Rightly\GPT
```

Persistent GPT state and its version-matched rollback backup are stored under:

```text
%ProgramData%\Rightly\GPT
```

Rightly does not send conversation content to a Rightly server. The GPT loopback endpoint accepts local connections only, and the injector disconnects after verification.

## Uninstallation

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/NoamHermos/rightly/main/installer/uninstall-online.ps1 | iex
```

Choose GPT, Claude, or both.

- A persistent GPT installation restores only its verified backup for the exact installed package version.
- A protected-package GPT installation removes its launcher, icon, runtime files, and shortcuts without modifying the official package.
- Claude is restored through its verified rollback mechanism.
- Selecting both also removes the shared repair bundle and **Repair RTL** shortcut.

## Important notice

Rightly is an independent, unofficial project and is not affiliated with OpenAI or Anthropic. The persistent GPT mode and Claude integration modify signed application files; the protected-package GPT mode uses a local DevTools endpoint during startup. These techniques may be affected by future application updates and are used at your own risk.

The project is distributed under the [MIT License](LICENSE). Third-party licenses and attribution are listed in [THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md), and security information is available in the [security policy](.github/SECURITY.md).
