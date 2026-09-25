# Builds and installs the Pythia 8 module of TreeLevel Tools.
#
#   .\build.ps1 -Pythia C:\src\pythia8318
#   .\build.ps1 -Pythia C:\src\pythia8318 -Arch x64 -NoInstall
#
# Pythia is GPL and is downloaded by you from https://pythia.org (any 8.3 release): unpack the archive and
# pass the folder holding include\ and src\. The module is installed, driver and xmldoc together, into
# %LOCALAPPDATA%\TreeLevel Tools\Modules\pythia8, where the engine looks for it.
#
# Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later.

[CmdletBinding()]
param(
    [string]$Pythia,
    [ValidateSet('x64', 'arm64')] [string]$Arch,
    [string]$Prefix,
    [switch]$NoInstall,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Fail($message) { Write-Host $message -ForegroundColor Red; exit 1 }

# The Pythia source tree: the argument, then the usual places beside the engine.
if (-not $Pythia) {
    $guesses = @(
        (Join-Path $root 'pythia8'),
        (Join-Path (Split-Path (Split-Path $root -Parent) -Parent) 'pythia8'),
        (Join-Path $env:LOCALAPPDATA 'TreeLevel Tools\src\pythia8')
    )
    $guesses += Get-ChildItem -Path (Split-Path $root -Parent) -Directory -Filter 'pythia8*' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName }
    $Pythia = $guesses | Where-Object { Test-Path (Join-Path $_ 'include\Pythia8\Pythia.h') } | Select-Object -First 1
}
if (-not $Pythia -or -not (Test-Path (Join-Path $Pythia 'include\Pythia8\Pythia.h'))) {
    Fail @"
Pythia 8 not found.

  1. download a release from https://pythia.org (pythia83xx.tgz)
  2. unpack it anywhere, for instance with:  tar xzf pythia8318.tgz -C C:\src
  3. run:  .\build.ps1 -Pythia C:\src\pythia8318
"@
}
$Pythia = (Resolve-Path $Pythia).Path

# The machine architecture, not the one of the PowerShell that is running: an x64 PowerShell emulated on an
# ARM64 machine reports AMD64.
if (-not $Arch) {
    $machine = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
    $Arch = if ($machine -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$platform = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }

# CMake: the PATH first, then the one Visual Studio installs.
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsVersion = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $vsVersion = & $vswhere -latest -products * -property installationVersion
    if (-not $cmake -and $vsPath) {
        $bundled = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        if (Test-Path $bundled) { $cmake = $bundled }
    }
}
if (-not $cmake) { Fail 'CMake not found — install it, or install the "Desktop development with C++" workload of Visual Studio.' }

$generator = switch (($vsVersion -split '\.')[0]) {
    '18' { 'Visual Studio 18 2026' }
    '17' { 'Visual Studio 17 2022' }
    '16' { 'Visual Studio 16 2019' }
    default { $null }
}
if (-not $generator) { Fail 'Visual Studio 2019 or later is needed to build Pythia.' }

$build = Join-Path $root "build\$Arch"
if ($Clean -and (Test-Path $build)) { Remove-Item $build -Recurse -Force }
if (-not $Prefix) { $Prefix = Join-Path $env:LOCALAPPDATA 'TreeLevel Tools\Modules\pythia8' }

Write-Host "Pythia    $Pythia"
Write-Host "generator $generator ($platform)"
Write-Host "module    $Prefix"

& $cmake -S $root -B $build -G $generator -A $platform "-DPYTHIA8_DIR=$($Pythia.Replace([char]92, [char]47))"
if ($LASTEXITCODE -ne 0) { Fail 'cmake configuration failed' }

# Pythia is a hundred translation units: several minutes the first time, seconds afterwards.
& $cmake --build $build --config Release --parallel
if ($LASTEXITCODE -ne 0) { Fail 'compilation failed' }

$driver = Join-Path $build 'Release\treelevel-pythia.exe'
if (-not (Test-Path $driver)) { Fail "the driver was not produced ($driver)" }
$version = & $driver --version
Write-Host "built     treelevel-pythia, Pythia $version" -ForegroundColor Green

if ($NoInstall) { exit 0 }
& $cmake --install $build --config Release --prefix $Prefix
if ($LASTEXITCODE -ne 0) { Fail 'installation failed' }
Write-Host "installed $Prefix" -ForegroundColor Green
Write-Host 'Check with:  treelevel-mc capabilities'
