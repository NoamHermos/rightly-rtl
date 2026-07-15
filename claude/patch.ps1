<#
Rightly Claude Desktop RTL patcher for Windows.

Patches the official Claude MSIX installation in place. The low-level ASAR,
hash, certificate, backup, and rollback engine is taken from a pinned revision
of shraga100/claude-desktop-rtl-patch. Its renderer payload is replaced with
the RT-AI payload and its interactive/automatic-update entry point is removed.
#>

[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Status,
    [switch] $Launch,
    [switch] $NoLaunch,
    [switch] $Elevated
)

$ErrorActionPreference = "Stop"

$Script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:PayloadPath = Join-Path $Script:ModuleRoot "claude-rtl-payload.js"
$Script:ShortcutName = "Claude RTL.lnk"
$Script:LauncherDir = Join-Path $env:LOCALAPPDATA "Programs\Claude-RTL-launcher"
$Script:LegacyCopyDir = Join-Path $env:LOCALAPPDATA "Programs\Claude-RT-AI"
$Script:LegacyPatcherDir = Join-Path $env:LOCALAPPDATA "Programs\Claude-RT-AI-patcher"
$Script:StateDir = Join-Path $env:ProgramData "ClaudeRtlPatch"
$Script:UpstreamCommit = "7174841b13c250654f48b6e57b15e6eb42a776b9"
$Script:UpstreamSha256 = "2ba1c3fa2b53f92a2f99b11f12e73d5e5ffd6f4ad77c718cec064af9cc1dbe93"
$Script:UpstreamUrl = "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/$($Script:UpstreamCommit)/patch.ps1"
$Script:AutomaticTaskNames = @(
    "Claude RT-AI RTL Auto-Update",
    "ClaudeRtlPatchWatcher"
)

# Console and elevation -------------------------------------------------------
function Write-Step {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string] $Message)
    Write-Host "  [*] $Message"
}

function Write-Ok {
    param([string] $Message)
    Write-Host "  [+] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string] $Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator
    )
}

function Invoke-ElevatedIfNeeded {
    param([ValidateSet("Install", "Uninstall")][string] $Action)

    if (Test-IsAdministrator) { return $false }
    if ($Elevated) { throw "Administrator rights were requested but were not granted." }
    if (-not $PSCommandPath) { throw "Cannot elevate because the patcher does not have a file path." }

    Write-Step "Requesting administrator rights for the official Claude installation"
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -$Action -Elevated"
    if ($NoLaunch) { $arguments += " -NoLaunch" }
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The elevated Claude $Action process exited with code $($process.ExitCode)."
    }
    return $true
}

# Official package and process management -----------------------------------
function Get-OfficialClaudePackage {
    $package = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) { throw "The official Claude app is not installed for this account." }

    $appDir = Join-Path $package.InstallLocation "app"
    $exe = Join-Path $appDir "claude.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "The official Claude executable was not found at $exe."
    }
    return [pscustomobject]@{
        Package = $package
        AppDir = [System.IO.Path]::GetFullPath($appDir)
        Exe = [System.IO.Path]::GetFullPath($exe)
        AppUserModelId = "$($package.PackageFamilyName)!Claude"
    }
}

function Get-ClaudeProcesses {
    param([string[]] $Roots)

    $normalizedRoots = @($Roots | Where-Object { $_ } | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
    })
    return @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.ExecutablePath
            if (-not $path) { return $false }
            $full = [System.IO.Path]::GetFullPath($path)
            @($normalizedRoots | Where-Object {
                $full.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        })
}

function Stop-ClaudeProcesses {
    $official = Get-OfficialClaudePackage
    $roots = @($official.AppDir, $Script:LegacyCopyDir)
    $processes = @(Get-ClaudeProcesses $roots)
    $main = $processes | Where-Object { $_.CommandLine -notmatch "--type=" } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void] $process.CloseMainWindow() }
        Start-Sleep -Seconds 2
    }
    foreach ($item in @(Get-ClaudeProcesses $roots)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Legacy watcher cleanup -----------------------------------------------------
function Get-AutomaticTasks {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $task = $_
        $knownName = $task.TaskName -in $Script:AutomaticTaskNames
        $knownAction = @($task.Actions | Where-Object {
            (($_.Execute + " " + $_.Arguments) -match '(?i)ClaudeRtlPatch[\\/]watcher\.ps1|claude-desktop-rtl-patch')
        }).Count -gt 0
        $knownName -or $knownAction
    })
}

function Remove-AutomaticPatching {
    foreach ($task in @(Get-AutomaticTasks)) {
        try {
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Info "Removed automatic task: $($task.TaskName)"
        } catch {
            Write-Warn "Could not remove automatic task '$($task.TaskName)': $($_.Exception.Message)"
        }
    }

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match '(?i)ClaudeRtlPatch[\\/]watcher\.ps1|claude-desktop-rtl-patch.*watch'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    foreach ($stateDir in @($Script:StateDir, (Join-Path $env:LOCALAPPDATA "ClaudeRtlPatch"))) {
        foreach ($name in @("watcher.ps1", "update.ps1")) {
            $path = Join-Path $stateDir $name
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (@(Get-AutomaticTasks).Count -gt 0) {
        throw "A Claude RTL automatic task remains installed. Run this installer as Administrator."
    }
}

# Verified upstream transformation ------------------------------------------
function Get-TextSha256 {
    param([string] $Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash($bytes) } finally { $algorithm.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Get-TransformedUpstreamScript {
    param([ValidateSet("Install", "Uninstall")][string] $Action)

    if (-not (Test-Path -LiteralPath $Script:PayloadPath)) {
        throw "The RT-AI Claude payload is missing at $($Script:PayloadPath)."
    }

    Write-Step "Downloading the pinned in-place Claude patch engine"
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $upstream = $null
    $downloadError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $upstream = (Invoke-WebRequest -Uri $Script:UpstreamUrl -UseBasicParsing -TimeoutSec 45).Content
            break
        } catch {
            $downloadError = $_
            if ($attempt -lt 3) {
                Write-Warn "Download attempt $attempt failed; retrying..."
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }
    if (-not $upstream) {
        throw "Could not download the pinned Claude patch engine after three attempts: $($downloadError.Exception.Message)"
    }
    $actualHash = Get-TextSha256 $upstream
    if ($actualHash -ne $Script:UpstreamSha256) {
        throw "The pinned upstream patch failed SHA-256 verification ($actualHash)."
    }
    Write-Ok "Verified upstream revision $($Script:UpstreamCommit.Substring(0, 12))."

    $payload = Get-Content -LiteralPath $Script:PayloadPath -Raw
    $assignment = '$RTL_INJECTION_CODE = @'''
    $payloadStart = $upstream.IndexOf($assignment, [System.StringComparison]::Ordinal)
    $mainComment = $upstream.IndexOf("# Main-process snippet", [System.StringComparison]::Ordinal)
    if ($payloadStart -lt 0 -or $mainComment -le $payloadStart) {
        throw "The pinned upstream renderer payload could not be isolated safely."
    }

    $replacement = $assignment + "`r`n" + $payload.TrimEnd() + "`r`n'@`r`n`r`n"
    $transformed = $upstream.Substring(0, $payloadStart) + $replacement + $upstream.Substring($mainComment)

    $menuMarker = $transformed.LastIndexOf("# MAIN MENU LOOP", [System.StringComparison]::Ordinal)
    if ($menuMarker -lt 0) { throw "The pinned upstream menu entry point could not be isolated safely." }
    $tail = if ($Action -eq "Install") {
        "# Non-interactive RT-AI install`r`nInstall-Patch`r`nUninstall-AutoUpdateTask`r`n"
    } else {
        "# Non-interactive RT-AI restore`r`nRestore-Patch`r`nUninstall-AutoUpdateTask`r`n"
    }
    return $transformed.Substring(0, $menuMarker) + $tail
}

function Invoke-InPlaceAction {
    param([ValidateSet("Install", "Uninstall")][string] $Action)

    $scriptText = Get-TransformedUpstreamScript $Action
    $hadAuto = Test-Path Env:CLAUDE_RTL_AUTO
    $oldAuto = $env:CLAUDE_RTL_AUTO
    $env:CLAUDE_RTL_AUTO = "1"
    try {
        & ([scriptblock]::Create($scriptText))
    } finally {
        if ($hadAuto) { $env:CLAUDE_RTL_AUTO = $oldAuto }
        else { Remove-Item Env:CLAUDE_RTL_AUTO -ErrorAction SilentlyContinue }
    }
}

# Managed files and official launcher ---------------------------------------
function Remove-DirectoryIfAllowed {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowed = @($Script:LegacyCopyDir, $Script:LegacyPatcherDir, $Script:LauncherDir) |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
    if ($full -notin $allowed) { throw "Refusing to remove unexpected directory: $full" }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Get-DesktopShortcutPath {
    return Join-Path ([Environment]::GetFolderPath("Desktop")) $Script:ShortcutName
}

function Get-StartMenuShortcutPath {
    return Join-Path ([Environment]::GetFolderPath("Programs")) $Script:ShortcutName
}

function Remove-Shortcuts {
    foreach ($path in @((Get-DesktopShortcutPath), (Get-StartMenuShortcutPath))) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Start-OfficialClaude {
    $official = Get-OfficialClaudePackage
    if (@(Get-ClaudeProcesses @($official.AppDir)).Count -gt 0) {
        Write-Info "Official Claude is already running."
        return
    }

    if (-not ("RtAiClaudeActivation" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IRtAiApplicationActivationManager {
    int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    int ActivateForFile(IntPtr appUserModelId, IntPtr itemArray, IntPtr verb, out uint processId);
    int ActivateForProtocol(IntPtr appUserModelId, IntPtr itemArray, out uint processId);
}

[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
class RtAiApplicationActivationManager { }

public static class RtAiClaudeActivation {
    public static uint Start(string appUserModelId, string arguments) {
        var manager = (IRtAiApplicationActivationManager)new RtAiApplicationActivationManager();
        uint processId;
        int result = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);
        if (result < 0) Marshal.ThrowExceptionForHR(result);
        return processId;
    }
}
'@
    }

    [void] [RtAiClaudeActivation]::Start($official.AppUserModelId, "--force-ui-direction=ltr")
    Write-Ok "Launched the official Claude app."
}

function Remove-LegacyCopy {
    foreach ($item in @(Get-ClaudeProcesses @($Script:LegacyCopyDir))) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Remove-DirectoryIfAllowed $Script:LegacyCopyDir
    Remove-DirectoryIfAllowed $Script:LegacyPatcherDir
}

# Public actions -------------------------------------------------------------
function Install-ClaudePatch {
    if (Invoke-ElevatedIfNeeded "Install") { return }
    Write-Step "Disabling every legacy automatic Claude RTL patch"
    Remove-AutomaticPatching

    Invoke-InPlaceAction "Install"
    Remove-AutomaticPatching

    Write-Step "Removing the obsolete copied Claude installation"
    Remove-LegacyCopy
    Remove-Shortcuts
    Remove-DirectoryIfAllowed $Script:LauncherDir

    if ($NoLaunch) { Stop-ClaudeProcesses }
    else { Start-OfficialClaude }

    Write-Host ""
    Write-Ok "The official Claude app is patched in place. The unified installer manages the repair shortcut."
}

function Uninstall-ClaudePatch {
    if (Invoke-ElevatedIfNeeded "Uninstall") { return }
    Remove-AutomaticPatching
    Remove-LegacyCopy
    Invoke-InPlaceAction "Uninstall"
    Remove-AutomaticPatching
    Remove-Shortcuts
    Remove-DirectoryIfAllowed $Script:LauncherDir
    Write-Ok "Claude was restored from its official backups and the RT-AI launcher was removed."
}

function Show-ClaudePatchStatus {
    $official = Get-OfficialClaudePackage
    $statePath = Join-Path $Script:StateDir "state.json"
    Write-Host ""
    Write-Host "Rightly for Claude - Status" -ForegroundColor Cyan
    Write-Info "Official package: $($official.Package.Version)"
    Write-Info "Official executable: $($official.Exe)"
    if (Test-Path -LiteralPath $statePath) { Write-Ok "In-place patch state: $statePath" }
    else { Write-Warn "In-place patch state was not found." }
    if (Test-Path -LiteralPath $Script:LegacyCopyDir) { Write-Warn "Obsolete Claude copy still exists: $($Script:LegacyCopyDir)" }
    else { Write-Ok "No copied Claude installation exists." }
    if (@(Get-AutomaticTasks).Count -gt 0) { Write-Warn "An automatic Claude RTL task is still installed." }
    else { Write-Ok "Automatic patching is disabled." }
}

$selectedActions = @()
if ($Install) { $selectedActions += "Install" }
if ($Uninstall) { $selectedActions += "Uninstall" }
if ($Status) { $selectedActions += "Status" }
if ($Launch) { $selectedActions += "Launch" }
if ($selectedActions.Count -eq 0) { $Install = $true; $selectedActions = @("Install") }
if ($selectedActions.Count -gt 1) { throw "Choose only one action: -Install, -Uninstall, -Status, or -Launch." }

if ($Install) { Install-ClaudePatch }
elseif ($Uninstall) { Uninstall-ClaudePatch }
elseif ($Status) { Show-ClaudePatchStatus }
elseif ($Launch) { Start-OfficialClaude }
