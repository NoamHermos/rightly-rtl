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
    "SECURITY.md",
    "THIRD_PARTY_NOTICES.md",
    "LICENSE",
    "install.ps1",
    "install-online.ps1",
    "install.bat",
    "uninstall.ps1",
    "uninstall-online.ps1",
    "uninstall.bat",
    "run-repair.ps1",
    "scripts\Rightly.Install.ps1",
    "assets\rightly-logo.png",
    "assets\rightly.ico",
    "patch.ps1",
    "launch-gpt.ps1",
    "gpt-rtl-cdp.js",
    "codex-rtl-payload.js",
    "claude\patch.ps1",
    "claude\claude-rtl-payload.js"
)
foreach ($relative in $required) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $relative)) "Required file is missing: $relative"
}

$obsolete = @(
    "fix-autoupdate-online.ps1",
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
    "install.ps1",
    "install-online.ps1",
    "uninstall.ps1",
    "uninstall-online.ps1",
    "run-repair.ps1",
    "scripts\Rightly.Install.ps1",
    "patch.ps1",
    "launch-gpt.ps1",
    "claude\patch.ps1"
)
foreach ($relative in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $relative), [ref] $tokens, [ref] $errors
    )
    Assert-True (-not $errors) "$relative has PowerShell syntax errors: $errors"
}

$installer = Read-RepoFile "install.ps1"
$installerModule = Read-RepoFile "scripts\Rightly.Install.ps1"
$uninstaller = Read-RepoFile "uninstall.ps1"
$patcher = Read-RepoFile "patch.ps1"
$launcher = Read-RepoFile "launch-gpt.ps1"
$injector = Read-RepoFile "gpt-rtl-cdp.js"
$payload = Read-RepoFile "codex-rtl-payload.js"
$claudePatcher = Read-RepoFile "claude\patch.ps1"
$repair = Read-RepoFile "run-repair.ps1"
$readme = Read-RepoFile "README.md"
$thirdParty = Read-RepoFile "THIRD_PARTY_NOTICES.md"

# GPT uses the official app and a bounded, loopback-only startup injector.
Assert-True ($patcher.Contains('architecture = "loopback-cdp-runtime"')) "Active GPT runtime architecture is missing"
Assert-True ($patcher.Contains('Remove-LegacyAutomaticPatching')) "Legacy GPT task cleanup is missing"
Assert-True ($patcher.Contains('Remove-LegacyCopiedApps')) "Legacy GPT copy cleanup is missing"
Assert-True (-not $patcher.Contains('architecture = "embedded-app-copy"')) "Active GPT patcher still identifies as a copy"
Assert-True ($launcher.Contains('--remote-debugging-address=127.0.0.1')) "GPT DevTools is not loopback-only"
Assert-True ($launcher.Contains('"--injection-window-ms", "20000"')) "GPT injector lifetime is not bounded"
Assert-True ($injector.Contains('Runtime.evaluate')) "GPT payload injection is missing"
Assert-True (-not $injector.Contains('setInterval')) "GPT injector must not poll forever"

# Renderer rules cover mixed RTL text while preserving app chrome and code.
Assert-True ($payload.Contains('hasHebrew')) "Hebrew-anywhere detection is missing"
Assert-True ($payload.Contains('APP_CHROME_SEL')) "Application chrome exclusion is missing"
Assert-True ($payload.Contains('processTables')) "RTL table processing is missing"
Assert-True ($payload.Contains('list-style-position:outside!important')) "RTL list styling is missing"
Assert-True ($payload.Contains('requestIdleCallback')) "Long-chat work is not idle-scheduled"
Assert-True ($payload.Contains('PROCESS_BATCH_SIZE = 3')) "Long-chat processing is not bounded"
Assert-True ($payload.Contains('normalizeSidebarTitleText')) "Mixed Hebrew sidebar title handling is missing"

# One shared module owns the interactive menu, repair bundle, and branded icon.
Assert-True ($installer.Contains('scripts\Rightly.Install.ps1')) "Installer does not load the shared module"
Assert-True ($installerModule.Contains('ValidateSet("install", "repair", "uninstall")')) "Interactive operations are incomplete"
Assert-True ($installerModule.Contains('assets\rightly.ico')) "Repair bundle does not include the Rightly icon"
Assert-True ($installerModule.Contains('$shortcut.IconLocation = "$icon,0"')) "Repair shortcut does not use the Rightly icon"
Assert-True ($installerModule.Contains('"Repair RTL.lnk"')) "Interactive repair shortcut is missing"
Assert-True ($installerModule.Contains('-Target Prompt')) "Repair shortcut does not open the target menu"
Assert-True (-not $installerModule.Contains('@("Codex.lnk"')) "Installer must not delete the official Codex shortcut by name"
Assert-True ($repair.Contains('& $installer -Target $Target -RepairMode')) "Repair runner does not forward its target"
Assert-True ($repair.Contains('Start-Transcript')) "Repair failures are not logged"
Assert-True ($uninstaller.Contains('Select-RightlyTarget -Operation "uninstall"')) "Unified uninstall menu is missing"

# Claude stays in-place, verifies the pinned engine, and removes legacy watchers.
Assert-True ($claudePatcher.Contains('$Script:UpstreamCommit')) "Pinned Claude revision is missing"
Assert-True ($claudePatcher.Contains('$Script:UpstreamSha256')) "Pinned Claude SHA-256 is missing"
Assert-True ($claudePatcher.Contains('Remove-AutomaticPatching')) "Legacy Claude watcher cleanup is missing"
Assert-True ($claudePatcher.Contains('Remove-LegacyCopy')) "Legacy Claude copy cleanup is missing"
Assert-True (-not $claudePatcher.Contains('Register-ScheduledTask')) "Claude must not register background repair"

# Brand assets are valid PNG/ICO files, not placeholders.
$png = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "assets\rightly-logo.png"))
$ico = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "assets\rightly.ico"))
Assert-True ($png.Length -gt 10000 -and $png[0] -eq 0x89 -and $png[1] -eq 0x50) "Rightly PNG asset is invalid"
Assert-True ($ico.Length -gt 10000 -and $ico[0] -eq 0 -and $ico[1] -eq 0 -and $ico[2] -eq 1) "Rightly ICO asset is invalid"

# The standalone repository contains only the current implementation.
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot "OLD"))) "Legacy copied-app archive must not ship in the standalone repository"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot "docs"))) "Borrowed documentation images must not ship in the standalone repository"
Assert-True (-not $installerModule.Contains('OLD\')) "The active repair bundle references OLD"

# Public documentation matches the current Windows architecture.
Assert-True ($readme.Contains('NoamHermos/rightly-rtl/main/install-online.ps1')) "README installer URL is wrong"
Assert-True ($readme.Contains('## How it works')) "README architecture summary is missing"
Assert-True ($readme.Contains('No scheduled task')) "README does not state that background repair is disabled"
Assert-True ($readme.Contains('Repair RTL')) "README does not explain the repair shortcut"
Assert-True ($thirdParty.Contains('Copyright (c) 2026 shraga100')) "Pinned Claude engine attribution is missing"
Assert-True ($readme -notmatch '[\u0590-\u05FF\uFB1D-\uFB4F]') "README must be entirely English"
Assert-True ($readme -notmatch '(?m)!\[') "README must not embed Markdown images"
Assert-True ($readme -notmatch '(?i)<img\b') "README must not embed HTML images"
Assert-True ($readme.Contains('| --- | --- |')) "README project table is missing"

& node.exe (Join-Path $PSScriptRoot "direction.test.js")
Assert-True ($LASTEXITCODE -eq 0) "GPT direction behavior tests failed"
& node.exe (Join-Path $PSScriptRoot "claude-direction.test.js")
Assert-True ($LASTEXITCODE -eq 0) "Claude direction behavior tests failed"

Write-Host "Rightly static verification passed." -ForegroundColor Green
