[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "installer\lib\Rightly.Install.ps1"
$installOnlinePath = Join-Path $repoRoot "installer\install-online.ps1"
$uninstallOnlinePath = Join-Path $repoRoot "installer\uninstall-online.ps1"
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rightly-package-test-" + [guid]::NewGuid().ToString("N"))
$originalLocalAppData = $env:LOCALAPPDATA

try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $env:LOCALAPPDATA = $sandbox

    . $modulePath
    Initialize-RightlyInstaller -Root $repoRoot
    Install-RightlyRepairBundle

    $repairRoot = Join-Path $sandbox "Programs\Rightly\Repair"
    $expected = @(
        "installer\install.ps1",
        "installer\install-online.ps1",
        "installer\run-repair.ps1",
        "installer\uninstall.ps1",
        "installer\lib\Rightly.Install.ps1",
        "assets\rightly.ico",
        "src\gpt\patch.ps1",
        "src\gpt\codex-rtl-payload.js",
        "src\gpt\gpt-rtl-cdp.js",
        "src\gpt\launch-gpt.ps1",
        "src\claude\patch.ps1",
        "src\claude\claude-rtl-payload.js"
    )
    foreach ($relative in $expected) {
        Assert-True (Test-Path -LiteralPath (Join-Path $repairRoot $relative) -PathType Leaf) `
            "Repair package is missing: $relative"
    }

    $actual = @(Get-ChildItem -LiteralPath $repairRoot -File -Recurse | ForEach-Object {
        $_.FullName.Substring($repairRoot.Length + 1)
    })
    Assert-True ($actual.Count -eq $expected.Count) `
        "Repair package contains unexpected files: $($actual | Where-Object { $_ -notin $expected })"

    $installOnline = Get-Content -LiteralPath $installOnlinePath -Raw
    $uninstallOnline = Get-Content -LiteralPath $uninstallOnlinePath -Raw
    Assert-True ($installOnline.Contains('installer\install.ps1')) "Online installer targets the wrong entry point"
    Assert-True ($installOnline.Contains('[switch] $RepairMode')) "Online installer does not accept repair mode"
    Assert-True ($installOnline.Contains('$installerArguments += "-RepairMode"')) "Online installer does not forward repair mode"
    Assert-True ($uninstallOnline.Contains('installer\uninstall.ps1')) "Online uninstaller targets the wrong entry point"
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Rightly repair-package verification passed." -ForegroundColor Green
