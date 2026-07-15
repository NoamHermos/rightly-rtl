<#
Rightly - unified online RTL installer for GPT and Claude.

Run with:
  irm https://raw.githubusercontent.com/NoamHermos/rightly/main/installer/install-online.ps1 | iex
#>

[CmdletBinding()]
param(
    [string] $Repo = "NoamHermos/rightly",
    [string] $Branch = "main",
    [ValidateSet("Prompt", "GptWork", "ClaudeCode", "Both")]
    [string] $Target = "Prompt"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rightly-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempRoot "source.zip"
$extractDir = Join-Path $tempRoot "extract"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    New-Item -ItemType Directory -Path $extractDir | Out-Null

    if ($Branch -match '^v\d+\.') {
        $zipUrl = "https://codeload.github.com/$Repo/zip/refs/tags/$Branch"
    } else {
        $zipUrl = "https://codeload.github.com/$Repo/zip/refs/heads/$Branch"
    }

    Write-Step "Downloading Rightly"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $sourceDir = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
    if (-not $sourceDir) { throw "Could not locate the downloaded source." }
    $installer = Join-Path $sourceDir.FullName "installer\install.ps1"
    if (-not (Test-Path -LiteralPath $installer)) { throw "install.ps1 was not found in the downloaded source." }

    Write-Step "Opening the installation menu"
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = "powershell.exe" }
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $installer -Target $Target
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with code $LASTEXITCODE." }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
