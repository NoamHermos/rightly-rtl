[CmdletBinding()]
param([switch] $SkipInstalledBuild)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repoRoot "claude"
$patcherPath = Join-Path $moduleRoot "patch.ps1"
$payloadPath = Join-Path $moduleRoot "claude-rtl-payload.js"
$readmePath = Join-Path $repoRoot "README.md"
$installOnlinePath = Join-Path $repoRoot "install-online.ps1"
$uninstallOnlinePath = Join-Path $repoRoot "uninstall-online.ps1"

foreach ($path in @($patcherPath, $payloadPath, $readmePath, $installOnlinePath, $uninstallOnlinePath)) {
    Assert-True (Test-Path -LiteralPath $path) "Missing Claude module file: $path"
}

foreach ($path in @($patcherPath, $installOnlinePath, $uninstallOnlinePath)) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    Assert-True (-not $errors) "$path has PowerShell syntax errors"
}

$patcher = Get-Content -LiteralPath $patcherPath -Raw
$payload = Get-Content -LiteralPath $payloadPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw
$installOnline = Get-Content -LiteralPath $installOnlinePath -Raw

Assert-True ($patcher.Contains('Get-AppxPackage -Name "Claude"')) "Official Claude package discovery is missing"
Assert-True ($patcher.Contains('$Script:UpstreamCommit')) "Pinned in-place engine revision is missing"
Assert-True ($patcher.Contains('$Script:UpstreamSha256')) "Pinned in-place engine SHA-256 is missing"
Assert-True ($patcher.Contains('The pinned upstream patch failed SHA-256 verification')) "Upstream verification failure is not enforced"
Assert-True ($patcher.Contains('$RTL_INJECTION_CODE = @''')) "Upstream renderer payload replacement is missing"
Assert-True ($patcher.Contains('Install-Patch')) "Non-interactive in-place installation is missing"
Assert-True ($patcher.Contains('Restore-Patch')) "Official backup restoration is missing"
Assert-True ($patcher.Contains('Start-OfficialClaude')) "Official Claude launcher is missing"
Assert-True ($patcher.Contains('RtAiClaudeActivation')) "MSIX activation manager is missing"
Assert-True ($patcher.Contains('--force-ui-direction=ltr')) "Official Claude launcher must keep window controls LTR"
Assert-True ($patcher.Contains('ClaudeRtlPatchWatcher')) "Shraga watcher cleanup is missing"
Assert-True ($patcher.Contains('Claude RT-AI RTL Auto-Update')) "Older RT-AI watcher cleanup is missing"
Assert-True ($patcher.Contains('watcher.ps1')) "Watcher file cleanup is missing"
Assert-True ($patcher.Contains('update.ps1')) "Legacy updater file cleanup is missing"
Assert-True ($patcher.Contains('Remove-LegacyCopy')) "Obsolete copied Claude cleanup is missing"
Assert-True ($patcher.Contains('Claude-RT-AI')) "The known obsolete copy path must be removed"
Assert-True (-not $patcher.Contains('Copy-ClaudeApp')) "Claude must not be copied into a second installation"
Assert-True (-not $patcher.Contains('EnableEmbeddedAsarIntegrityValidation=off')) "The official module must use verified hash replacement, not copied-exe fuse changes"
Assert-True ($patcher.Contains('Remove-Shortcuts')) "Claude must remove the obsolete application shortcut"
Assert-True (-not $patcher.Contains('Deploy-Launcher')) "Claude must not deploy a separate application launcher"
Assert-True (-not $patcher.Contains('New-Shortcuts')) "Claude must not recreate an application shortcut"

Assert-True ($payload.Contains('RT-AI CLAUDE RTL PATCH START')) "Claude payload marker is missing"
Assert-True ($payload.Contains('__RT_AI_CLAUDE_RTL_PATCH__')) "Claude payload must be idempotent"
Assert-True ($payload.Contains('hasHebrew')) "Claude payload must detect Hebrew anywhere"
Assert-True ($payload.Contains('.ProseMirror')) "Claude composer support is missing"
Assert-True ($payload.Contains('MutationObserver')) "Claude streaming response support is missing"
Assert-True ($payload.Contains('APP_CHROME_SEL')) "Claude app chrome exclusion is missing"
Assert-True ($payload.Contains('list-style-position:outside!important')) "Claude RTL bullet positioning is missing"
Assert-True ($payload.Contains('table[data-rt-ai-claude-dir=')) "Claude RTL table styling is missing"
Assert-True ($payload.Contains('margin-left:auto!important;margin-right:auto!important')) "Claude RTL tables should be centered"
Assert-True ($payload.Contains('code{direction:ltr!important')) "Claude code must remain LTR"

Assert-True ($installOnline.Contains('NoamHermos/rightly-rtl')) "Claude online installer must use the standalone Rightly repository"
Assert-True ($readme.Contains('applies it directly to Claude')) "README must explain the in-place Claude installation"
Assert-True ($readme.Contains('does not create a copied Claude application')) "README must rule out a copied Claude installation"
Assert-True ($readme.Contains('Repair RTL')) "Claude README must describe the interactive repair shortcut"

& node (Join-Path $PSScriptRoot "claude-direction.test.js")
Assert-True ($LASTEXITCODE -eq 0) "Claude direction behavior tests failed"

if (-not $SkipInstalledBuild) {
    $package = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if ($package -and $npx) {
        $appDir = Join-Path $package.InstallLocation "app"
        $asarPath = Join-Path $appDir "resources\app.asar"
        Assert-True (Test-Path -LiteralPath "$asarPath.bak") "Official Claude ASAR backup is missing"
        Assert-True (Test-Path -LiteralPath (Join-Path $appDir "claude.exe.bak")) "Official Claude executable backup is missing"
        Assert-True (Test-Path -LiteralPath (Join-Path $appDir "resources\cowork-svc.exe.bak")) "Official Cowork service backup is missing"

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-inplace-verify-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Path $tempRoot | Out-Null
            & $npx.Source --yes "@electron/asar" extract $asarPath $tempRoot
            Assert-True ($LASTEXITCODE -eq 0) "Could not extract the official patched Claude ASAR"

            $mainView = Join-Path $tempRoot ".vite\build\mainView.js"
            Assert-True (Test-Path -LiteralPath $mainView) "Official Claude mainView.js is missing"
            $mainViewText = Get-Content -LiteralPath $mainView -Raw
            Assert-True ($mainViewText.Contains("RT-AI CLAUDE RTL PATCH START")) "The official Claude app does not contain the RT-AI renderer payload"

            $packageJson = Get-Content -LiteralPath (Join-Path $tempRoot "package.json") -Raw | ConvertFrom-Json
            $mainEntry = Join-Path $tempRoot ([string] $packageJson.main)
            Assert-True (Test-Path -LiteralPath $mainEntry) "Official Claude main-process entry is missing"
            $mainSource = Get-Content -LiteralPath $mainEntry -Raw
            Assert-True ($mainSource.Contains("CLAUDE RTL MAIN PATCH START")) "Official Claude is missing the window-control direction patch"
            Assert-True ($mainSource.Contains("force-ui-direction', 'ltr")) "Official Claude does not force Chromium UI direction to LTR"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $legacyCopy = Join-Path $env:LOCALAPPDATA "Programs\Claude-RT-AI"
        Assert-True (-not (Test-Path -LiteralPath $legacyCopy)) "The obsolete copied Claude installation still exists"

        $officialProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($appDir, [System.StringComparison]::OrdinalIgnoreCase) })
        Assert-True ($officialProcesses.Count -gt 0) "The official Claude app is not running"

        $automaticTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -in @("ClaudeRtlPatchWatcher", "Claude RT-AI RTL Auto-Update")
        })
        Assert-True ($automaticTasks.Count -eq 0) "An automatic Claude RTL task is still installed"
        Write-Host "Official Claude $($package.Version) in-place installation verified." -ForegroundColor Green
    } else {
        Write-Host "Installed Claude integration check skipped (Claude or npx not found)." -ForegroundColor Yellow
    }
}

Write-Host "Rightly Claude module verification passed." -ForegroundColor Green
