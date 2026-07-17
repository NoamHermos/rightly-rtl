<#
.SYNOPSIS
Shared installation helpers for Rightly's Windows entry points.

.DESCRIPTION
This file owns the interactive target menu, elevation hand-off, repair bundle,
and desktop shortcut. App-specific patching remains in src\gpt\patch.ps1 and
src\claude\patch.ps1 so each integration can be tested independently.
#>

Set-StrictMode -Version 2.0

$Script:RightlyRoot = $null
$Script:RightlyRepairDir = $null
$Script:RightlyRepairShortcutNames = @(
    "Repair RTL.lnk",
    "Repair GPT RTL.lnk",
    "Repair Claude RTL.lnk",
    "Repair GPT + Claude RTL.lnk"
)

function Initialize-RightlyInstaller {
    param([Parameter(Mandatory)][string] $Root)

    $Script:RightlyRoot = [System.IO.Path]::GetFullPath($Root)
    $Script:RightlyRepairDir = Join-Path $env:LOCALAPPDATA "Programs\Rightly\Repair"
}

function Write-RightlyStep {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-RightlyOk {
    param([string] $Message)
    Write-Host "  [+] $Message" -ForegroundColor Green
}

function Write-RightlyInfo {
    param([string] $Message)
    Write-Host "  [*] $Message" -ForegroundColor DarkGray
}

function Get-RightlyPowerShellPath {
    $current = Get-Process -Id $PID -ErrorAction SilentlyContinue
    if ($current -and $current.Path) { return $current.Path }
    return (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe")
}

function Select-RightlyTarget {
    param([ValidateSet("install", "repair", "uninstall")][string] $Operation)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  Rightly - Interactive RTL $Operation"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "  1. GPT Work / Codex"
    Write-Host "  2. Claude Desktop / Code"
    Write-Host "  3. Both"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Choose what to $Operation [1-3]"
        switch ($choice.Trim()) {
            "1" { return "GptWork" }
            "2" { return "ClaudeCode" }
            "3" { return "Both" }
            default { Write-Host "Please enter 1, 2, or 3." -ForegroundColor Yellow }
        }
    }
}

function Test-RightlyAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Invoke-RightlyElevatedInstallerIfNeeded {
    param(
        [Parameter(Mandatory)][string] $Target,
        [switch] $RepairMode,
        [switch] $NoLaunch,
        [switch] $Elevated
    )

    if (Test-RightlyAdministrator) { return $false }
    if ($Elevated) { throw "Administrator rights were requested but were not granted." }

    $installer = Join-Path $Script:RightlyRoot "installer\install.ps1"
    if (-not (Test-Path -LiteralPath $installer)) {
        throw "Cannot elevate because the installer is missing: $installer"
    }

    Write-RightlyStep "Requesting administrator rights for the official applications"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$installer`" -Target $Target -Elevated -NoLaunch"
    if ($RepairMode) { $arguments += " -RepairMode" }

    $process = Start-Process -FilePath (Get-RightlyPowerShellPath) `
        -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The elevated installer exited with code $($process.ExitCode)."
    }
    return $true
}

function Invoke-RightlyPatcher {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet("Install", "Uninstall")][string] $Action = "Install"
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "$Name patcher was not found at $Path" }
    Write-RightlyStep "$Action $Name"
    & (Get-RightlyPowerShellPath) -NoProfile -ExecutionPolicy Bypass -File $Path "-$Action" -NoLaunch
    if ($LASTEXITCODE -ne 0) { throw "$Name patcher exited with code $LASTEXITCODE." }
}

function Invoke-RightlyOfficialLauncher {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Path,
        [switch] $IsolateApplicationOutput
    )

    Write-RightlyStep "Opening the official $Name application"
    if ($IsolateApplicationOutput) {
        $logDir = Join-Path $Script:RightlyRepairDir "logs"
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $safeName = ($Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
        $stdoutLog = Join-Path $logDir "$safeName-launch.stdout.log"
        $stderrLog = Join-Path $logDir "$safeName-launch.stderr.log"
        & (Get-RightlyPowerShellPath) -NoProfile -ExecutionPolicy Bypass `
            -File $Path -Launch 1> $stdoutLog 2> $stderrLog
        $launcherExitCode = $LASTEXITCODE
        if ($launcherExitCode -ne 0) {
            throw "$Name launcher exited with code $launcherExitCode. See $stderrLog"
        }
    } else {
        & (Get-RightlyPowerShellPath) -NoProfile -ExecutionPolicy Bypass -File $Path -Launch
        if ($LASTEXITCODE -ne 0) { throw "$Name launcher exited with code $LASTEXITCODE." }
    }
    Write-RightlyOk "$Name repair completed and the official app launched successfully."
}

function Copy-RightlyRepairFile {
    param([Parameter(Mandatory)][string] $RelativePath)

    $source = Join-Path $Script:RightlyRoot $RelativePath
    $destination = Join-Path $Script:RightlyRepairDir $RelativePath
    if (-not (Test-Path -LiteralPath $source)) { throw "Repair source file is missing: $source" }

    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    $sourceFull = [System.IO.Path]::GetFullPath($source)
    $destinationFull = [System.IO.Path]::GetFullPath($destination)
    if (-not $sourceFull.Equals($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $sourceFull -Destination $destinationFull -Force
    }
}

function Install-RightlyRepairBundle {
    Write-RightlyStep "Installing the interactive RTL repair command"
    foreach ($relative in @(
        "installer\install.ps1",
        "installer\install-online.ps1",
        "installer\run-repair.ps1",
        "installer\uninstall.ps1",
        "installer\lib\Rightly.Install.ps1",
        "assets\rightly.ico",
        "assets\rightly-gpt.ico",
        "src\gpt\patch.ps1",
        "src\gpt\codex-rtl-payload.js",
        "src\gpt\gpt-rtl-cdp.js",
        "src\gpt\launch-gpt.ps1",
        "src\gpt\Rightly.Gpt.Launcher.cs",
        "src\gpt\lib\Rightly.GptAsar.ps1",
        "src\gpt\lib\Rightly.GptLauncher.ps1",
        "src\claude\patch.ps1",
        "src\claude\claude-rtl-payload.js"
    )) {
        Copy-RightlyRepairFile $relative
    }
    Remove-RightlyLegacyRepairBundle
    Write-RightlyOk "Repair command installed at $($Script:RightlyRepairDir)"
}

function Remove-RightlyLegacyRepairBundle {
    $legacy = Join-Path $env:LOCALAPPDATA "Programs\GPTW-CC-RTL-repair"
    if (-not (Test-Path -LiteralPath $legacy)) { return }

    $legacyFull = [System.IO.Path]::GetFullPath($legacy).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($Script:RightlyRoot).TrimEnd('\')
    if ($rootFull.Equals($legacyFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-RightlyInfo "The previous repair folder is currently in use and will be removed by the next installer run."
        return
    }

    try {
        Remove-Item -LiteralPath $legacyFull -Recurse -Force -ErrorAction Stop
        Write-RightlyInfo "Removed the previous repair bundle: $legacyFull"
    } catch {
        # A PowerShell window launched by the old shortcut can keep its working
        # directory open. The folder is harmless and is retried next run.
        Write-RightlyInfo "The previous repair folder is still in use; cleanup will be retried next run."
    }
}

function Remove-RightlyOldShortcuts {
    $desktop = [Environment]::GetFolderPath("Desktop")
    foreach ($name in $Script:RightlyRepairShortcutNames) {
        Remove-Item -LiteralPath (Join-Path $desktop $name) -Force -ErrorAction SilentlyContinue
    }

    # Only remove names created by older Rightly releases. A generic Codex.lnk
    # can belong to the official app and must never be removed by name alone.
    foreach ($folder in @($desktop, [Environment]::GetFolderPath("Programs"))) {
        foreach ($name in @("Codex RT-AI.lnk", "Codex RTL.lnk", "Claude RTL.lnk")) {
            Remove-Item -LiteralPath (Join-Path $folder $name) -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-RightlyRepairShortcut {
    Remove-RightlyOldShortcuts

    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktop "Repair RTL.lnk"
    $repairRunner = Join-Path $Script:RightlyRepairDir "installer\run-repair.ps1"
    $icon = Join-Path $Script:RightlyRepairDir "assets\rightly.ico"

    foreach ($path in @($repairRunner, $icon)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Repair shortcut dependency is missing: $path" }
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Get-RightlyPowerShellPath
    $shortcut.WorkingDirectory = $Script:RightlyRepairDir
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$repairRunner`" -Target Prompt"
    $shortcut.IconLocation = "$icon,0"
    $shortcut.Description = "Rightly: repair RTL in GPT, Claude, or both"
    $shortcut.Save()
    Write-RightlyOk "Created repair shortcut: $shortcutPath"
}

function Remove-RightlyRepairShortcut {
    $desktop = [Environment]::GetFolderPath("Desktop")
    foreach ($name in $Script:RightlyRepairShortcutNames) {
        Remove-Item -LiteralPath (Join-Path $desktop $name) -Force -ErrorAction SilentlyContinue
    }
}

function Remove-RightlyRepairBundle {
    if (-not (Test-Path -LiteralPath $Script:RightlyRepairDir)) { return }
    $allowed = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs\Rightly\Repair"))
    $actual = [System.IO.Path]::GetFullPath($Script:RightlyRepairDir)
    if (-not $actual.Equals($allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected repair directory: $actual"
    }
    Remove-Item -LiteralPath $actual -Recurse -Force
}
