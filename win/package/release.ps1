# Assembles what a user of TreeLevel downloads on Windows: the engine and the Pythia 8 module, in one folder
# to unpack. Herwig and Sherpa are not here — they come in the container image.
#
#   .\release.ps1 -Pythia "$env:LOCALAPPDATA\TreeLevel Tools\src\pythia8318"
#   .\release.ps1 -Pythia <sources> -Arch x64 -NoPdfData
#   .\release.ps1 -EngineOnly                     # no Pythia module, for a quick build
#
# The archive lands in win/package/out/. Unpacking it into %LOCALAPPDATA%\Programs is the whole installation:
# TreeLevel looks there, and the engine finds the module beside itself.
#
# Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later.

[CmdletBinding()]
param(
    [string]$Pythia,
    [ValidateSet('x64', 'arm64')] [string]$Arch,
    [switch]$NoPdfData,
    [switch]$EngineOnly,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent          # win/
$repo = Split-Path $root -Parent

function Fail($message) { Write-Host $message -ForegroundColor Red; exit 1 }
function Say($message) { Write-Host $message -ForegroundColor Cyan }

# The machine architecture, not the one of the PowerShell that is running.
if (-not $Arch) {
    $machine = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
    $Arch = if ($machine -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$rid = "win-$Arch"

$version = (Select-String -Path (Join-Path $root 'treelevel-mc\treelevel-mc.csproj') -Pattern '<Version>([^<]+)').Matches[0].Groups[1].Value
if (-not $version) { Fail 'no <Version> in treelevel-mc.csproj' }

$out = Join-Path $PSScriptRoot 'out'
$staging = Join-Path $out "TreeLevel Tools"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

# --- the engine ---------------------------------------------------------------------------------------------
Say "Moteur $version ($rid)"
& dotnet publish (Join-Path $root 'treelevel-mc') -c Release -r $rid --self-contained true `
    -p:PublishSingleFile=true -p:DebugType=none -o (Join-Path $out "publish-$Arch") | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'the engine did not build' }
Copy-Item (Join-Path $out "publish-$Arch\treelevel-mc.exe") $staging

# --- the Pythia module --------------------------------------------------------------------------------------
if (-not $EngineOnly) {
    if (-not $Pythia) { Fail 'give the Pythia sources with -Pythia, or pass -EngineOnly' }
    Say "Module Pythia 8"
    $modules = Join-Path $staging 'Modules\pythia8'
    & (Join-Path $root 'backends\pythia\build.ps1') -Pythia $Pythia -Arch $Arch -Prefix $modules
    if ($LASTEXITCODE -ne 0) { Fail 'the Pythia module did not build' }
    if ($NoPdfData) {
        # 53 MB of parton densities that an e+e- collision never opens; a hadron beam does.
        Remove-Item (Join-Path $modules 'pdfdata') -Recurse -Force -ErrorAction SilentlyContinue
        Say "  pdfdata retiré"
    }
}

# --- what goes with it --------------------------------------------------------------------------------------
Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $staging 'LICENSE.txt') -ErrorAction SilentlyContinue
@"
TreeLevel Tools $version — $Arch

Installation
------------
Déplacez ce dossier « TreeLevel Tools » dans :

    %LOCALAPPDATA%\Programs\

TreeLevel le trouvera tout seul au prochain démarrage. C'est tout : rien à
enregistrer, aucun service, aucun compte. Pour désinstaller, supprimez le dossier.

Ce qu'il contient
-----------------
    treelevel-mc.exe          le moteur
    Modules\pythia8\          Pythia 8 et ses données

Pour vérifier depuis une console :

    "%LOCALAPPDATA%\Programs\TreeLevel Tools\treelevel-mc.exe" capabilities

Herwig 7 et Sherpa 3
--------------------
Ils n'existent pas pour Windows et arrivent dans une image de conteneur :

    docker pull ghcr.io/gpasa/treelevel-mc-engine:$version

Licence
-------
GPL v3 ou ultérieure. Pythia 8 est sous GPL v2 ou ultérieure ; sa licence est dans
Modules\pythia8\COPYING.pythia8 et ses sources sont celles de https://pythia.org,
construites par win/backends/pythia du dépôt https://github.com/gpasa/treelevel-mc-engine.
"@ | Set-Content (Join-Path $staging 'LISEZMOI.txt') -Encoding utf8

# --- the archive --------------------------------------------------------------------------------------------
$zip = Join-Path $out "TreeLevelTools-$version-$Arch.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal
if (-not $KeepStaging) { Remove-Item (Join-Path $out "publish-$Arch") -Recurse -Force -ErrorAction SilentlyContinue }

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
$loose = [math]::Round(((Get-ChildItem $staging -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
Say ""
Write-Host "$zip" -ForegroundColor Green
Write-Host "  $size Mo compressés, $loose Mo déployés"
