<# Opens the interactive Rightly repair menu with persistent logging and friendly errors. #>

[CmdletBinding()]
param(
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string]$Target = "Prompt"
)

$ErrorActionPreference = "Stop"
$installerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $installerDir
$installer = Join-Path $installerDir "install.ps1"
$logDir = Join-Path $root "logs"
$logName = if ($Target -eq "Prompt") { "repair-interactive.log" } else { "repair-$($Target.ToLowerInvariant()).log" }
$logPath = Join-Path $logDir $logName
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Silence Node's non-fatal deprecation and warning output (for example the
# url.parse DEP0169 notice) for every Node subprocess started during the
# repair, so their console noise is never mistaken for a Rightly failure.
$env:NODE_NO_WARNINGS = "1"
$env:NODE_OPTIONS = (@($env:NODE_OPTIONS, "--no-deprecation") | Where-Object { $_ }) -join " "

function Wait-RightlyClose {
    Write-Host ""
    Write-Host "Press any key to close . . ." -ForegroundColor DarkGray
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try { [void](Read-Host) } catch { }
    }
}

$succeeded = $false
try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $installer)) { throw "Rightly installer is missing: $installer" }
    & $installer -Target $Target -RepairMode
    $succeeded = $true
} catch {
    try { Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) FATAL $($_.Exception.Message)" -Encoding UTF8 } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`r`n`r`nThe full log was saved at:`r`n$logPath",
            "Rightly repair failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch { }
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}

Write-Host ""
if ($succeeded) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  SUCCESS" -ForegroundColor Green
    Write-Host "  Rightly RTL repair completed. You can use the app now." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Wait-RightlyClose
    exit 0
} else {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  FAILED" -ForegroundColor Red
    Write-Host "  Rightly RTL repair did not complete." -ForegroundColor Red
    Write-Host "  Log: $logPath" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Wait-RightlyClose
    exit 1
}
