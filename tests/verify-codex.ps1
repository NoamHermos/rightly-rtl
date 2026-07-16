[CmdletBinding()]
param([switch] $SkipInstalledBuild)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$paths = @{
    Patcher = Join-Path $repoRoot "src\gpt\patch.ps1"
    Payload = Join-Path $repoRoot "src\gpt\codex-rtl-payload.js"
    AsarModule = Join-Path $repoRoot "src\gpt\lib\Rightly.GptAsar.ps1"
    Installer = Join-Path $repoRoot "installer\install.ps1"
    InstallerModule = Join-Path $repoRoot "installer\lib\Rightly.Install.ps1"
    Repair = Join-Path $repoRoot "installer\run-repair.ps1"
}

foreach ($path in $paths.Values) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required GPT file is missing: $path"
}
foreach ($path in @($paths.Patcher, $paths.AsarModule, $paths.Installer, $paths.InstallerModule, $paths.Repair)) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    Assert-True (-not $errors) "$path has PowerShell syntax errors: $errors"
}

$patcher = Get-Content -LiteralPath $paths.Patcher -Raw
$payload = Get-Content -LiteralPath $paths.Payload -Raw
$asarModule = Get-Content -LiteralPath $paths.AsarModule -Raw
$installer = Get-Content -LiteralPath $paths.Installer -Raw
$installerModule = Get-Content -LiteralPath $paths.InstallerModule -Raw
$repair = Get-Content -LiteralPath $paths.Repair -Raw

# GPT is modified in place with a version-bound, hash-verified rollback backup.
Assert-True ($patcher.Contains('Get-AppxPackage -Name "OpenAI.Codex"')) "Official GPT package discovery is missing"
Assert-True ($patcher.Contains('architecture = "official-in-place-asar"')) "Persistent GPT architecture is missing"
Assert-True ($patcher.Contains('New-RightlyGptAsar')) "Shared ASAR builder is not used"
Assert-True ($patcher.Contains('Grant-AsarWriteAccess')) "Official ASAR write preparation is missing"
Assert-True ($patcher.Contains('originalHash')) "Original ASAR hash metadata is missing"
Assert-True ($patcher.Contains('patchedHash')) "Patched ASAR hash metadata is missing"
Assert-True ($patcher.Contains('rollback backup failed SHA-256 verification')) "Rollback hash validation is missing"
Assert-True ($patcher.Contains('return $Official.Asar')) "GPT builds must use the official ASAR beside app.asar.unpacked"
Assert-True (-not $patcher.Contains('return $backup')) "GPT must not build from the detached rollback ASAR"
Assert-True ($patcher.Contains('Copy-VerifiedAsar -Source $Script:BackupPath')) "Failed installs do not restore the managed backup"
Assert-True ($patcher.Contains('Assert-AsarCanBeReplaced')) "GPT ASAR replacement preflight is missing"
Assert-True ($patcher.Contains('The official GPT/Codex app is already closed.')) "An already-closed GPT app is not handled as success"
Assert-True ($patcher.Contains('Stop-ProcessTree')) "Official Codex child process trees are not force-closed"
Assert-True ($patcher.Contains('Invoke-NativeUtility')) "Native process failures are not handled by exit code"
Assert-True ($patcher.Contains('AddSeconds(10)')) "GPT ASAR handle-release polling is missing"
Assert-True ($patcher.Contains('take ownership of the official GPT resources folder')) "WindowsApps parent permissions are not prepared"
Assert-True ($patcher.Contains('WindowsIdentity]::GetCurrent().User.Value')) "The elevated repair user is not granted explicit ASAR access"
Assert-True ($patcher.Contains('"-R", "-S", "-H"')) "The read-only WindowsApps ASAR attribute is not cleared before writing"
Assert-True ($patcher.Contains('Set-AsarByRename')) "Access-denied ASAR replacement has no rename fallback"
Assert-True ($patcher.Contains('return "Rename"')) "The replacement preflight does not distinguish permission state from a live lock"
Assert-True ($patcher.Contains('Remove-LegacyRuntime')) "Legacy runtime cleanup is missing"
Assert-True ($patcher.Contains('Remove-LegacyModificationPackage')) "Legacy overlay cleanup is missing"
Assert-True ($patcher.Contains('Remove-LegacyCopiedApps')) "Legacy copied-app cleanup is missing"
Assert-True (-not $patcher.Contains('Register-ScheduledTask')) "GPT must not install automatic background repair"
Assert-True (-not $patcher.Contains('--remote-debugging')) "The old DevTools runtime leaked into the persistent patcher"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'src\gpt\gpt-rtl-cdp.js'))) "Obsolete GPT injector still ships"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'src\gpt\launch-gpt.ps1'))) "Obsolete GPT launcher still ships"

Assert-True ($asarModule.Contains('@electron/asar')) "Electron ASAR tooling is missing"
Assert-True ($asarModule.Contains('webview\assets\app-main-*.js')) "GPT renderer entry discovery is missing"
Assert-True ($asarModule.Contains('The source ASAR already contains a Rightly marker')) "Double-patch protection is missing"
Assert-True ($asarModule.Contains('50MB')) "Truncated ASAR protection is missing"

# Renderer rules cover mixed RTL text while preserving app chrome and code.
Assert-True ($payload.Contains('RT-AI CODEX RTL PATCH START')) "RTL payload marker is missing"
Assert-True ($payload.Contains('__RT_AI_CODEX_RTL_PATCH__')) "RTL payload is not idempotent"
Assert-True ($payload.Contains('requestIdleCallback')) "Long-chat work is not deferred"
Assert-True ($payload.Contains('PROCESS_BATCH_SIZE = 3')) "Long-chat processing is not bounded"
Assert-True ($payload.Contains('enqueueWorkInSubtree')) "Mutations still trigger broad page rescans"
Assert-True ($payload.Contains('processTables')) "RTL table handling is missing"
Assert-True ($payload.Contains('list-style-position:outside!important')) "RTL list handling is missing"
Assert-True ($payload.Contains('aside [data-thread-title=\"true\"]')) "Sidebar title targeting is missing"
Assert-True ($payload.Contains('SIDEBAR_RTL_MARK = "\u200f"')) "Invisible RTL sidebar mark is missing"
Assert-True ($payload.Contains('el.style.textAlign = "left"')) "Sidebar titles are not kept left-aligned"

# The repair bundle carries only the persistent implementation.
Assert-True ($installer.Contains('lib\Rightly.Install.ps1')) "Installer does not load the shared module"
Assert-True ($installerModule.Contains('"src\gpt\lib\Rightly.GptAsar.ps1"')) "Repair bundle omits the ASAR helper"
Assert-True (([regex]::Matches($installerModule, 'src\\gpt\\gpt-rtl-cdp\.js')).Count -eq 1) "Old injector should appear only in cleanup"
Assert-True (([regex]::Matches($installerModule, 'src\\gpt\\launch-gpt\.ps1')).Count -eq 1) "Old launcher should appear only in cleanup"
Assert-True ($installerModule.Contains('"assets\rightly.ico"')) "Repair bundle omits the Rightly icon"
Assert-True ($installerModule.Contains('"Repair RTL.lnk"')) "Interactive repair shortcut is missing"
Assert-True ($repair.Contains('persistent ASAR patch and rollback metadata were verified')) "Repair success text is stale"

if (-not $SkipInstalledBuild) {
    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    Assert-True ($null -ne $package) "The official GPT Work / Codex package is not installed"
    Assert-True ($package.Status -eq "Ok") "The official GPT Work / Codex package is not healthy"

    $asarPath = Join-Path $package.InstallLocation "app\resources\app.asar"
    $statePath = Join-Path $env:ProgramData "Rightly\GPT\state.json"
    Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) "Persistent GPT state is not installed"
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-True ($state.architecture -eq "official-in-place-asar") "Installed GPT state describes the wrong architecture"
    Assert-True ($state.packageFullName -eq $package.PackageFullName) "Installed GPT state belongs to another package version"
    Assert-True (Test-Path -LiteralPath $state.backupPath -PathType Leaf) "GPT rollback backup is missing"
    $originalHash = (Get-FileHash -LiteralPath $state.backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installedHash = (Get-FileHash -LiteralPath $asarPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($originalHash -eq $state.originalHash) "GPT rollback backup hash does not match state"
    Assert-True ($installedHash -eq $state.patchedHash) "Official GPT ASAR is not the verified Rightly build"
    Assert-True ($installedHash -ne $originalHash) "Official and rollback ASAR hashes must differ"

    $automaticTask = Get-ScheduledTask -TaskName "Codex RT-AI RTL Auto-Update" -ErrorAction SilentlyContinue
    Assert-True (-not $automaticTask) "A legacy automatic GPT RTL task is still installed"
    Write-Host "Installed persistent GPT patch verified." -ForegroundColor Green
}

Write-Host "Rightly persistent GPT verification passed." -ForegroundColor Green
