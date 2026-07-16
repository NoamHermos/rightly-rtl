<# Opens the interactive Rightly repair menu with persistent logging and friendly errors. #>

[CmdletBinding()]
param(
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string]$Target = "Prompt"
)

$ErrorActionPreference = "Stop"
$installerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $installerDir
$onlineInstaller = Join-Path $installerDir "install-online.ps1"
$logDir = Join-Path $root "logs"
$logName = if ($Target -eq "Prompt") { "repair-interactive.log" } else { "repair-$($Target.ToLowerInvariant()).log" }
$logPath = Join-Path $logDir $logName
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Wait-RightlyClose {
    Write-Host ""
    Write-Host "Press any key to close . . ." -ForegroundColor DarkGray
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try { [void](Read-Host) } catch { }
    }
}

function Show-RightlySuccess {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "Every selected application completed successfully.`r`n`r`nWhen GPT was selected, its RTL payload marker was injected and verified before this message was shown.",
            "Rightly repair completed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return $true
    } catch {
        return $false
    }
}

$succeeded = $false
try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $onlineInstaller)) {
        throw "Rightly online installer is missing: $onlineInstaller"
    }

    # The local bootstrap always downloads main before it invokes the repair.
    # A successful desktop-shortcut run therefore uses the current repository
    # rather than the source snapshot copied during the first installation.
    Write-Host "Checking for the latest Rightly version..." -ForegroundColor Cyan
    & $onlineInstaller -Repo "NoamHermos/rightly" -Branch "main" -Target $Target -RepairMode
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
    if (-not (Show-RightlySuccess)) { Wait-RightlyClose }
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
