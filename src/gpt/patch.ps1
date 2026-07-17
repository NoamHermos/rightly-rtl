<#
.SYNOPSIS
Applies verified Rightly RTL support to the official GPT Work / Codex app.

.DESCRIPTION
Rightly first attempts a persistent in-place rebuild of the official external
app.asar and verifies the installed hash. If Windows/MSIX keeps that file
immutable even in backup mode, Rightly leaves the package original intact and
installs a loopback-only launch-time injector instead. Neither mode copies the
application or installs a background watcher.
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
$Script:LauncherModulePath = Join-Path $Script:ModuleRoot "lib\Rightly.GptLauncher.ps1"
$Script:LauncherSourcePath = Join-Path $Script:ModuleRoot "Rightly.Gpt.Launcher.cs"
$Script:LauncherIconPath = Join-Path (Split-Path -Parent (Split-Path -Parent $Script:ModuleRoot)) "assets\rightly-gpt.ico"
$Script:StateRoot = Join-Path $env:ProgramData "Rightly\GPT"
$Script:StatePath = Join-Path $Script:StateRoot "state.json"
$Script:BackupPath = Join-Path $Script:StateRoot "backup\app.asar"
$Script:RuntimeDir = Join-Path $env:LOCALAPPDATA "Programs\Rightly\GPT"
$Script:RuntimeLauncher = Join-Path $Script:RuntimeDir "launch-gpt.ps1"
$Script:RuntimeLauncherExe = Join-Path $Script:RuntimeDir "Rightly GPT.exe"
$Script:RuntimeLauncherIcon = Join-Path $Script:RuntimeDir "Rightly GPT.ico"
$Script:RuntimeState = Join-Path $Script:RuntimeDir "state.json"
$Script:RuntimeFiles = @("codex-rtl-payload.js", "gpt-rtl-cdp.js", "launch-gpt.ps1")
$Script:LegacyRuntimeDir = $Script:RuntimeDir
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
if (-not (Test-Path -LiteralPath $Script:LauncherModulePath -PathType Leaf)) {
    throw "GPT launcher helper is missing: $($Script:LauncherModulePath)"
}
. $Script:LauncherModulePath

# Console and process helpers ------------------------------------------------
function Write-Step { param([string] $Message); Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message); Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-Info { param([string] $Message); Write-Host "  [*] $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message); Write-Host "  [!] $Message" -ForegroundColor Yellow }

function Invoke-NativeUtility {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $FailureMessage = "Native utility failed",
        [switch] $IgnoreExitCode
    )

    # Windows PowerShell 5.1 turns text written to a native program's stderr
    # into an error record. Capture it with a non-terminating preference and
    # make the actual process exit code the single source of truth.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $details = (@($output | ForEach-Object { [string] $_ }) -join " ").Trim()
        if ($details) { throw "$FailureMessage (exit code $exitCode): $details" }
        throw "$FailureMessage (exit code $exitCode)."
    }
    return $exitCode
}

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

function Stop-ProcessTree {
    param([Parameter(Mandatory)][uint32] $ProcessId)

    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }
    $taskkill = Join-Path $env:WINDIR "System32\taskkill.exe"
    [void] (Invoke-NativeUtility -FilePath $taskkill `
        -Arguments @("/PID", [string] $ProcessId, "/T", "/F") -IgnoreExitCode)

    # taskkill can return before the process object disappears. Keep the
    # PowerShell fallback so a surviving child cannot retain the ASAR handle.
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OfficialCodex {
    param([string] $AppDir)

    $processes = @(Get-OfficialCodexProcesses $AppDir)
    if ($processes.Count -eq 0) {
        Write-Info "The official GPT/Codex app is already closed."
        return
    }

    Write-Info "Force-closing every official GPT/Codex process and child process."
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $processes = @(Get-OfficialCodexProcesses $AppDir)
        if ($processes.Count -eq 0) { break }

        $officialIds = @($processes | ForEach-Object { [uint32] $_.ProcessId })
        $roots = @($processes | Where-Object {
            $officialIds -notcontains [uint32] $_.ParentProcessId
        })
        if ($roots.Count -eq 0) { $roots = $processes }
        foreach ($item in @($roots | Sort-Object ProcessId -Unique)) {
            Stop-ProcessTree -ProcessId ([uint32] $item.ProcessId)
        }

        # A crash reporter may outlive its original parent. Refresh the list
        # and terminate any such package-scoped survivor directly.
        foreach ($item in @(Get-OfficialCodexProcesses $AppDir)) {
            Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)

    $remaining = @(Get-OfficialCodexProcesses $AppDir)
    if ($remaining.Count -gt 0) {
        $ids = ($remaining | Select-Object -ExpandProperty ProcessId) -join ", "
        throw "Could not stop every official GPT/Codex process. Remaining process ids: $ids"
    }

    # Electron and Crashpad may release their final mapped-file handles shortly
    # after the processes disappear from the process table.
    Start-Sleep -Milliseconds 750
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
        Write-Info "Removed the previous launch-time GPT runtime."
    }
    Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath("Desktop")) "Rightly GPT.lnk") `
        -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Join-Path ([Environment]::GetFolderPath("Programs")) "Rightly") "Rightly GPT.lnk") `
        -Force -ErrorAction SilentlyContinue
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

function Copy-RightlyRuntimeFile {
    param([string] $Name)

    $source = Join-Path $Script:ModuleRoot $Name
    $destination = Join-Path $Script:RuntimeDir $Name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Rightly runtime source file is missing: $source"
    }
    $sourceFull = [System.IO.Path]::GetFullPath($source)
    $destinationFull = [System.IO.Path]::GetFullPath($destination)
    if (-not $sourceFull.Equals($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $sourceFull -Destination $destinationFull -Force
    }
}

function New-RightlyRuntimeShortcut {
    foreach ($shortcutPath in @(New-RightlyGptShortcuts `
        -LauncherPath $Script:RuntimeLauncherExe -WorkingDirectory $Script:RuntimeDir `
        -IconPath $Script:RuntimeLauncherIcon)) {
        Write-Ok "Created Rightly GPT shortcut: $shortcutPath"
    }
}

function Deploy-RightlyRuntimeFallback {
    $official = Get-OfficialCodexPackage
    New-Item -ItemType Directory -Path $Script:RuntimeDir -Force | Out-Null
    foreach ($name in $Script:RuntimeFiles) { Copy-RightlyRuntimeFile $name }
    Copy-Item -LiteralPath $Script:LauncherIconPath -Destination $Script:RuntimeLauncherIcon -Force
    [void] (New-RightlyGptLauncher -SourcePath $Script:LauncherSourcePath `
        -DestinationPath $Script:RuntimeLauncherExe -IconPath $Script:RuntimeLauncherIcon)
    [ordered]@{
        architecture = "loopback-cdp-runtime"
        officialPackageFullName = $official.PackageFullName
        officialPackageVersion = $official.Version
        payloadHash = (Get-FileHash -LiteralPath $Script:PayloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        installedAt = (Get-Date).ToString("o")
        reason = "The installed MSIX package rejected verified in-place ASAR replacement."
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Script:RuntimeState -Encoding UTF8
    New-RightlyRuntimeShortcut
    Write-Warn "Windows protected this Codex package from in-place changes. Installed the launch-time RTL runtime instead."
}

function Start-RightlyRuntimeCodex {
    if (-not (Test-Path -LiteralPath $Script:RuntimeLauncher -PathType Leaf)) {
        throw "Rightly's GPT runtime launcher is missing: $($Script:RuntimeLauncher)"
    }
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $process = Start-Process -FilePath $powershell -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", "`"$Script:RuntimeLauncher`""
    ) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        $runtimeLog = Join-Path $Script:RuntimeDir "logs\gpt-runtime.log"
        throw "GPT opened without a verified Rightly payload. See $runtimeLog"
    }
    Write-Ok "GPT Work / Codex RTL payload was injected and verified."
}

function Start-InstalledRightlyCodex {
    if (Test-Path -LiteralPath $Script:RuntimeState -PathType Leaf) {
        Start-RightlyRuntimeCodex
    } else {
        Start-OfficialCodex
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
function Write-AsarAccessDiagnostics {
    param([string] $Path, [string] $Stage)

    # Emitted through Write-Host so Start-Transcript captures the full picture:
    # the running identity, the file owner, its attributes, and the complete
    # ACL. When a WindowsApps write is refused, this is what pinpoints whether
    # the block is an inherited deny ACE, a missing grant, or a stale owner.
    try {
        Write-Info "---- ACL diagnostics ($Stage): $Path"
        $whoami = Join-Path $env:WINDIR "System32\whoami.exe"
        $identity = (& $whoami 2>&1) -join ""
        Write-Info "  Running as: $identity (elevated: $(Test-IsAdministrator))"

        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($item) { Write-Info "  Attributes: $($item.Attributes)" }
        else { Write-Info "  Attributes: <path not found>" }

        try {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            Write-Info "  Owner: $($acl.Owner)"
            foreach ($ace in $acl.Access) {
                $flags = @()
                if ($ace.IsInherited) { $flags += "inherited" } else { $flags += "explicit" }
                Write-Info "  ACE: $($ace.AccessControlType) $($ace.IdentityReference) [$($ace.FileSystemRights)] ($($flags -join ','))"
            }
        } catch {
            Write-Info "  Get-Acl failed: $($_.Exception.Message)"
        }
    } catch { }
}

function Grant-AsarWriteAccess {
    param([string] $AsarPath)
    if (-not (Test-IsAdministrator)) { throw "Administrator rights are required to patch the official GPT ASAR." }

    $resourcesDir = Split-Path -Parent $AsarPath
    $takeown = Join-Path $env:WINDIR "System32\takeown.exe"
    $icacls = Join-Path $env:WINDIR "System32\icacls.exe"
    $attrib = Join-Path $env:WINDIR "System32\attrib.exe"
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    Write-AsarAccessDiagnostics -Path $resourcesDir -Stage "resources folder before grant"
    Write-AsarAccessDiagnostics -Path $AsarPath -Stage "before grant"

    # Newer WindowsApps packages enforce the parent directory ACL in addition
    # to the target file ACL. Own both objects (scope stays limited to resources
    # and app.asar, never the package) so their DACLs become authoritative.
    [void] (Invoke-NativeUtility -FilePath $takeown -Arguments @("/F", $resourcesDir, "/A") `
        -FailureMessage "Could not take ownership of the official GPT resources folder")
    [void] (Invoke-NativeUtility -FilePath $takeown -Arguments @("/F", $AsarPath, "/A") `
        -FailureMessage "Could not take ownership of the official GPT ASAR")

    # On Windows 11's protected WindowsApps tree the block is usually an
    # inherited deny ACE that flows down from a package/parent folder. A grant
    # cannot override an inherited deny, and /remove:d cannot delete an inherited
    # ACE from the child, so detach inheritance on app.asar first (this drops the
    # inherited deny), then write explicit full-control ACEs. SYSTEM and ALL
    # APPLICATION PACKAGES keep read access so the packaged app still loads.
    [void] (Invoke-NativeUtility -FilePath $icacls `
        -Arguments @($AsarPath, "/inheritance:r") -IgnoreExitCode)
    [void] (Invoke-NativeUtility -FilePath $icacls `
        -Arguments @($AsarPath, "/remove:d", '*S-1-5-32-544', "*$userSid") -IgnoreExitCode)
    [void] (Invoke-NativeUtility -FilePath $icacls `
        -Arguments @($AsarPath, "/grant", '*S-1-5-32-544:(F)', "*$userSid`:(F)", '*S-1-5-18:(F)', '*S-1-15-2-1:(RX)') `
        -FailureMessage "Could not grant write access to the official GPT ASAR")

    # The parent directory is included because backup-mode replacement still
    # needs to traverse the complete destination path.
    [void] (Invoke-NativeUtility -FilePath $icacls `
        -Arguments @($resourcesDir, "/grant", '*S-1-5-32-544:(F)', "*$userSid`:(F)") `
        -FailureMessage "Could not grant write access to the official GPT resources folder")
    [void] (Invoke-NativeUtility -FilePath $icacls `
        -Arguments @($resourcesDir, "/remove:d", '*S-1-5-32-544', "*$userSid") -IgnoreExitCode)

    # WindowsApps stages app.asar with the read-only (and sometimes system)
    # attribute set. Opening a read-only file for write returns an access-denied
    # error even after ownership and ACLs are corrected, so clear the attributes
    # explicitly before the replacement. attrib is used as the authoritative
    # path because a swallowed Set-ItemProperty failure previously left the
    # read-only bit in place.
    [void] (Invoke-NativeUtility -FilePath $attrib `
        -Arguments @("-R", "-S", "-H", $AsarPath) -IgnoreExitCode)
    try {
        Set-ItemProperty -LiteralPath $AsarPath -Name IsReadOnly -Value $false -ErrorAction Stop
    } catch { }

    Write-AsarAccessDiagnostics -Path $resourcesDir -Stage "resources folder after grant"
    Write-AsarAccessDiagnostics -Path $AsarPath -Stage "after grant"
}

function Test-IsAccessDeniedException {
    param($Exception)

    # PowerShell wraps a .NET method failure in a MethodInvocationException, so
    # the real UnauthorizedAccessException lives further down the InnerException
    # chain. Walk the whole chain and also match the Win32 access-denied HResult
    # (0x80070005) so the caller reliably recognises an ACL/attribute refusal.
    $probe = $Exception
    while ($probe) {
        if ($probe -is [System.UnauthorizedAccessException]) { return $true }
        if ($probe.HResult -eq -2147024891) { return $true }
        $probe = $probe.InnerException
    }
    return $false
}

function Test-IsUnsupportedAsarReplacement {
    param($Exception)

    $probe = $Exception
    while ($probe) {
        if ($probe -is [System.NotSupportedException]) { return $true }
        $probe = $probe.InnerException
    }
    return $false
}

function Assert-AsarCanBeReplaced {
    param([string] $AsarPath)

    # Returns "InPlace" when an exclusive read/write handle is available (the
    # fast path that overwrites the file directly). Returns "Backup" when the
    # only obstacle is an access-denied condition with no official process
    # holding the file. The caller then uses robocopy's backup mode rather than
    # assuming a same-directory rename can bypass WindowsApps protection.
    # Throws only when a live GPT/Codex process keeps re-locking the ASAR.
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $stream = $null
        $lastException = $null
        try {
            $stream = [System.IO.File]::Open(
                $AsarPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            return "InPlace"
        } catch {
            $lastException = $_.Exception
        } finally {
            if ($stream) { $stream.Dispose() }
        }

        # If Windows restarted a package process during the hand-off, terminate
        # it again and keep polling until the ASAR handle is actually released.
        $officialBusy = $false
        try {
            $official = Get-OfficialCodexPackage
            if (@(Get-OfficialCodexProcesses $official.AppDir).Count -gt 0) {
                Stop-OfficialCodex $official.AppDir
                $officialBusy = $true
            }
        } catch { }

        # Access denied without any surviving official process is a permission
        # or WindowsApps protection state, not a live lock. Stop polling and let
        # the caller retry with SeBackupPrivilege/SeRestorePrivilege semantics.
        if (-not $officialBusy -and (Test-IsAccessDeniedException $lastException)) {
            return "Backup"
        }
        Start-Sleep -Milliseconds 350
    } while ((Get-Date) -lt $deadline)

    $processHint = ""
    try {
        $official = Get-OfficialCodexPackage
        $processes = @(Get-OfficialCodexProcesses $official.AppDir)
        if ($processes.Count -gt 0) {
            $ids = ($processes | Select-Object -ExpandProperty ProcessId) -join ", "
            $processHint = " Remaining GPT/Codex process ids: $ids."
        }
    } catch { }
    $lastError = if ($lastException) { $lastException.Message } else { "unknown error" }
    throw "Rightly force-closed GPT/Codex and prepared the WindowsApps permissions, but still could not obtain exclusive write access to GPT's app.asar.$processHint Original error: $lastError"
}

function Copy-AsarWithBackupMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    $robocopy = Join-Path $env:WINDIR "System32\robocopy.exe"
    if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
        throw "robocopy.exe is unavailable."
    }

    $stageDir = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("rightly-robocopy-" + [guid]::NewGuid().ToString("N"))
    $fileName = [System.IO.Path]::GetFileName($Destination)
    $destinationDir = [System.IO.Path]::GetDirectoryName($Destination)
    $stagedFile = Join-Path $stageDir $fileName

    try {
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        [System.IO.File]::Copy($Source, $stagedFile, $true)

        $output = @()
        $exitCode = $null
        $previousPreference = $ErrorActionPreference
        try {
            # Windows PowerShell 5.1 converts native stderr into error records.
            # Robocopy exit codes 0-7 are success states; 8+ are real failures.
            $ErrorActionPreference = "Continue"
            $output = @(& $robocopy `
                $stageDir `
                $destinationDir `
                $fileName `
                "/B" `
                "/COPY:DAT" `
                "/R:1" `
                "/W:1" `
                "/IS" `
                "/IT" `
                "/NFL" `
                "/NDL" `
                "/NJH" `
                "/NJS" `
                "/NP" 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($null -eq $exitCode -or $exitCode -ge 8) {
            $details = (@($output | ForEach-Object { [string] $_ }) -join " ").Trim()
            throw [System.NotSupportedException]::new(
                "Backup-mode ASAR replacement failed with robocopy exit code $exitCode. $details")
        }
    } finally {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-VerifiedAsar {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $ExpectedHash
    )

    $currentHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -eq $ExpectedHash) { return $currentHash }

    Grant-AsarWriteAccess $Destination
    $replacementMode = Assert-AsarCanBeReplaced $Destination

    if ($replacementMode -eq "InPlace") {
        try {
            [System.IO.File]::Copy($Source, $Destination, $true)
        } catch {
            if (-not (Test-IsAccessDeniedException $_.Exception)) { throw }
            Write-Warn "Direct ASAR overwrite was denied; retrying in backup mode."
            Copy-AsarWithBackupMode -Source $Source -Destination $Destination
        }
    } else {
        Write-Info "Using backup-mode ASAR replacement."
        Copy-AsarWithBackupMode -Source $Source -Destination $Destination
    }
    $installedHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -ne $ExpectedHash) {
        throw [System.NotSupportedException]::new(
            "Windows reported a successful ASAR copy, but the installed SHA-256 hash did not change.")
    }
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
    $runtimeFallback = $false

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
        $installFailure = $_
        if (Test-Path -LiteralPath $Script:BackupPath) {
            try {
                $backupHash = (Get-FileHash -LiteralPath $Script:BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $failedInstallHash = (Get-FileHash -LiteralPath $official.Asar -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($failedInstallHash -ne $backupHash) {
                    Copy-VerifiedAsar -Source $Script:BackupPath -Destination $official.Asar -ExpectedHash $backupHash | Out-Null
                    Write-Warn "The original GPT ASAR was restored after the failed patch."
                } else {
                    Write-Info "The official GPT ASAR remained original after the rejected replacement."
                }
            } catch { }
        }

        if (-not (Test-IsUnsupportedAsarReplacement $installFailure.Exception)) {
            throw $installFailure
        }

        $currentHash = (Get-FileHash -LiteralPath $official.Asar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -ne $originalHash) {
            throw "The official GPT ASAR could not be restored after Windows rejected replacement."
        }
        Remove-ManagedDirectory $Script:StateRoot
        Deploy-RightlyRuntimeFallback
        $runtimeFallback = $true
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($NoLaunch) { Write-Info "Launch deferred to the unified installer." }
    elseif ($runtimeFallback) { Start-RightlyRuntimeCodex }
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
    if (-not $state -and (Test-Path -LiteralPath $Script:RuntimeState -PathType Leaf)) {
        $runtime = Get-Content -LiteralPath $Script:RuntimeState -Raw | ConvertFrom-Json
        Write-Ok "Launch-time RTL runtime is installed for GPT $($runtime.officialPackageVersion)."
        Write-Info "Use the 'Rightly GPT' desktop shortcut so the payload can be injected and verified."
        return
    }
    if (-not $state) { Write-Warn "No Rightly GPT installation state was found."; return }
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
elseif ($Launch) { Start-InstalledRightlyCodex }
