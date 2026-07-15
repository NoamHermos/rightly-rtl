<# Opens the interactive Rightly repair menu with persistent logging and friendly errors. #>

[CmdletBinding()]
param(
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string]$Target = "Prompt"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $root "install.ps1"
$logDir = Join-Path $root "logs"
$logName = if ($Target -eq "Prompt") { "repair-interactive.log" } else { "repair-$($Target.ToLowerInvariant()).log" }
$logPath = Join-Path $logDir $logName
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $installer)) { throw "Rightly installer is missing: $installer" }
    & $installer -Target $Target -RepairMode
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
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
