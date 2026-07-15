<#
.SYNOPSIS
Installs or repairs Rightly for GPT Work / Codex, Claude, or both.

.DESCRIPTION
The entry point intentionally contains only orchestration. Shared installer
plumbing lives in lib\Rightly.Install.ps1; each app keeps its own patcher.
#>

[CmdletBinding()]
param(
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string] $Target = "Prompt",
    [switch] $NoLaunch,
    [switch] $RepairMode,
    [switch] $Elevated
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $PSScriptRoot "lib\Rightly.Install.ps1"
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Installer module is missing: $modulePath" }
. $modulePath
Initialize-RightlyInstaller -Root $projectRoot

$gptPatcher = Join-Path $projectRoot "src\gpt\patch.ps1"
$claudePatcher = Join-Path $projectRoot "src\claude\patch.ps1"
$operation = if ($RepairMode) { "repair" } else { "install" }

if ($Target -eq "Prompt") { $Target = Select-RightlyTarget -Operation $operation }

$ranElevatedInstaller = Invoke-RightlyElevatedInstallerIfNeeded `
    -Target $Target -RepairMode:$RepairMode -NoLaunch:$NoLaunch -Elevated:$Elevated
if ($ranElevatedInstaller) {
    if (-not $NoLaunch) {
        if ($Target -in @("ClaudeCode", "Both")) {
            Invoke-RightlyOfficialLauncher -Name "Claude" -Path $claudePatcher
        }
        if ($Target -in @("GptWork", "Both")) {
            Invoke-RightlyOfficialLauncher -Name "GPT Work / Codex" -Path $gptPatcher
        }
    }
    return
}

if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    throw "Node.js is not installed. Install Node.js LTS from https://nodejs.org/ and run the installer again."
}

if ($Target -in @("GptWork", "Both")) {
    Invoke-RightlyPatcher -Name "GPT Work / Codex" -Path $gptPatcher
}
if ($Target -in @("ClaudeCode", "Both")) {
    Invoke-RightlyPatcher -Name "Claude Desktop / Code" -Path $claudePatcher
}

Install-RightlyRepairBundle
New-RightlyRepairShortcut

Write-Host ""
$completion = if ($RepairMode) { "RTL repair" } else { "Installation" }
Write-Host "$completion completed successfully." -ForegroundColor Green
Write-Host "Use the Repair RTL desktop shortcut after restarting or updating an app." -ForegroundColor Green

if (-not $NoLaunch) {
    # GPT opens last because it can move the active conversation to the new window.
    if ($Target -in @("ClaudeCode", "Both")) {
        Invoke-RightlyOfficialLauncher -Name "Claude" -Path $claudePatcher
    }
    if ($Target -in @("GptWork", "Both")) {
        Invoke-RightlyOfficialLauncher -Name "GPT Work / Codex" -Path $gptPatcher
    }
}
