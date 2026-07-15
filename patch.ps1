<#
Rightly GPT Work / Codex RTL runtime installer for Windows.

The official OpenAI package remains untouched. Rightly starts the official
ChatGPT.exe with a loopback-only Chromium DevTools endpoint and injects the RTL
payload into memory during application startup. This works with MSIX package
integrity and avoids creating or rebuilding an application copy.
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
$Script:RuntimeDir = Join-Path $env:LOCALAPPDATA "Programs\Rightly\GPT"
$Script:RuntimeLauncher = Join-Path $Script:RuntimeDir "launch-gpt.ps1"
$Script:RuntimeState = Join-Path $Script:RuntimeDir "state.json"
$Script:LegacyStateDir = Join-Path $env:ProgramData "GptwRtlPatch"
$Script:LegacyModificationName = "RT.AI.Codex.RTL.Modification"
$Script:LegacyCertificateFriendlyName = "RT-AI GPTW RTL Modification"
$Script:LegacyTaskNames = @("Codex RT-AI RTL Auto-Update")
$Script:LegacyCopyDirs = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Codex-RT-AI")
    (Join-Path $env:LOCALAPPDATA "Programs\Codex-RT-AI-patcher")
    (Join-Path $env:LOCALAPPDATA "Programs\Rightly-GPT-Embedded")
)
$Script:RuntimeFiles = @("codex-rtl-payload.js", "gpt-rtl-cdp.js", "launch-gpt.ps1")

# Console and elevation -------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [+] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [*] $Message" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator
    )
}

function Invoke-ElevatedIfNeeded {
    param([ValidateSet("Install", "Uninstall")][string]$Action)
    if (Test-IsAdministrator) { return $false }
    if ($Elevated) { throw "Administrator rights were requested but were not granted." }
    if (-not $PSCommandPath) { throw "Cannot elevate because the patcher has no file path." }

    Write-Step "Requesting administrator rights for one-time legacy cleanup"
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    # The elevated child never launches GPT. The original medium-integrity
    # process launches it after cleanup has completed.
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -$Action -Elevated -NoLaunch"
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "The elevated Rightly $Action process exited with code $($process.ExitCode)." }
    return $true
}

# Official package and process management -----------------------------------
function Get-OfficialCodexPackage {
    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) { throw "The official GPT Work / Codex app is not installed." }
    $appDir = Join-Path $package.InstallLocation "app"
    $exe = Join-Path $appDir "ChatGPT.exe"
    $asar = Join-Path $appDir "resources\app.asar"
    foreach ($path in @($exe, $asar)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "The official GPT file is missing: $path" }
    }
    return [pscustomobject]@{
        Package = $package
        AppDir = [System.IO.Path]::GetFullPath($appDir)
        Exe = [System.IO.Path]::GetFullPath($exe)
        Asar = [System.IO.Path]::GetFullPath($asar)
    }
}

function Get-OfficialCodexProcesses {
    $official = Get-OfficialCodexPackage
    $prefix = $official.AppDir.TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-OfficialCodex {
    $processes = @(Get-OfficialCodexProcesses)
    $main = $processes | Where-Object { $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type=" } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
        Start-Sleep -Seconds 3
    }
    foreach ($item in @(Get-OfficialCodexProcesses)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ExactManagedPath {
    param([string]$Path, [string[]]$AllowedPaths)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowed = @($AllowedPaths | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') })
    if (-not ($allowed | Where-Object { $full.Equals($_, [System.StringComparison]::OrdinalIgnoreCase) })) {
        throw "Refusing to remove unmanaged path: $full"
    }
    return $full
}

function Remove-ManagedDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $allowedPaths = @($Script:RuntimeDir, $Script:LegacyStateDir) + @($Script:LegacyCopyDirs)
    $full = Assert-ExactManagedPath -Path $Path -AllowedPaths $allowedPaths
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Get-ProcessesUnderPaths {
    param([string[]]$Paths)
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

function Stop-LegacyCopiedApps {
    $processes = @(Get-ProcessesUnderPaths $Script:LegacyCopyDirs)
    $main = $processes | Where-Object {
        $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type="
    } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(8)
        while (@(Get-ProcessesUnderPaths $Script:LegacyCopyDirs).Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    foreach ($item in @(Get-ProcessesUnderPaths $Script:LegacyCopyDirs)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Migration cleanup ----------------------------------------------------------
function Remove-LegacyCopyShortcuts {
    $prefixes = @($Script:LegacyCopyDirs | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
    })
    $shell = New-Object -ComObject WScript.Shell
    $shortcutFolders = @(
        [Environment]::GetFolderPath("Desktop")
        [Environment]::GetFolderPath("Programs")
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar")
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\StartMenu")
    )
    foreach ($folder in $shortcutFolders) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter "*.lnk" -Force -ErrorAction SilentlyContinue)) {
            $shortcut = $shell.CreateShortcut($file.FullName)
            $combined = ([string]$shortcut.TargetPath) + " " + ([string]$shortcut.Arguments)
            $isLegacy = @($prefixes | Where-Object {
                $combined.IndexOf($_.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -gt 0
            if ($isLegacy) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Info "Removed copied-app shortcut: $($file.FullName)"
            }
        }
    }
}

function Remove-LegacyCopiedApps {
    Stop-LegacyCopiedApps
    Remove-LegacyCopyShortcuts
    foreach ($path in $Script:LegacyCopyDirs) {
        if (Test-Path -LiteralPath $path) {
            Remove-ManagedDirectory $path
            Write-Info "Removed copied GPT build: $path"
        }
    }
}

function Remove-LegacyAutomaticPatching {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return }
    foreach ($name in $Script:LegacyTaskNames) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            Write-Info "Removed legacy automatic task: $name"
        }
    }
}

function Remove-LegacyModificationPackage {
    $packages = @(Get-AppxPackage -Name $Script:LegacyModificationName -PackageTypeFilter Optional -ErrorAction SilentlyContinue)
    if ($packages.Count -gt 0) {
        Stop-OfficialCodex
        foreach ($package in $packages) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            Write-Info "Removed ineffective legacy MSIX overlay: $($package.PackageFullName)"
        }
    }
    Remove-ManagedDirectory $Script:LegacyStateDir

    foreach ($storePath in @(
        "Cert:\CurrentUser\My",
        "Cert:\CurrentUser\Root",
        "Cert:\CurrentUser\TrustedPeople",
        "Cert:\LocalMachine\Root",
        "Cert:\LocalMachine\TrustedPeople"
    )) {
        Get-ChildItem $storePath -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -eq $Script:LegacyCertificateFriendlyName } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.PSPath -Force -ErrorAction Stop
                Write-Info "Removed obsolete Rightly signing certificate from $storePath"
            }
    }
}

# Runtime deployment ---------------------------------------------------------
function Copy-RuntimeFile {
    param([string]$Name)
    $source = Join-Path $Script:ModuleRoot $Name
    $destination = Join-Path $Script:RuntimeDir $Name
    if (-not (Test-Path -LiteralPath $source)) { throw "Rightly source file is missing: $source" }
    $sourceFull = [System.IO.Path]::GetFullPath($source)
    $destinationFull = [System.IO.Path]::GetFullPath($destination)
    if (-not $sourceFull.Equals($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $sourceFull -Destination $destinationFull -Force
    }
}

function Deploy-RightlyRuntime {
    $official = Get-OfficialCodexPackage
    New-Item -ItemType Directory -Path $Script:RuntimeDir -Force | Out-Null
    foreach ($name in $Script:RuntimeFiles) { Copy-RuntimeFile $name }
    [ordered]@{
        architecture = "loopback-cdp-runtime"
        officialPackageFullName = $official.Package.PackageFullName
        officialPackageVersion = [string]$official.Package.Version
        installedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $Script:RuntimeState -Encoding UTF8
    Write-Ok "Installed lightweight Rightly runtime at $($Script:RuntimeDir)"
}

function Start-RightlyCodex {
    if (-not (Test-Path -LiteralPath $Script:RuntimeLauncher)) { Deploy-RightlyRuntime }
    $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $process = Start-Process -FilePath $powershell -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", "`"$Script:RuntimeLauncher`""
    ) -PassThru
    Write-Ok "Starting the official GPT app with Rightly (launcher PID $($process.Id))."
}

# Public actions -------------------------------------------------------------
function Install-RightlyRuntime {
    if (Invoke-ElevatedIfNeeded "Install") {
        if (-not $NoLaunch) { Start-RightlyCodex }
        return
    }
    Write-Step "Removing the ineffective MSIX overlay and its large build cache"
    Remove-LegacyAutomaticPatching
    Remove-LegacyModificationPackage
    Write-Step "Removing obsolete copied GPT builds"
    Remove-LegacyCopiedApps
    Write-Step "Installing the lightweight in-memory Rightly runtime"
    Deploy-RightlyRuntime
    if ($NoLaunch) { Write-Info "Launch deferred to the unified installer." }
    else { Start-RightlyCodex }
}

function Uninstall-RightlyRuntime {
    if (Invoke-ElevatedIfNeeded "Uninstall") { return }
    Stop-OfficialCodex
    Remove-LegacyAutomaticPatching
    Remove-LegacyModificationPackage
    Remove-LegacyCopiedApps
    Remove-ManagedDirectory $Script:RuntimeDir
    foreach ($name in @("Repair GPT RTL.lnk", "Rightly GPT.lnk")) {
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath("Desktop")) $name) -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "Rightly was removed. The official OpenAI app remains installed and untouched."
}

function Show-RightlyStatus {
    $official = Get-OfficialCodexPackage
    $runtimeProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ieq "node.exe" -and $_.CommandLine -match "gpt-rtl-cdp\.js"
    })
    Write-Host ""
    Write-Host "Rightly for GPT Work / Codex - Status" -ForegroundColor Cyan
    Write-Info "Official package: $($official.Package.PackageFullName)"
    if (Test-Path -LiteralPath $Script:RuntimeState) { Write-Ok "Runtime installed: $($Script:RuntimeDir)" }
    else { Write-Warn "Rightly runtime is not installed." }
    if ($runtimeProcesses.Count -gt 0) { Write-Ok "In-memory injector is running (PID $($runtimeProcesses[0].ProcessId))." }
    else { Write-Warn "GPT is not currently running through the Rightly shortcut." }
    $legacy = @(Get-AppxPackage -Name $Script:LegacyModificationName -PackageTypeFilter Optional -ErrorAction SilentlyContinue)
    if ($legacy.Count -eq 0) { Write-Ok "No legacy MSIX overlay is installed." }
    else { Write-Warn "The legacy MSIX overlay is still installed." }
    $copies = @($Script:LegacyCopyDirs | Where-Object { Test-Path -LiteralPath $_ })
    if ($copies.Count -eq 0) { Write-Ok "No copied GPT installations exist." }
    else { Write-Warn "Copied GPT installations still exist: $($copies -join ', ')" }
}

$selectedActions = @()
if ($Install) { $selectedActions += "Install" }
if ($Uninstall) { $selectedActions += "Uninstall" }
if ($Status) { $selectedActions += "Status" }
if ($Launch) { $selectedActions += "Launch" }
if ($selectedActions.Count -eq 0) { $Install = $true; $selectedActions = @("Install") }
if ($selectedActions.Count -gt 1) { throw "Choose only one action: -Install, -Uninstall, -Status, or -Launch." }

if ($Install) { Install-RightlyRuntime }
elseif ($Uninstall) { Uninstall-RightlyRuntime }
elseif ($Status) { Show-RightlyStatus }
elseif ($Launch) { Start-RightlyCodex }
