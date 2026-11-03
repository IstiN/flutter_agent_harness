#!/usr/bin/env pwsh
# install_local.ps1 - build the Fa CLI from source and install it locally on
# Windows. The Windows mirror of install_local.sh (which targets ~/.local/bin
# on POSIX). Default install layout matches the released Windows installer:
#   %LOCALAPPDATA%\Fa\bin\fa.exe      (the AOT binary)
#   %LOCALAPPDATA%\Fa\bin\version.txt (git-describe build stamp)
#   %LOCALAPPDATA%\Fa\lib\*.dll       (native assets, resolved as bin/../lib)
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File install_local.ps1
#
# The running-exe swap is safe on Windows: a running image cannot be
# overwritten, but it CAN be renamed, so the old fa.exe is moved aside
# (fa-prev-<HHmm>.exe, kept as a rollback artifact) before the new one lands.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallBin = if ($env:FA_INSTALL_BIN) { $env:FA_INSTALL_BIN }
              else { Join-Path $env:LOCALAPPDATA 'Fa\bin' }
$InstallLib = Join-Path (Split-Path -Parent $InstallBin) 'lib'
$BundleDir = Join-Path $RepoRoot 'fa-local'

# Resolve the Dart SDK entry point: FA_DART override, `dart` on PATH, or the
# flutter-bundled dart.bat next to a `flutter` on PATH / in the usual
# locations (a bare `dart` is often absent on Windows dev machines that only
# have Flutter installed).
$Dart = $null
$candidates = @($env:FA_DART)
$dartCmd = Get-Command dart -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dartCmd) { $candidates += $dartCmd.Source }
$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue | Select-Object -First 1
if ($flutterCmd) {
    $candidates += Join-Path (Split-Path -Parent $flutterCmd.Source) 'dart.bat'
}
$candidates += @(
    (Join-Path $env:USERPROFILE 'flutter\bin\dart.bat'),
    (Join-Path $env:LOCALAPPDATA 'flutter\bin\dart.bat')
)
foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    if (Test-Path $candidate) { $Dart = $candidate; break }
}
if (-not $Dart) {
    throw 'no Dart SDK found - put dart on PATH or set FA_DART to dart.bat'
}
Write-Host "-> Using Dart: $Dart"

Set-Location $RepoRoot

Write-Host '-> Resolving packages...'
& $Dart pub get | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'dart pub get failed' }

Write-Host '-> Building Fa CLI bundle...'
& $Dart build cli --target=bin/fah.dart --output=fa-local
if ($LASTEXITCODE -ne 0) {
    Write-Host '   dart build cli unavailable or failed - falling back to dart compile exe'
    $FallbackBin = Join-Path $BundleDir 'bundle\bin'
    New-Item -ItemType Directory -Force -Path $FallbackBin | Out-Null
    & $Dart compile exe 'bin/fah.dart' -o (Join-Path $FallbackBin 'fah.exe')
    if ($LASTEXITCODE -ne 0) { throw 'dart compile exe failed' }
}

# gh-1522: the committed pubspec carries the 0.0.0-dev placeholder (the git
# tag is the single source of truth) - stamp the build version from git
# describe, same contract as install_local.sh.
$Version = (& git describe --tags --always --dirty 2>$null)
if (-not $Version -or $LASTEXITCODE -ne 0) { $Version = '0.0.0-dev' }
$Version = $Version -replace '^v', ''
$BundleBinDir = Join-Path $BundleDir 'bundle\bin'
$BundleLibDir = Join-Path $BundleDir 'bundle\lib'
if (-not (Test-Path (Join-Path $BundleBinDir 'fah.exe'))) {
    # dart build cli output shape differs across SDK versions; find it.
    $Built = Get-ChildItem -Path $BundleDir -Recurse -Filter 'fah.exe' |
        Select-Object -First 1
    if (-not $Built) { throw 'build produced no fah.exe' }
    $BundleBinDir = $Built.DirectoryName
}
Set-Content -Path (Join-Path $BundleBinDir 'version.txt') -Value $Version -NoNewline
Write-Host "-> Built fa v$Version"

Write-Host "-> Installing to $InstallBin..."
New-Item -ItemType Directory -Force -Path $InstallBin | Out-Null
New-Item -ItemType Directory -Force -Path $InstallLib | Out-Null

$Target = Join-Path $InstallBin 'fa.exe'
if (Test-Path $Target) {
    # A running fa.exe cannot be overwritten but CAN be renamed - move it
    # aside and keep it as a rollback artifact.
    $Stamp = Get-Date -Format 'HHmm'
    $Backup = Join-Path $InstallBin "fa-prev-$Stamp.exe"
    Move-Item -Force -Path $Target -Destination $Backup
    Write-Host "   previous binary kept as $(Split-Path -Leaf $Backup)"
}
Copy-Item -Force -Path (Join-Path $BundleBinDir 'fah.exe') -Destination $Target
Copy-Item -Force -Path (Join-Path $BundleBinDir 'version.txt') -Destination (Join-Path $InstallBin 'version.txt')

# gh-1574: the AOT binary's native-assets resolver looks for the bundle libs
# in <exe_dir>/../lib - copy whatever the bundle produced (sqlite3.dll).
if (Test-Path $BundleLibDir) {
    Copy-Item -Force -Path (Join-Path $BundleLibDir '*') -Destination $InstallLib
}

Write-Host "-> Installed $Target"

$InstalledVersion = (& $Target --version 2>$null)
if ($LASTEXITCODE -eq 0 -and $InstalledVersion) {
    Write-Host "[OK] $InstalledVersion is on PATH"
} else {
    Write-Warning "installed binary did not answer --version (exit $LASTEXITCODE)"
}
