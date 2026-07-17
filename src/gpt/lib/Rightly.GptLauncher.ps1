<#
.SYNOPSIS
Builds the native-looking Rightly GPT launcher used by Windows shortcuts.

.DESCRIPTION
The launcher is a small, windowless .NET executable. It gives Windows a stable
application identity and embedded Rightly icon while delegating the actual,
audited launch-time injection to launch-gpt.ps1.
#>

function New-RightlyGptLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][string] $IconPath
    )

    foreach ($path in @($SourcePath, $IconPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Rightly GPT launcher build input is missing: $path"
        }
    }

    $destinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $temporaryExe = Join-Path $destinationDirectory ("Rightly.Gpt.Launcher.{0}.tmp.exe" -f [guid]::NewGuid().ToString("N"))

    try {
        $compiler = @(
            (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
            (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $compiler) {
            throw "Windows' built-in .NET Framework C# compiler is unavailable."
        }

        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $compilerOutput = @(& $compiler @(
                "/nologo",
                "/target:winexe",
                "/optimize+",
                "/platform:anycpu",
                "/reference:System.Drawing.dll",
                "/reference:System.Windows.Forms.dll",
                "/win32icon:$IconPath",
                "/out:$temporaryExe",
                $SourcePath
            ) 2>&1)
            $compilerExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($compilerExitCode -ne 0) {
            $details = (@($compilerOutput | ForEach-Object { [string] $_ }) -join " ").Trim()
            throw "Could not compile the Rightly GPT launcher (exit code $compilerExitCode): $details"
        }

        if (-not (Test-Path -LiteralPath $temporaryExe -PathType Leaf)) {
            throw "The Rightly GPT launcher compiler did not create an executable."
        }
        if ((Get-Item -LiteralPath $temporaryExe).Length -lt 4096) {
            throw "The compiled Rightly GPT launcher is unexpectedly small."
        }

        Move-Item -LiteralPath $temporaryExe -Destination $DestinationPath -Force
        return [System.IO.Path]::GetFullPath($DestinationPath)
    } finally {
        Remove-Item -LiteralPath $temporaryExe -Force -ErrorAction SilentlyContinue
    }
}

function New-RightlyGptShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LauncherPath,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $IconPath
    )

    foreach ($path in @($LauncherPath, $IconPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Rightly GPT shortcut dependency is missing: $path"
        }
    }

    $shortcutPaths = @(
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Rightly GPT.lnk"),
        (Join-Path (Join-Path ([Environment]::GetFolderPath("Programs")) "Rightly") "Rightly GPT.lnk")
    )
    $shell = New-Object -ComObject WScript.Shell

    # Windows owns taskbar pin creation, but an existing pin is still a normal
    # shortcut. Refresh only pins that already target this managed launcher.
    $taskbarDirectory = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    foreach ($pinnedPath in @(Get-ChildItem -LiteralPath $taskbarDirectory -Filter "*.lnk" -ErrorAction SilentlyContinue)) {
        try {
            $pinned = $shell.CreateShortcut($pinnedPath.FullName)
            if ([System.IO.Path]::GetFullPath($pinned.TargetPath).Equals(
                    [System.IO.Path]::GetFullPath($LauncherPath),
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                $shortcutPaths += $pinnedPath.FullName
            }
        } catch { }
    }

    foreach ($shortcutPath in @($shortcutPaths | Select-Object -Unique)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $shortcutPath) -Force | Out-Null
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $LauncherPath
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.Arguments = ""
        $shortcut.IconLocation = "$IconPath,0"
        $shortcut.Description = "Rightly RTL for the official GPT Work / Codex app"
        $shortcut.Save()
        Write-Output $shortcutPath
    }
}
