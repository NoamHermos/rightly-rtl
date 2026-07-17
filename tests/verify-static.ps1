$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Read-RepoFile {
    param([string] $RelativePath)
    return Get-Content -LiteralPath (Join-Path $repoRoot $RelativePath) -Raw
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$required = @(
    "README.md",
    "LICENSE",
    ".github\SECURITY.md",
    "docs\THIRD_PARTY_NOTICES.md",
    "installer\install.ps1",
    "installer\install-online.ps1",
    "installer\install.bat",
    "installer\uninstall.ps1",
    "installer\uninstall-online.ps1",
    "installer\uninstall.bat",
    "installer\run-repair.ps1",
    "installer\lib\Rightly.Install.ps1",
    "assets\rightly-logo.png",
    "assets\rightly.ico",
    "assets\rightly-gpt-logo.png",
    "assets\rightly-gpt.ico",
    "src\gpt\patch.ps1",
    "src\gpt\codex-rtl-payload.js",
    "src\gpt\gpt-rtl-cdp.js",
    "src\gpt\launch-gpt.ps1",
    "src\gpt\Rightly.Gpt.Launcher.cs",
    "src\gpt\lib\Rightly.GptAsar.ps1",
    "src\gpt\lib\Rightly.GptLauncher.ps1",
    "src\claude\patch.ps1",
    "src\claude\claude-rtl-payload.js",
    "tests\verify-package.ps1"
)
foreach ($relative in $required) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $relative)) "Required file is missing: $relative"
}

$obsolete = @(
    "fix-autoupdate-online.ps1",
    "install.ps1",
    "install-online.ps1",
    "install.bat",
    "uninstall.ps1",
    "uninstall-online.ps1",
    "uninstall.bat",
    "run-repair.ps1",
    "patch.ps1",
    "launch-gpt.ps1",
    "gpt-rtl-cdp.js",
    "codex-rtl-payload.js",
    "install-online.sh",
    "patch.sh",
    "uninstall-online.sh",
    "status.bat",
    "claude\README.md",
    "claude\install-online.ps1",
    "claude\install.bat",
    "claude\status.bat",
    "claude\uninstall-online.ps1",
    "claude\uninstall.bat"
)
foreach ($relative in $obsolete) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relative))) "Obsolete entry point still exists: $relative"
}

$powerShellFiles = @(
    "installer\install.ps1",
    "installer\install-online.ps1",
    "installer\uninstall.ps1",
    "installer\uninstall-online.ps1",
    "installer\run-repair.ps1",
    "installer\lib\Rightly.Install.ps1",
    "tests\verify-package.ps1",
    "src\gpt\patch.ps1",
    "src\gpt\launch-gpt.ps1",
    "src\gpt\lib\Rightly.GptAsar.ps1",
    "src\gpt\lib\Rightly.GptLauncher.ps1",
    "src\claude\patch.ps1"
)
foreach ($relative in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $relative), [ref] $tokens, [ref] $errors
    )
    Assert-True (-not $errors) "$relative has PowerShell syntax errors: $errors"
}

$installer = Read-RepoFile "installer\install.ps1"
$onlineInstaller = Read-RepoFile "installer\install-online.ps1"
$installerModule = Read-RepoFile "installer\lib\Rightly.Install.ps1"
$uninstaller = Read-RepoFile "installer\uninstall.ps1"
$patcher = Read-RepoFile "src\gpt\patch.ps1"
$asarModule = Read-RepoFile "src\gpt\lib\Rightly.GptAsar.ps1"
$launcherModule = Read-RepoFile "src\gpt\lib\Rightly.GptLauncher.ps1"
$payload = Read-RepoFile "src\gpt\codex-rtl-payload.js"
$claudePatcher = Read-RepoFile "src\claude\patch.ps1"
$repair = Read-RepoFile "installer\run-repair.ps1"
$readme = Read-RepoFile "README.md"
$thirdParty = Read-RepoFile "docs\THIRD_PARTY_NOTICES.md"

# GPT prefers a persistent ASAR patch and falls back without modifying MSIX.
Assert-True ($patcher.Contains('architecture = "official-in-place-asar"')) "Persistent GPT architecture is missing"
Assert-True ($patcher.Contains('Remove-LegacyRuntime')) "Legacy GPT runtime cleanup is missing"
Assert-True ($patcher.Contains('Remove-LegacyCopiedApps')) "Legacy GPT copy cleanup is missing"
Assert-True (-not $patcher.Contains('architecture = "embedded-app-copy"')) "Active GPT patcher still identifies as a copy"
Assert-True ($patcher.Contains('Grant-AsarWriteAccess')) "GPT in-place installation is missing"
Assert-True ($patcher.Contains('Assert-AsarCanBeReplaced')) "GPT ASAR replacement preflight is missing"
Assert-True ($patcher.Contains('Copy-VerifiedAsar')) "GPT ASAR replacement verification is missing"
Assert-True ($patcher.Contains('The official GPT/Codex app is already closed.')) "Closed GPT process handling is missing"
Assert-True ($patcher.Contains('Stop-ProcessTree')) "Official Codex child process-tree cleanup is missing"
Assert-True ($patcher.Contains('Invoke-NativeUtility')) "Native utility exit handling is missing"
Assert-True ($patcher.Contains('take ownership of the official GPT resources folder')) "WindowsApps resources ACL preparation is missing"
Assert-True ($patcher.Contains('Copy-AsarWithBackupMode')) "Access-denied ASAR replacement has no backup-mode fallback"
Assert-True ($patcher.Contains('robocopy.exe')) "Windows backup-mode copy utility is missing"
Assert-True ($patcher.Contains('$exitCode -ge 8')) "Robocopy failure exit codes are not handled"
Assert-True (-not $patcher.Contains('Set-AsarByRename')) "The invalid WindowsApps rename fallback is still active"
Assert-True ($patcher.Contains('rollback backup failed SHA-256 verification')) "GPT rollback validation is missing"
Assert-True ($patcher.Contains('return $Official.Asar')) "GPT ASAR source is detached from app.asar.unpacked"
Assert-True (-not $patcher.Contains('return $backup')) "GPT still builds from the detached rollback backup"
Assert-True ($asarModule.Contains('@electron/asar')) "GPT ASAR tooling is missing"
Assert-True ($asarModule.Contains('webview\assets\app-main-*.js')) "GPT renderer discovery is missing"
Assert-True ($patcher.Contains('architecture = "loopback-cdp-runtime"')) "Protected-package runtime fallback is missing"
Assert-True ($patcher.Contains('Deploy-RightlyRuntimeFallback')) "Unsupported ASAR replacement does not deploy the runtime fallback"
Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot 'src\gpt\gpt-rtl-cdp.js')) "GPT runtime injector is missing"
Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot 'src\gpt\launch-gpt.ps1')) "GPT runtime launcher is missing"
Assert-True ($patcher.Contains('$Script:RuntimeLauncherExe')) "GPT runtime has no dedicated launcher executable"
Assert-True ($patcher.Contains('New-RightlyGptLauncher')) "GPT launcher executable is not built during fallback deployment"
Assert-True ($patcher.Contains('New-RightlyGptShortcuts')) "GPT runtime does not create its native-launcher shortcuts"
Assert-True ($launcherModule.Contains('$shortcut.TargetPath = $LauncherPath')) "Rightly GPT shortcut still targets PowerShell"
Assert-True ($launcherModule.Contains('$shortcut.IconLocation = "$IconPath,0"')) "Rightly GPT shortcuts do not use the distinct icon file"
Assert-True ($launcherModule.Contains('User Pinned\TaskBar')) "Existing Rightly GPT taskbar pins are not refreshed"
Assert-True ($patcher.Contains('assets\rightly-gpt.ico')) "GPT launcher does not use its distinct Rightly GPT icon"
$runtimeLauncher = Read-RepoFile "src\gpt\launch-gpt.ps1"
$runtimeInjector = Read-RepoFile "src\gpt\gpt-rtl-cdp.js"
$nativeLauncher = Read-RepoFile "src\gpt\Rightly.Gpt.Launcher.cs"
Assert-True ($runtimeLauncher.Contains('Test-RunningRightlyPayload')) "GPT launcher does not verify an already-running instance"
Assert-True ($runtimeLauncher.Contains('already open with a verified Rightly payload; leaving it running')) "Verified GPT instances are not preserved"
Assert-True ($runtimeLauncher.Contains('open without a verified Rightly payload; restarting it')) "Uncorrected GPT instances are not restarted"
Assert-True ($runtimeInjector.Contains('verifyRunningInstance')) "GPT injector has no read-only running-instance verifier"
Assert-True ($runtimeInjector.Contains('hasRightlyMarker')) "GPT verifier does not inspect the renderer marker"
Assert-True ($nativeLauncher.Contains('MutexName')) "Rightly GPT has no Windows single-instance lock"
Assert-True ($nativeLauncher.Contains('Rightly GPT is already starting')) "A duplicate launch has no clear user message"
Assert-True ($nativeLauncher.Contains('class StatusWindow')) "Rightly GPT has no branded startup status window"
Assert-True ($nativeLauncher.Contains('BackgroundWorker')) "The launcher GUI can block while GPT starts"
Assert-True ($runtimeLauncher.Contains('Set-RightlyStatus')) "The GPT runtime does not publish startup progress"
Assert-True ($runtimeLauncher.Contains('if (-not $StatusFile) { Show-RightlyError')) "GUI launches can show duplicate error dialogs"
Assert-True ($runtimeLauncher.Contains('SW_RESTORE = 9')) "A minimized corrected GPT window is not explicitly restored"
Assert-True ($runtimeLauncher.Contains('SetForegroundWindow')) "An existing corrected GPT window is not brought forward"
Assert-True ($runtimeLauncher.Contains('RightlyWindowActivation]::Restore')) "The native window-restoration helper is unused"
Assert-True ($runtimeLauncher.Contains('Rightly is active in the background. Opening a new GPT window.')) "Background-only GPT has no window-opening status"
Assert-True ($runtimeLauncher.Contains('Start-PackagedCodex -AppUserModelId $Official.AppUserModelId -Arguments ""')) "Background-only GPT is not reactivated through its official package identity"
Assert-True ($runtimeLauncher.Contains('without restarting or reinjecting it')) "Background-window activation intent is undocumented in code"
Assert-True ($runtimeLauncher.Contains('Test-RunningRightlyHost')) "Tray-only GPT cannot be identified as a Rightly-managed host"
Assert-True ($runtimeLauncher.Contains('Test-OfficialCodexHasVisibleWindow')) "Tray-only GPT cannot be distinguished from a visible window"
Assert-True ($runtimeLauncher.Contains('preserving the process')) "Tray-only Rightly GPT is not explicitly preserved"
Assert-True ($runtimeLauncher.Contains('Start-Injector $port')) "A newly created background GPT window cannot receive the Rightly payload"
Assert-True ($runtimeLauncher.Contains('original PID preserved')) "Same-process background activation is not verified in the runtime flow"

# Renderer rules cover mixed RTL text while preserving app chrome and code.
Assert-True ($payload.Contains('hasHebrew')) "Hebrew-anywhere detection is missing"
Assert-True ($payload.Contains('APP_CHROME_SEL')) "Application chrome exclusion is missing"
Assert-True ($payload.Contains('processTables')) "RTL table processing is missing"
Assert-True ($payload.Contains('list-style-position:outside!important')) "RTL list styling is missing"
Assert-True ($payload.Contains('requestIdleCallback')) "Long-chat work is not idle-scheduled"
Assert-True ($payload.Contains('PROCESS_BATCH_SIZE = 3')) "Long-chat processing is not bounded"
Assert-True ($payload.Contains('normalizeSidebarTitleText')) "Mixed Hebrew sidebar title handling is missing"

# One shared module owns the interactive menu, repair bundle, and branded icon.
Assert-True ($installer.Contains('lib\Rightly.Install.ps1')) "Installer does not load the shared module"
Assert-True ($installerModule.Contains('ValidateSet("install", "repair", "uninstall")')) "Interactive operations are incomplete"
Assert-True ($installerModule.Contains('assets\rightly.ico')) "Repair bundle does not include the Rightly icon"
Assert-True ($installerModule.Contains('installer\install-online.ps1')) "Repair bundle does not include its online bootstrap"
Assert-True ($installerModule.Contains('$shortcut.IconLocation = "$icon,0"')) "Repair shortcut does not use the Rightly icon"
Assert-True ($installerModule.Contains('"Repair RTL.lnk"')) "Interactive repair shortcut is missing"
Assert-True ($installerModule.Contains('-Target Prompt')) "Repair shortcut does not open the target menu"
Assert-True (-not $installerModule.Contains('@("Codex.lnk"')) "Installer must not delete the official Codex shortcut by name"
Assert-True ($repair.Contains('& $onlineInstaller -Repo "NoamHermos/rightly" -Branch "main" -Target $Target -RepairMode')) "Repair runner does not fetch main or forward its target"
Assert-True ($onlineInstaller.Contains('[switch] $RepairMode')) "Online installer does not accept repair mode"
Assert-True ($onlineInstaller.Contains('$installerArguments += "-RepairMode"')) "Online installer does not forward repair mode"
Assert-True ($repair.Contains('Start-Transcript')) "Repair failures are not logged"
Assert-True ($repair.Contains('if ($transcribing)')) "Repair logging does not close the transcript before appending a fatal line"
Assert-True ($repair.Contains('Show-RightlySuccess')) "Repair does not end with a clear success result"
Assert-True ($installer.Contains('-IsolateApplicationOutput')) "Claude output can appear after the repair result"
Assert-True ($installerModule.Contains('$launcherExitCode = $LASTEXITCODE')) "Isolated Claude launch does not preserve its real exit code"
Assert-True ($uninstaller.Contains('Select-RightlyTarget -Operation "uninstall"')) "Unified uninstall menu is missing"

# Claude stays in-place, verifies the pinned engine, and removes legacy watchers.
Assert-True ($claudePatcher.Contains('$Script:UpstreamCommit')) "Pinned Claude revision is missing"
Assert-True ($claudePatcher.Contains('$Script:UpstreamSha256')) "Pinned Claude SHA-256 is missing"
Assert-True ($claudePatcher.Contains('Remove-AutomaticPatching')) "Legacy Claude watcher cleanup is missing"
Assert-True ($claudePatcher.Contains('Remove-LegacyCopy')) "Legacy Claude copy cleanup is missing"
Assert-True (-not $claudePatcher.Contains('Register-ScheduledTask')) "Claude must not register background repair"
Assert-True ($claudePatcher.Contains('--no-deprecation')) "Claude deprecation warning suppression is missing"
Assert-True (-not $claudePatcher.Contains('NODE_NO_WARNINGS')) "Claude patcher must not suppress every Node warning"
Assert-True (-not $patcher.Contains('NODE_NO_WARNINGS')) "GPT patcher must not suppress Node warnings"
Assert-True ((Read-RepoFile "src\claude\claude-rtl-payload.js").Contains('processInteractiveQuestions')) "Claude question panels are not processed"

# Brand assets are valid PNG/ICO files, not placeholders.
$png = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "assets\rightly-logo.png"))
$ico = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "assets\rightly.ico"))
$gptPng = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "assets\rightly-gpt-logo.png"))
$gptIco = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "assets\rightly-gpt.ico"))
Assert-True ($png.Length -gt 10000 -and $png[0] -eq 0x89 -and $png[1] -eq 0x50) "Rightly PNG asset is invalid"
Assert-True ($ico.Length -gt 10000 -and $ico[0] -eq 0 -and $ico[1] -eq 0 -and $ico[2] -eq 1) "Rightly ICO asset is invalid"
Assert-True ($gptPng.Length -gt 10000 -and $gptPng[0] -eq 0x89 -and $gptPng[1] -eq 0x50) "Rightly GPT PNG asset is invalid"
Assert-True ($gptIco.Length -gt 10000 -and $gptIco[0] -eq 0 -and $gptIco[1] -eq 0 -and $gptIco[2] -eq 1) "Rightly GPT ICO asset is invalid"

# The standalone repository contains only the current implementation.
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot "OLD"))) "Legacy copied-app archive must not ship in the standalone repository"
$docImages = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "docs") -File -Recurse | Where-Object Extension -Match '^\.(png|jpe?g|gif|webp)$')
Assert-True ($docImages.Count -eq 0) "Borrowed documentation images must not ship in the standalone repository"
Assert-True (-not $installerModule.Contains('OLD\')) "The active repair bundle references OLD"
$allowedRootFiles = @(".gitattributes", ".gitignore", "LICENSE", "README.md")
$unexpectedRootFiles = @(Get-ChildItem -LiteralPath $repoRoot -File -Force | Where-Object Name -NotIn $allowedRootFiles)
Assert-True ($unexpectedRootFiles.Count -eq 0) "Unexpected loose files remain at the repository root: $($unexpectedRootFiles.Name -join ', ')"

# Public documentation matches the current Windows architecture.
Assert-True ($readme.Contains('NoamHermos/rightly/main/installer/install-online.ps1')) "README installer URL is wrong"
Assert-True ($readme.Contains('## How it works')) "README architecture summary is missing"
Assert-True ($readme.Contains('No scheduled task')) "README does not state that background repair is disabled"
Assert-True ($readme.Contains('Repair RTL')) "README does not explain the repair shortcut"
Assert-True ($readme.Contains('persistent in-place ASAR patch')) "README does not explain persistent GPT support"
Assert-True ($thirdParty.Contains('Copyright (c) 2026 RT-AI')) "Original MIT attribution is missing"
Assert-True ($thirdParty.Contains('Copyright (c) 2026 shraga100')) "Pinned Claude engine attribution is missing"
Assert-True ($readme -notmatch '[\u0590-\u05FF\uFB1D-\uFB4F]') "README must be entirely English"
Assert-True ($readme -notmatch '(?m)!\[') "README must not embed Markdown images"
Assert-True ($readme -notmatch '(?i)<img\b') "README must not embed HTML images"
Assert-True ($readme.Contains('| --- | --- |')) "README project table is missing"

& node.exe (Join-Path $PSScriptRoot "direction.test.js")
Assert-True ($LASTEXITCODE -eq 0) "GPT direction behavior tests failed"
& node.exe (Join-Path $PSScriptRoot "claude-direction.test.js")
Assert-True ($LASTEXITCODE -eq 0) "Claude direction behavior tests failed"
& node.exe --check (Join-Path $repoRoot "src\gpt\gpt-rtl-cdp.js")
Assert-True ($LASTEXITCODE -eq 0) "GPT runtime injector has JavaScript syntax errors"

Write-Host "Rightly static verification passed." -ForegroundColor Green
