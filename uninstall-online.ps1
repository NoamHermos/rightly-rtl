<#
.SYNOPSIS
Downloads Rightly and opens the unified Windows uninstaller.

.EXAMPLE
irm https://raw.githubusercontent.com/NoamHermos/rightly-rtl/main/uninstall-online.ps1 | iex
#>

[CmdletBinding()]
param(
    [string] $Repo = "NoamHermos/rightly-rtl",
    [string] $Branch = "main",
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string] $Target = "Prompt"
)

$ErrorActionPreference = "Stop"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rightly-uninstall-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempRoot "source.zip"
$extractDir = Join-Path $tempRoot "extract"

try {
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    $kind = if ($Branch -match '^v\d+\.') { "tags" } else { "heads" }
    $zipUrl = "https://codeload.github.com/$Repo/zip/refs/$kind/$Branch"

    Write-Host "==> Downloading Rightly" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $sourceDir = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
    if (-not $sourceDir) { throw "Could not locate the downloaded source." }
    $uninstaller = Join-Path $sourceDir.FullName "uninstall.ps1"
    if (-not (Test-Path -LiteralPath $uninstaller)) { throw "uninstall.ps1 was not found in the downloaded source." }

    $powershell = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $powershell) {
        $powershell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $uninstaller -Target $Target
    if ($LASTEXITCODE -ne 0) { throw "Uninstaller exited with code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
