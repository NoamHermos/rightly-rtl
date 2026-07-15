<#
Launches the official GPT Work / Codex package with a loopback-only Chromium
debugging endpoint, then starts the lightweight Rightly runtime injector.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:PayloadPath = Join-Path $Script:Root "codex-rtl-payload.js"
$Script:InjectorPath = Join-Path $Script:Root "gpt-rtl-cdp.js"
$Script:LogDir = Join-Path $Script:Root "logs"
$Script:LogPath = Join-Path $Script:LogDir "gpt-runtime.log"
$Script:LegacyAppDirs = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Codex-RT-AI")
    (Join-Path $env:LOCALAPPDATA "Programs\Rightly-GPT-Embedded")
)

function Write-RightlyLog {
    param([string] $Message)
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    Add-Content -LiteralPath $Script:LogPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}

function Show-RightlyError {
    param([string] $Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "$Message`r`n`r`nLog: $($Script:LogPath)",
            "Rightly GPT",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch { }
}

function Get-OfficialCodexPackage {
    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) { throw "The official GPT Work / Codex app is not installed." }
    $appDir = Join-Path $package.InstallLocation "app"
    $exe = Join-Path $appDir "ChatGPT.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "Official ChatGPT.exe was not found at $exe" }
    return [pscustomobject]@{
        AppDir = [System.IO.Path]::GetFullPath($appDir)
        Exe = [System.IO.Path]::GetFullPath($exe)
        AppUserModelId = "$($package.PackageFamilyName)!App"
    }
}

function Get-OfficialCodexProcesses {
    param([string] $AppDir)
    $prefix = [System.IO.Path]::GetFullPath($AppDir).TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-OfficialCodex {
    param([string] $AppDir)
    $processes = @(Get-OfficialCodexProcesses $AppDir)
    $main = $processes | Where-Object { $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type=" } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-OfficialCodexProcesses $AppDir).Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    foreach ($item in @(Get-OfficialCodexProcesses $AppDir)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
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

function Stop-LegacyCopiedCodex {
    $processes = @(Get-ProcessesUnderPaths $Script:LegacyAppDirs)
    $main = $processes | Where-Object {
        $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type="
    } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(8)
        while (@(Get-ProcessesUnderPaths $Script:LegacyAppDirs).Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    foreach ($item in @(Get-ProcessesUnderPaths $Script:LegacyAppDirs)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Quote-NativeArgument {
    param([string] $Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Stop-StaleRightlyInjectors {
    $injectorFullPath = [System.IO.Path]::GetFullPath($Script:InjectorPath)
    foreach ($item in @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue)) {
        if ($item.CommandLine -and $item.CommandLine.IndexOf($injectorFullPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
            Write-RightlyLog "Stopped stale Rightly injector PID $($item.ProcessId)"
        }
    }
}

function Start-Injector {
    param([int] $Port)
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { throw "Node.js LTS is required to run Rightly." }
    foreach ($path in @($Script:PayloadPath, $Script:InjectorPath)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Rightly runtime file is missing: $path" }
    }
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    $arguments = @(
        (Quote-NativeArgument $Script:InjectorPath),
        "--port", [string]$Port,
        "--payload", (Quote-NativeArgument $Script:PayloadPath),
        "--log", (Quote-NativeArgument $Script:LogPath),
        "--injection-window-ms", "20000"
    ) -join " "
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $node.Source
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $process) { throw "Could not start the Rightly runtime injector." }
    return $process
}

function Start-PackagedCodex {
    param([string] $AppUserModelId, [string] $Arguments)
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
    public static uint Start(string appUserModelId, string arguments) {
        var manager = (IRightlyApplicationActivationManager)new RightlyApplicationActivationManager();
        uint processId;
        int result = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);
        if (result < 0) Marshal.ThrowExceptionForHR(result);
        return processId;
    }
}
'@
    }
    return [RightlyCodexActivation]::Start($AppUserModelId, $Arguments)
}

try {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    Set-Content -LiteralPath $Script:LogPath -Value "$(Get-Date -Format o) Starting Rightly GPT runtime" -Encoding UTF8
    $official = Get-OfficialCodexPackage
    Stop-LegacyCopiedCodex
    Stop-OfficialCodex $official.AppDir
    Stop-StaleRightlyInjectors
    $port = Get-FreeLoopbackPort
    $injector = Start-Injector $port
    $arguments = "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$port --force-ui-direction=ltr"
    $launchedProcessId = Start-PackagedCodex -AppUserModelId $official.AppUserModelId -Arguments $arguments
    Write-RightlyLog "Launched official GPT PID $launchedProcessId with loopback DevTools port $port; injector PID $($injector.Id)"
} catch {
    Write-RightlyLog "FATAL $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    Show-RightlyError $_.Exception.Message
    exit 1
}
