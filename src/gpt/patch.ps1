<#
.SYNOPSIS
Applies persistent Rightly RTL support to the official GPT Work / Codex app.

.DESCRIPTION
The official Microsoft Store package is patched in place by rebuilding only
its external app.asar. The original ASAR is backed up with package and hash
metadata so uninstall and failed-install rollback never restore across app
versions. No copied application, DevTools endpoint, watcher, or runtime
injector is required after installation.
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
$Script:PayloadPath = Join-Path $Script:ModuleRoot "codex-rtl-payload.js"
$Script:AsarModulePath = Join-Path $Script:ModuleRoot "lib\Rightly.GptAsar.ps1"
$Script:StateRoot = Join-Path $env:ProgramData "Rightly\GPT"
$Script:StatePath = Join-Path $Script:StateRoot "state.json"
$Script:BackupPath = Join-Path $Script:StateRoot "backup\app.asar"
$Script:LegacyRuntimeDir = Join-Path $env:LOCALAPPDATA "Programs\Rightly\GPT"
$Script:LegacyStateDirs = @(
    (Join-Path $env:ProgramData "GptwRtlPatch"),
    (Join-Path $env:ProgramData "CodexRtAi")
)
$Script:LegacyModificationNames = @(
    "RT.AI.Codex.RTL.Modification",
    "OpenAI.Codex.RtAiRtl"
)
$Script:LegacyCertificateFriendlyNames = @(
    "RT-AI GPTW RTL Modification",
    "Codex RT-AI Modification Package"
)
$Script:LegacyTaskNames = @("Codex RT-AI RTL Auto-Update")
$Script:LegacyCopyDirs = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Codex-RT-AI"),
    (Join-Path $env:LOCALAPPDATA "Programs\Codex-RT-AI-patcher"),
    (Join-Path $env:LOCALAPPDATA "Programs\Rightly-GPT-Embedded")
)

if (-not (Test-Path -LiteralPath $Script:AsarModulePath -PathType Leaf)) {
    throw "GPT ASAR helper is missing: $($Script:AsarModulePath)"
}
. $Script:AsarModulePath

# Console and process helpers ------------------------------------------------
function Write-Step { param([string] $Message); Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message); Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-Info { param([string] $Message); Write-Host "  [*] $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message); Write-Host "  [!] $Message" -ForegroundColor Yellow }

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Invoke-ElevatedIfNeeded {
    param([ValidateSet("Install", "Uninstall")][string] $Action)

    if (Test-IsAdministrator) { return $false }
    if ($Elevated) { throw "Administrator rights were requested but were not granted." }
    if (-not $PSCommandPath) { throw "Cannot elevate because the GPT patcher has no file path." }

    Write-Step "Requesting administrator rights for the official GPT installation"
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -$Action -Elevated"
    if ($NoLaunch) { $arguments += " -NoLaunch" }
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The elevated GPT $Action process exited with code $($process.ExitCode)."
    }
    return $true
}

# Official package -----------------------------------------------------------
function Get-OfficialCodexPackage {
    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) { throw "The official GPT Work / Codex app is not installed." }

    $appDir = Join-Path $package.InstallLocation "app"
    $exe = Join-Path $appDir "ChatGPT.exe"
    $asar = Join-Path $appDir "resources\app.asar"
    foreach ($path in @($exe, $asar)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Official GPT file is missing: $path" }
    }
    return [pscustomobject]@{
        Package = $package
        PackageFullName = [string] $package.PackageFullName
        Version = [string] $package.Version
        AppDir = [System.IO.Path]::GetFullPath($appDir)
        Exe = [System.IO.Path]::GetFullPath($exe)
        Asar = [System.IO.Path]::GetFullPath($asar)
        AppUserModelId = "$($package.PackageFamilyName)!App"
    }
}

function Get-OfficialCodexProcesses {
    param([string] $AppDir)
    $prefix = [System.IO.Path]::GetFullPath($AppDir).TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith(
            $prefix, [System.StringComparison]::OrdinalIgnoreCase
        )
    })
}

function Stop-OfficialCodex {
    param([string] $AppDir)
    $processes = @(Get-OfficialCodexProcesses $AppDir)
    $main = $processes | Where-Object {
        $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type="
    } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void] $process.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(8)
        while (@(Get-OfficialCodexProcesses $AppDir).Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    foreach ($item in @(Get-OfficialCodexProcesses $AppDir)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-OfficialCodex {
    $official = Get-OfficialCodexPackage
    if (@(Get-OfficialCodexProcesses $official.AppDir).Count -gt 0) {
        Write-Info "Official GPT Work / Codex is already running."
        return
    }

    if (-not ("RightlyCodexActivation" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IRightlyApplicationActivationManager {
    int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    int ActivateForFile(IntPtr appUserModelId, IntPtr itemArray, IntPtr verb, out uint processId);
    int ActivateForProtocol(IntPtr appUserModelId, IntPtr itemArray, out uint processId);
}
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
class RightlyApplicationActivationManager { }
public static class RightlyCodexActivation {
    public static uint Start(string appUserModelId) {
        var manager = (IRightlyApplicationActivationManager)new RightlyApplicationActivationManager();
        uint processId;
        int result = manager.ActivateApplication(appUserModelId, "", 0, out processId);
        if (result < 0) Marshal.ThrowExceptionForHR(result);
        return processId;
    }
}
'@
    }

    $processId = [RightlyCodexActivation]::Start($official.AppUserModelId)
    $deadline = (Get-Date).AddSeconds(12)
    do {
        Start-Sleep -Milliseconds 300
        $main = @(Get-OfficialCodexProcesses $official.AppDir | Where-Object {
            $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type="
        })
    } while ($main.Count -eq 0 -and (Get-Date) -lt $deadline)
    if ($main.Count -eq 0) { throw "The official GPT app did not remain open after activation." }
    Write-Ok "Launched the official persistent-patch GPT app (PID $processId)."
}

# Managed state and legacy cleanup ------------------------------------------
function Assert-ExactManagedPath {
    param([string] $Path, [string[]] $AllowedPaths)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowed = @($AllowedPaths | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\')
    })
    if (-not ($allowed | Where-Object {
        $full.Equals($_, [System.StringComparison]::OrdinalIgnoreCase)
    })) { throw "Refusing to remove unmanaged path: $full" }
    return $full
}

function Remove-ManagedDirectory {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $allowed = @($Script:StateRoot, $Script:LegacyRuntimeDir) +
        @($Script:LegacyStateDirs) + @($Script:LegacyCopyDirs)
    $full = Assert-ExactManagedPath -Path $Path -AllowedPaths $allowed
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Read-PatchState {
    if (-not (Test-Path -LiteralPath $Script:StatePath)) { return $null }
    return Get-Content -LiteralPath $Script:StatePath -Raw | ConvertFrom-Json
}

function Write-PatchState {
    param([System.Collections.IDictionary] $State)
    New-Item -ItemType Directory -Path $Script:StateRoot -Force | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Script:StatePath -Encoding UTF8
}

function Get-VerifiedRollbackBackup {
    param([Parameter(Mandatory)] $State)

    $recorded = [System.IO.Path]::GetFullPath([string] $State.backupPath)
    $expected = [System.IO.Path]::GetFullPath($Script:BackupPath)
    if (-not $recorded.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The GPT rollback state points outside Rightly's managed backup path."
    }
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
        throw "The GPT rollback backup is missing: $expected"
    }
    $backupHash = (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($backupHash -ne [string] $State.originalHash) {
        throw "The GPT rollback backup failed SHA-256 verification."
    }
    return $expected
}

function Get-ProcessesUnderPaths {
    param([string[]] $Paths)
    $prefixes = @($Paths | Where-Object { $_ } | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
    })
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.ExecutablePath) { return $false }
        $full = [System.IO.Path]::GetFullPath($_.ExecutablePath)
        @($prefixes | Where-Object {
            $full.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
    })
}

function Remove-LegacyCopiedApps {
    foreach ($item in @(Get-ProcessesUnderPaths $Script:LegacyCopyDirs)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $prefixes = @($Script:LegacyCopyDirs | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
    })
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("Programs"),
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"),
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\StartMenu")
    )) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter "*.lnk" -Force -ErrorAction SilentlyContinue)) {
            try {
                $target = [System.IO.Path]::GetFullPath($shell.CreateShortcut($file.FullName).TargetPath)
                if ($prefixes | Where-Object {
                    $target.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
                }) {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    Write-Info "Removed obsolete copied-app shortcut: $($file.FullName)"
                }
            } catch { }
        }
    }

    foreach ($path in $Script:LegacyCopyDirs) {
        if (Test-Path -LiteralPath $path) {
            Remove-ManagedDirectory $path
            Write-Info "Removed obsolete copied GPT build: $path"
        }
    }
}

function Remove-LegacyRuntime {
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '(?i)gpt-rtl-cdp\.js' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Script:LegacyRuntimeDir) {
        Remove-ManagedDirectory $Script:LegacyRuntimeDir
        Write-Info "Removed the obsolete in-memory GPT runtime."
    }
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($name in $Script:LegacyTaskNames) {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($task) {
                Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                Write-Info "Removed legacy automatic task: $name"
            }
        }
    }
}

function Remove-LegacyModificationPackage {
    foreach ($name in $Script:LegacyModificationNames) {
        $packages = @(Get-AppxPackage -Name $name -PackageTypeFilter Optional -ErrorAction SilentlyContinue)
        foreach ($package in $packages) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            Write-Info "Removed ineffective legacy MSIX overlay: $($package.PackageFullName)"
        }
    }
    foreach ($path in $Script:LegacyStateDirs) { Remove-ManagedDirectory $path }

    foreach ($storePath in @(
        "Cert:\CurrentUser\My", "Cert:\CurrentUser\Root", "Cert:\CurrentUser\TrustedPeople",
        "Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPeople"
    )) {
        Get-ChildItem $storePath -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -in $Script:LegacyCertificateFriendlyNames } |
            ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Force -ErrorAction Stop }
    }
}

# In-place ASAR installation ------------------------------------------------
function Grant-AsarWriteAccess {
    param([string] $AsarPath)
    if (-not (Test-IsAdministrator)) { throw "Administrator rights are required to patch the official GPT ASAR." }
    $resourcesDir = Split-Path -Parent $AsarPath
    & (Join-Path $env:WINDIR "System32\takeown.exe") /F $AsarPath /A | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not take ownership of the official GPT ASAR." }
    & (Join-Path $env:WINDIR "System32\icacls.exe") $AsarPath /grant '*S-1-5-32-544:(F)' /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant write access to the official GPT ASAR." }
    & (Join-Path $env:WINDIR "System32\icacls.exe") $resourcesDir /grant '*S-1-5-32-544:(M)' /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant write access to the official GPT resources folder." }
    try {
        Set-ItemProperty -LiteralPath $AsarPath -Name IsReadOnly -Value $false -ErrorAction Stop
    } catch { }
}

function Assert-AsarCanBeReplaced {
    param([string] $AsarPath)

    try {
        $stream = [System.IO.File]::Open(
            $AsarPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $stream.Close()
    } catch {
        $processHint = ""
        try {
            $official = Get-OfficialCodexPackage
            $processes = @(Get-OfficialCodexProcesses $official.AppDir)
            if ($processes.Count -gt 0) {
                $ids = ($processes | Select-Object -ExpandProperty ProcessId) -join ", "
                $processHint = " Remaining GPT/Codex process ids: $ids."
            }
        } catch { }
        throw "Rightly could not replace GPT's app.asar. Close every GPT Work / Codex window and any Codex task still running, then run Repair RTL again.$processHint Original error: $($_.Exception.Message)"
    }
}

function Copy-VerifiedAsar {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $ExpectedHash
    )

    Grant-AsarWriteAccess $Destination
    Assert-AsarCanBeReplaced $Destination
    [System.IO.File]::Copy($Source, $Destination, $true)
    $installedHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -ne $ExpectedHash) { throw "The installed GPT ASAR failed SHA-256 verification." }
    return $installedHash
}

function Get-OriginalAsarForInstall {
    param([pscustomobject] $Official)

    $state = Read-PatchState
    $currentHash = (Get-FileHash -LiteralPath $Official.Asar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($state -and $state.packageFullName -eq $Official.PackageFullName) {
        $backup = Get-VerifiedRollbackBackup $state

        if ($currentHash -eq [string] $state.patchedHash) {
            Write-Info "Restoring the verified original before refreshing the Rightly payload."
            Copy-VerifiedAsar -Source $backup -Destination $Official.Asar -ExpectedHash ([string] $state.originalHash) | Out-Null
            return $Official.Asar
        }
        if ($currentHash -eq [string] $state.originalHash) { return $Official.Asar }
        throw "The official GPT ASAR changed unexpectedly. Update or repair GPT from Microsoft Store, then run Rightly again."
    }

    if ($state) {
        Write-Info "Detected a new official GPT package; replacing the obsolete version-specific backup."
        Remove-ManagedDirectory $Script:StateRoot
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Script:BackupPath) -Force | Out-Null
    Copy-Item -LiteralPath $Official.Asar -Destination $Script:BackupPath -Force
    $backupHash = (Get-FileHash -LiteralPath $Script:BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($backupHash -ne $currentHash) { throw "The GPT rollback backup failed verification after copying." }
    return $Official.Asar
}

function Install-PersistentCodexPatch {
    if (Invoke-ElevatedIfNeeded "Install") { return }
    if (-not (Test-Path -LiteralPath $Script:PayloadPath)) { throw "RTL payload is missing: $($Script:PayloadPath)" }
    $npx = Get-RightlyToolPath @("npx.cmd")
    if (-not $npx) { throw "Node.js with npx is required during GPT installation and repair." }

    $official = Get-OfficialCodexPackage
    Write-Step "Closing the official GPT app"
    Stop-OfficialCodex $official.AppDir
    Remove-LegacyRuntime
    Remove-LegacyCopiedApps
    Remove-LegacyModificationPackage

    $originalAsar = Get-OriginalAsarForInstall $official
    $originalHash = (Get-FileHash -LiteralPath $originalAsar -Algorithm SHA256).Hash.ToLowerInvariant()
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rightly-gpt-asar-" + [guid]::NewGuid().ToString("N"))
    $patchedAsar = Join-Path $tempRoot "app.asar"

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $build = New-RightlyGptAsar -SourceAsar $originalAsar -DestinationAsar $patchedAsar `
            -PayloadPath $Script:PayloadPath -NpxPath $npx
        $patchedHash = $build.Sha256
        if ($patchedHash -eq $originalHash) { throw "The patched ASAR hash did not change." }

        Write-Step "Installing the persistent patch into the official GPT package"
        $installedHash = Copy-VerifiedAsar -Source $patchedAsar -Destination $official.Asar -ExpectedHash $patchedHash

        Write-PatchState ([ordered]@{
            architecture = "official-in-place-asar"
            packageFullName = $official.PackageFullName
            packageVersion = $official.Version
            asarPath = $official.Asar
            backupPath = $Script:BackupPath
            originalHash = $originalHash
            patchedHash = $patchedHash
            payloadHash = (Get-FileHash -LiteralPath $Script:PayloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            installedAt = (Get-Date).ToString("o")
        })
        Write-Ok "GPT was patched in place. Normal future launches will keep Rightly active."
    } catch {
        if (Test-Path -LiteralPath $Script:BackupPath) {
            try {
                $backupHash = (Get-FileHash -LiteralPath $Script:BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
                Copy-VerifiedAsar -Source $Script:BackupPath -Destination $official.Asar -ExpectedHash $backupHash | Out-Null
                Write-Warn "The original GPT ASAR was restored after the failed patch."
            } catch { }
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($NoLaunch) { Write-Info "Launch deferred to the unified installer." }
    else { Start-OfficialCodex }
}

function Uninstall-PersistentCodexPatch {
    if (Invoke-ElevatedIfNeeded "Uninstall") { return }
    $official = Get-OfficialCodexPackage
    Stop-OfficialCodex $official.AppDir
    $state = Read-PatchState

    if ($state -and $state.packageFullName -eq $official.PackageFullName) {
        $backup = Get-VerifiedRollbackBackup $state
        $currentHash = (Get-FileHash -LiteralPath $official.Asar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -eq [string] $state.patchedHash) {
            Copy-VerifiedAsar -Source $backup -Destination $official.Asar -ExpectedHash ([string] $state.originalHash) | Out-Null
            Write-Ok "Restored the original official GPT ASAR."
        } elseif ($currentHash -ne [string] $state.originalHash) {
            throw "The GPT ASAR changed unexpectedly; the verified backup was kept at $backup"
        }
    } elseif ($state) {
        Write-Info "The official GPT package was updated; its current files were not modified by uninstall."
    }

    Remove-ManagedDirectory $Script:StateRoot
    Remove-LegacyRuntime
    Remove-LegacyCopiedApps
    Remove-LegacyModificationPackage
    Write-Ok "Rightly was removed. The official GPT app remains installed."
}

function Show-PersistentCodexStatus {
    $official = Get-OfficialCodexPackage
    $state = Read-PatchState
    Write-Host ""
    Write-Host "Rightly for GPT Work / Codex - Status" -ForegroundColor Cyan
    Write-Info "Official package: $($official.PackageFullName)"
    if (-not $state) { Write-Warn "No persistent Rightly patch state was found."; return }
    if ($state.packageFullName -ne $official.PackageFullName) {
        Write-Warn "GPT was updated after Rightly was installed. Run Repair RTL once."
        return
    }
    $currentHash = (Get-FileHash -LiteralPath $official.Asar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -eq [string] $state.patchedHash) {
        Write-Ok "Persistent in-place RTL patch is active for GPT $($official.Version)."
    } elseif ($currentHash -eq [string] $state.originalHash) {
        Write-Warn "The official ASAR is currently unpatched. Run Repair RTL."
    } else {
        Write-Warn "The GPT ASAR does not match the recorded original or patched hash."
    }
    try {
        [void] (Get-VerifiedRollbackBackup $state)
        Write-Ok "Verified rollback backup is present."
    } catch {
        Write-Warn $_.Exception.Message
    }
}

$selectedActions = @()
if ($Install) { $selectedActions += "Install" }
if ($Uninstall) { $selectedActions += "Uninstall" }
if ($Status) { $selectedActions += "Status" }
if ($Launch) { $selectedActions += "Launch" }
if ($selectedActions.Count -eq 0) { $Install = $true; $selectedActions = @("Install") }
if ($selectedActions.Count -gt 1) { throw "Choose only one action: -Install, -Uninstall, -Status, or -Launch." }

if ($Install) { Install-PersistentCodexPatch }
elseif ($Uninstall) { Uninstall-PersistentCodexPatch }
elseif ($Status) { Show-PersistentCodexStatus }
elseif ($Launch) { Start-OfficialCodex }
