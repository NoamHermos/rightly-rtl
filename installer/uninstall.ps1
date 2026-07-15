<#
.SYNOPSIS
Restores GPT Work / Codex, Claude, or both to their unmodified Rightly state.
#>

[CmdletBinding()]
param(
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string] $Target = "Prompt"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $PSScriptRoot "lib\Rightly.Install.ps1"
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Installer module is missing: $modulePath" }
. $modulePath
Initialize-RightlyInstaller -Root $projectRoot

$gptPatcher = Join-Path $projectRoot "src\gpt\patch.ps1"
$claudePatcher = Join-Path $projectRoot "src\claude\patch.ps1"
if ($Target -eq "Prompt") { $Target = Select-RightlyTarget -Operation "uninstall" }

if ($Target -in @("GptWork", "Both")) {
    Invoke-RightlyPatcher -Name "GPT Work / Codex" -Path $gptPatcher -Action Uninstall
}
if ($Target -in @("ClaudeCode", "Both")) {
    Invoke-RightlyPatcher -Name "Claude Desktop / Code" -Path $claudePatcher -Action Uninstall
}

if ($Target -eq "Both") {
    Remove-RightlyRepairShortcut
    $runningFromRepairBundle = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd('\').Equals(
        [System.IO.Path]::GetFullPath($Script:RightlyRepairDir).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if ($runningFromRepairBundle) {
        Write-RightlyInfo "The repair files are in use and can be deleted after this window closes: $($Script:RightlyRepairDir)"
    } else {
        Remove-RightlyRepairBundle
    }
}

Write-Host ""
Write-Host "Rightly uninstall completed successfully." -ForegroundColor Green
