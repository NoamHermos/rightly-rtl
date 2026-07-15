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
    Injector = Join-Path $repoRoot "src\gpt\gpt-rtl-cdp.js"
    Launcher = Join-Path $repoRoot "src\gpt\launch-gpt.ps1"
    Installer = Join-Path $repoRoot "installer\install.ps1"
    InstallerModule = Join-Path $repoRoot "installer\lib\Rightly.Install.ps1"
    Repair = Join-Path $repoRoot "installer\run-repair.ps1"
}

foreach ($path in $paths.Values) {
    Assert-True (Test-Path -LiteralPath $path) "Required GPT file is missing: $path"
}
foreach ($path in @($paths.Patcher, $paths.Launcher, $paths.Installer, $paths.InstallerModule, $paths.Repair)) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    Assert-True (-not $errors) "$path has PowerShell syntax errors: $errors"
}

$patcher = Get-Content -LiteralPath $paths.Patcher -Raw
$payload = Get-Content -LiteralPath $paths.Payload -Raw
$injector = Get-Content -LiteralPath $paths.Injector -Raw
$launcher = Get-Content -LiteralPath $paths.Launcher -Raw
$installer = Get-Content -LiteralPath $paths.Installer -Raw
$installerModule = Get-Content -LiteralPath $paths.InstallerModule -Raw

# The active Windows implementation opens the official app and injects only in memory.
Assert-True ($patcher.Contains('Get-AppxPackage -Name "OpenAI.Codex"')) "Official GPT package discovery is missing"
Assert-True ($patcher.Contains('architecture = "loopback-cdp-runtime"')) "The active GPT architecture is not the official-app runtime"
Assert-True ($patcher.Contains('Deploy-RightlyRuntime')) "Runtime deployment is missing"
Assert-True ($patcher.Contains('gpt-rtl-cdp.js')) "Runtime injector is not deployed"
Assert-True ($patcher.Contains('launch-gpt.ps1')) "Official-app launcher is not deployed"
Assert-True ($patcher.Contains('Remove-LegacyModificationPackage')) "Legacy modification cleanup is missing"
Assert-True ($patcher.Contains('Remove-LegacyCopiedApps')) "Legacy copied-app cleanup is missing"
Assert-True ($patcher.Contains('Programs\Rightly-GPT-Embedded')) "Embedded comparison copy cleanup is missing"
Assert-True ($patcher.Contains('User Pinned\TaskBar')) "Pinned copied-app shortcut cleanup is missing"
Assert-True (-not $patcher.Contains('architecture = "embedded-app-copy"')) "The archived copy architecture leaked into the active patcher"
Assert-True (-not $patcher.Contains('Copy-AppTree')) "The active GPT patcher must not copy the application"
Assert-True (-not $patcher.Contains('@electron/fuses')) "The active GPT patcher must not modify the official executable"
Assert-True (-not $patcher.Contains('Register-ScheduledTask')) "GPT must not install automatic background repair"

Assert-True ($injector.Contains('http://127.0.0.1:')) "The injector is not restricted to the local endpoint"
Assert-True ($injector.Contains('/json/list')) "Page-specific target discovery is missing"
Assert-True ($injector.Contains('target.webSocketDebuggerUrl')) "Page-specific WebSocket attachment is missing"
Assert-True ($injector.Contains('Page.addScriptToEvaluateOnNewDocument')) "New renderer injection is missing"
Assert-True ($injector.Contains('Runtime.evaluate')) "Existing renderer injection is missing"
Assert-True ($injector.Contains('Injected and verified Rightly payload')) "Payload verification is missing"
Assert-True ($injector.Contains('Startup injection window completed')) "The injector does not disconnect after startup"
Assert-True (-not $injector.Contains('Target.setAutoAttach')) "Broken browser-session auto-attach is still present"
Assert-True (-not $injector.Contains('setInterval')) "The injector must not poll forever"

Assert-True ($launcher.Contains('--remote-debugging-address=127.0.0.1')) "Chromium debugging is not loopback-only"
Assert-True ($launcher.Contains('--force-ui-direction=ltr')) "Native application chrome must remain LTR"
Assert-True ($launcher.Contains('"--injection-window-ms", "20000"')) "Startup injection window is not bounded"
Assert-True ($launcher.Contains('Stop-StaleRightlyInjectors')) "Stale injector cleanup is missing"
Assert-True ($launcher.Contains('Stop-LegacyCopiedCodex')) "Official launcher does not close copied GPT builds"

Assert-True ($payload.Contains('RT-AI CODEX RTL PATCH START')) "RTL payload marker is missing"
Assert-True ($payload.Contains('__RT_AI_CODEX_RTL_PATCH__')) "RTL payload is not idempotent"
Assert-True ($payload.Contains('requestIdleCallback')) "Long-chat work is not deferred"
Assert-True ($payload.Contains('PROCESS_BATCH_SIZE = 3')) "Long-chat processing is not bounded"
Assert-True ($payload.Contains('enqueueWorkInSubtree')) "Mutations still trigger broad page rescans"
Assert-True ($payload.Contains('processTables')) "RTL table handling is missing"
Assert-True ($payload.Contains('list-style-position:outside!important')) "RTL list marker handling is missing"
Assert-True ($payload.Contains('aside [data-thread-title=\"true\"]')) "Sidebar task title targeting is missing"
Assert-True ($payload.Contains('SIDEBAR_RTL_MARK = "\u200f"')) "Invisible RTL mark for mixed sidebar titles is missing"
Assert-True ($payload.Contains('el.style.textAlign = "left"')) "Sidebar titles are not kept left-aligned"

# The standalone repository contains only the official-app runtime.
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot "OLD"))) "The copied-app archive must not ship in the standalone repository"
Assert-True (-not $installerModule.Contains('OLD\')) "The main installer must never deploy or run OLD"
Assert-True ($installer.Contains('lib\Rightly.Install.ps1')) "Installer does not load the shared module"
Assert-True ($installerModule.Contains('"src\gpt\gpt-rtl-cdp.js"')) "Repair bundle omits the active injector"
Assert-True ($installerModule.Contains('"src\gpt\launch-gpt.ps1"')) "Repair bundle omits the active launcher"
Assert-True ($installerModule.Contains('"assets\rightly.ico"')) "Repair bundle omits the Rightly icon"
Assert-True ($installerModule.Contains('"Repair RTL.lnk"')) "The interactive repair shortcut is missing"
Assert-True ($installerModule.Contains('-Target Prompt')) "The repair shortcut does not prompt for GPT, Claude, or both"
Assert-True ($installerModule.Contains('$shortcut.IconLocation = "$icon,0"')) "The repair shortcut does not use the branded icon"

if (-not $SkipInstalledBuild) {
    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    Assert-True ($null -ne $package) "The official GPT Work / Codex package is not installed"
    Assert-True ($package.Status -eq "Ok") "The official GPT Work / Codex package is not healthy"

    $runtimeDir = Join-Path $env:LOCALAPPDATA "Programs\Rightly\GPT"
    $statePath = Join-Path $runtimeDir "state.json"
    Assert-True (Test-Path -LiteralPath $statePath) "The official-app Rightly runtime is not installed"
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-True ($state.architecture -eq "loopback-cdp-runtime") "Installed GPT state describes the wrong architecture"
    foreach ($name in @("codex-rtl-payload.js", "gpt-rtl-cdp.js", "launch-gpt.ps1")) {
        Assert-True (Test-Path -LiteralPath (Join-Path $runtimeDir $name)) "Installed runtime file is missing: $name"
    }

    $automaticTask = Get-ScheduledTask -TaskName "Codex RT-AI RTL Auto-Update" -ErrorAction SilentlyContinue
    Assert-True (-not $automaticTask) "A legacy automatic GPT RTL task is still installed"
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Repair RTL.lnk"
    if (Test-Path -LiteralPath $shortcutPath) {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
        Assert-True ($shortcut.IconLocation -match '(?i)Rightly[\\/]Repair[\\/]assets[\\/]rightly\.ico,0$') "Installed repair shortcut uses the wrong icon"
    }
    Write-Host "Installed official-app GPT runtime verified." -ForegroundColor Green
}

Write-Host "Rightly GPT official-app runtime verification passed." -ForegroundColor Green
