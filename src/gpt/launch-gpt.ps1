<#
Launches the official GPT Work / Codex package with a loopback-only Chromium
debugging endpoint, then starts the lightweight Rightly runtime injector.
#>

[CmdletBinding()]
param([string] $StatusFile)

$ErrorActionPreference = "Stop"
$Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:PayloadPath = Join-Path $Script:Root "codex-rtl-payload.js"
$Script:InjectorPath = Join-Path $Script:Root "gpt-rtl-cdp.js"
$Script:LogDir = Join-Path $Script:Root "logs"
$Script:LogPath = Join-Path $Script:LogDir "gpt-runtime.log"
$Script:ResultPath = Join-Path $Script:LogDir "gpt-startup-result.json"

function Write-RightlyLog {
    param([string] $Message)
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    Add-Content -LiteralPath $Script:LogPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}

function Set-RightlyStatus {
    param([string] $Code, [string] $Message)
    if (-not $StatusFile) { return }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $StatusFile) -Force | Out-Null
        Set-Content -LiteralPath $StatusFile -Value @($Code, $Message) -Encoding UTF8
    } catch { }
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
        AppUserModelId = "$($package.PackageFamilyName)!App"
    }
}

function Get-OfficialCodexProcesses {
    param([string] $AppDir)
    $prefix = [System.IO.Path]::GetFullPath($AppDir).TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith(
            $prefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-MainOfficialCodexProcess {
    param([string] $AppDir)
    return @(Get-OfficialCodexProcesses $AppDir | Where-Object {
        $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type="
    } | Select-Object -First 1)
}

function Stop-OfficialCodex {
    param([string] $AppDir)
    $processes = @(Get-OfficialCodexProcesses $AppDir)
    $main = $processes | Where-Object {
        $_.Name -ieq "ChatGPT.exe" -and $_.CommandLine -notmatch "--type="
    } | Select-Object -First 1
    if ($main) {
        $process = Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue
        if ($process) { [void]$process.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(8)
        while (@(Get-OfficialCodexProcesses $AppDir).Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    foreach ($item in @(Get-OfficialCodexProcesses $AppDir)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Get-FreeLoopbackPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port
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
        if ($item.CommandLine -and $item.CommandLine.IndexOf(
                $injectorFullPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
            Write-RightlyLog "Stopped stale Rightly injector PID $($item.ProcessId)"
        }
    }
}

function Start-Injector {
    param(
        [int] $Port,
        [string] $ResultPath = $Script:ResultPath,
        [switch] $VerifyOnly
    )
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { throw "Node.js LTS is required to run Rightly." }
    foreach ($path in @($Script:PayloadPath, $Script:InjectorPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Rightly runtime file is missing: $path"
        }
    }

    $arguments = @(
        (Quote-NativeArgument $Script:InjectorPath),
        "--port", [string] $Port,
        "--payload", (Quote-NativeArgument $Script:PayloadPath),
        "--log", (Quote-NativeArgument $Script:LogPath),
        "--result", (Quote-NativeArgument $ResultPath),
        "--injection-window-ms", $(if ($VerifyOnly) { "5000" } else { "20000" })
    ) -join " "
    if ($VerifyOnly) { $arguments += " --verify-only true" }
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

function Get-RightlyDebugPort {
    param($Process)
    if (-not $Process -or -not $Process.CommandLine) { return $null }
    if ($Process.CommandLine -match '(?:^|\s)--remote-debugging-port(?:=|\s+)(\d+)(?:\s|$)') {
        return [int] $Matches[1]
    }
    return $null
}

function Test-RunningRightlyHost {
    param($Process)
    if (-not $Process -or -not $Process.CommandLine) { return $false }
    return $null -ne (Get-RightlyDebugPort $Process) -and
        $Process.CommandLine -match '(?:^|\s)--remote-debugging-address=127\.0\.0\.1(?:\s|$)' -and
        $Process.CommandLine -match '(?:^|\s)--force-ui-direction=ltr(?:\s|$)'
}

function Test-OfficialCodexHasVisibleWindow {
    param($MainProcess)
    $process = Get-Process -Id $MainProcess.ProcessId -ErrorAction SilentlyContinue
    return $null -ne $process -and $process.MainWindowHandle -ne [IntPtr]::Zero
}

function Test-RunningRightlyPayload {
    param($MainProcess)

    $port = Get-RightlyDebugPort $MainProcess
    if (-not $port) {
        Write-RightlyLog "Running GPT PID $($MainProcess.ProcessId) has no Rightly DevTools port"
        return $false
    }

    $verificationResult = Join-Path $Script:LogDir ("gpt-running-result-{0}.json" -f [guid]::NewGuid().ToString("N"))
    $verifier = $null
    try {
        $verifier = Start-Injector -Port $port -ResultPath $verificationResult -VerifyOnly
        $deadline = (Get-Date).AddSeconds(8)
        do {
            if (Test-Path -LiteralPath $verificationResult -PathType Leaf) {
                try {
                    $result = Get-Content -LiteralPath $verificationResult -Raw | ConvertFrom-Json
                    return $result.status -eq "success"
                } catch { }
            }
            if ($verifier.HasExited) { break }
            Start-Sleep -Milliseconds 150
        } while ((Get-Date) -lt $deadline)
        return $false
    } finally {
        if ($verifier -and -not $verifier.HasExited) {
            Stop-Process -Id $verifier.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $verificationResult -Force -ErrorAction SilentlyContinue
    }
}

function Focus-OfficialCodex {
    param($MainProcess, $Official)
    try {
        if (-not ("RightlyWindowActivation" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RightlyWindowActivation {
    private const int SW_RESTORE = 9;
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    public static bool Restore(uint processId) {
        IntPtr match = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId && IsWindowVisible(window)) {
                match = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        if (match == IntPtr.Zero) return false;
        ShowWindowAsync(match, SW_RESTORE);
        SetForegroundWindow(match);
        return true;
    }
}
'@
        }

        if ([RightlyWindowActivation]::Restore([uint32] $MainProcess.ProcessId)) {
            Write-RightlyLog "Restored and focused the existing GPT window for PID $($MainProcess.ProcessId)"
            return
        }

        # Closing GPT's last window can leave the corrected Electron process in
        # the notification area. Activating the official package asks that same
        # process to create a new window without restarting or reinjecting it.
        Set-RightlyStatus "opening" "Rightly is active in the background. Opening a new GPT window."
        $activationProcessId = Start-PackagedCodex -AppUserModelId $Official.AppUserModelId -Arguments ""
        Write-RightlyLog "Requested a window from the background GPT instance through package activation PID $activationProcessId"

        $deadline = (Get-Date).AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 200
            $currentMain = @(Get-MainOfficialCodexProcess $Official.AppDir) | Select-Object -First 1
            if ($currentMain -and [RightlyWindowActivation]::Restore([uint32] $currentMain.ProcessId)) {
                Write-RightlyLog "Opened and focused a window from the corrected background GPT process"
                return
            }
        } while ((Get-Date) -lt $deadline)

        # Keep AppActivate as a final compatibility fallback when Electron
        # creates the window under a short-lived activation process.
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.AppActivate([int] $activationProcessId)) {
            Write-RightlyLog "Focused the package activation process through the compatibility fallback"
            return
        }
        throw "GPT is corrected and running in the background, but Windows did not open its window."
    } catch {
        Write-RightlyLog "Could not restore the existing GPT window: $($_.Exception.Message)"
        throw
    }
}

function Wait-InjectorVerification {
    param([System.Diagnostics.Process] $Injector)

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Script:ResultPath -PathType Leaf) {
            $result = $null
            try { $result = Get-Content -LiteralPath $Script:ResultPath -Raw | ConvertFrom-Json }
            catch { }
            if ($result) {
                if ($result.status -eq "success") {
                    Write-RightlyLog "GPT payload verification confirmed: $($result.message)"
                    return
                }
                if ($result.status -eq "failure") {
                    throw "GPT RTL injection failed: $($result.message)"
                }
            }
        }
        if ($Injector.HasExited -and $Injector.ExitCode -ne 0) {
            throw "The GPT RTL injector exited with code $($Injector.ExitCode) before verification."
        }
        Start-Sleep -Milliseconds 250
    }
    throw "GPT opened, but the Rightly payload marker was not verified within 60 seconds."
}

function Start-PackagedCodex {
    param([string] $AppUserModelId, [string] $Arguments)
    if (-not ("RightlyRuntimeActivation" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IRightlyRuntimeActivationManager {
    int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    int ActivateForFile(IntPtr appUserModelId, IntPtr itemArray, IntPtr verb, out uint processId);
    int ActivateForProtocol(IntPtr appUserModelId, IntPtr itemArray, out uint processId);
}
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
class RightlyRuntimeActivationManager { }
public static class RightlyRuntimeActivation {
    public static uint Start(string appUserModelId, string arguments) {
        var manager = (IRightlyRuntimeActivationManager)new RightlyRuntimeActivationManager();
        uint processId;
        int result = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);
        if (result < 0) Marshal.ThrowExceptionForHR(result);
        return processId;
    }
}
'@
    }
    return [RightlyRuntimeActivation]::Start($AppUserModelId, $Arguments)
}

$injector = $null
try {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    Set-Content -LiteralPath $Script:LogPath `
        -Value "$(Get-Date -Format o) Starting Rightly GPT runtime" -Encoding UTF8
    Set-RightlyStatus "checking" "Checking whether GPT is already open with a verified Rightly correction."
    Remove-Item -LiteralPath $Script:ResultPath -Force -ErrorAction SilentlyContinue
    $official = Get-OfficialCodexPackage
    $runningMain = @(Get-MainOfficialCodexProcess $official.AppDir) | Select-Object -First 1
    $runningHasWindow = $runningMain -and (Test-OfficialCodexHasVisibleWindow $runningMain)
    $runningIsRightlyHost = $runningMain -and (Test-RunningRightlyHost $runningMain)
    $runningPayloadVerified = $runningMain -and (Test-RunningRightlyPayload $runningMain)

    if ($runningPayloadVerified -and $runningHasWindow) {
        Write-RightlyLog "GPT PID $($runningMain.ProcessId) is already open with a verified Rightly payload; leaving it running"
        Set-RightlyStatus "ready" "GPT is already running with Rightly. Opening or restoring its window."
        Focus-OfficialCodex -MainProcess $runningMain -Official $official
        exit 0
    }

    if ($runningMain -and -not $runningHasWindow -and $runningIsRightlyHost) {
        $port = Get-RightlyDebugPort $runningMain
        Write-RightlyLog "GPT PID $($runningMain.ProcessId) is a Rightly host running without a visible window; preserving the process"
        Set-RightlyStatus "opening" "Rightly is active in the background. Opening a new GPT window without restarting it."
        Stop-StaleRightlyInjectors
        $injector = Start-Injector $port
        $activationProcessId = Start-PackagedCodex -AppUserModelId $official.AppUserModelId -Arguments ""
        Write-RightlyLog "Requested a new window from background GPT PID $($runningMain.ProcessId); activation PID $activationProcessId; injector PID $($injector.Id)"
        Set-RightlyStatus "injecting" "Applying Rightly to the new window and verifying its live renderer."
        Wait-InjectorVerification $injector
        Focus-OfficialCodex -MainProcess $runningMain -Official $official
        Write-RightlyLog "Background GPT window opened with a verified Rightly payload; original PID preserved"
        Set-RightlyStatus "ready" "GPT is open with a verified Rightly correction."
        exit 0
    }

    if ($runningMain) {
        Write-RightlyLog "GPT PID $($runningMain.ProcessId) is open without a verified Rightly payload; restarting it"
        Set-RightlyStatus "restarting" "GPT is open without a verified correction, so Rightly will restart it once."
    } else {
        Set-RightlyStatus "preparing" "Preparing a local, verified Rightly startup."
    }
    Stop-OfficialCodex $official.AppDir
    Stop-StaleRightlyInjectors
    Set-RightlyStatus "opening" "Opening the official GPT application with a private loopback debugging endpoint."
    $port = Get-FreeLoopbackPort
    $injector = Start-Injector $port
    $arguments = "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$port --force-ui-direction=ltr"
    $launchedProcessId = Start-PackagedCodex `
        -AppUserModelId $official.AppUserModelId -Arguments $arguments
    Write-RightlyLog "Launched official GPT PID $launchedProcessId with loopback DevTools port $port; injector PID $($injector.Id)"
    Set-RightlyStatus "injecting" "Applying the RTL payload and verifying it inside the live GPT renderer."
    Wait-InjectorVerification $injector
    Write-RightlyLog "GPT startup completed with a verified Rightly payload"
    Set-RightlyStatus "ready" "GPT is open with a verified Rightly correction."
} catch {
    if ($injector -and -not $injector.HasExited) {
        Stop-Process -Id $injector.Id -Force -ErrorAction SilentlyContinue
    }
    Write-RightlyLog "FATAL $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    Set-RightlyStatus "failed" $_.Exception.Message
    if (-not $StatusFile) { Show-RightlyError $_.Exception.Message }
    exit 1
}
