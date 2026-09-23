# TreeLevel MC Engine — Windows

La même chose que sur macOS : TreeLevel écrit un dossier de travail, ce programme y fait tourner un générateur
et réécrit les événements en HepMC3. Le protocole est identique au bit près — un dossier écrit sur un Mac se
relit ici et inversement.

```
treelevel-mc run <dossier>            exécute job.json, produit events.hepmc, tient status.json à jour
treelevel-mc capabilities [--out f]   les générateurs installés, en JSON
treelevel-mc version
```

## Ce qui tourne, et comment

| Générateur | Sur Windows |
|---|---|
| Sans gerbe (`passthrough`) | intégré au moteur, rien à installer |
| Pythia 8 | natif, MSVC — `backends/pythia` construit le pilote et son module |
| Herwig 7 | dans le conteneur : aucune version Windows n'existe |
| Sherpa 3 | dans le conteneur, pour la même raison |
| WHIZARD, CalcHEP | pas encore portés |

Pythia, Herwig et Sherpa sont sous **GPL** : ce dépôt est GPL v3, et aucun de leurs fichiers n'y est recopié.
Vous construisez Pythia avec le script ci-dessous ; Herwig et Sherpa arrivent construits dans l'image, dont la
recette et les sources sont publiées avec elle.

## Construire le moteur

.NET 8 suffit ; il n'y a aucune dépendance.

```powershell
cd win\treelevel-mc
dotnet publish -c Release -r win-arm64   # ou win-x64
```

Le résultat est un seul exécutable, `treelevel-mc.exe`. TreeLevel le cherche à côté de lui, dans
`%LOCALAPPDATA%\Programs\TreeLevel MC Engine`, dans `%ProgramFiles%\TreeLevel MC Engine`, dans votre dossier
personnel, puis dans le PATH.

> TreeLevel est empaqueté en MSIX, et un paquet MSIX détourne les écritures dans `%LOCALAPPDATA%` vers son
> propre conteneur : un programme extérieur ne verrait pas ce qu'il y écrit. Les dossiers de travail sont donc
> créés **à côté du moteur** (`<dossier du moteur>\MCJobs\<id>`), et les capacités sont lues en lançant
> `treelevel-mc capabilities` plutôt qu'en ouvrant le fichier publié.

## Construire le module Pythia 8

Pythia n'a pas de système de construction pour Windows. `backends/pythia` compile ses sources directement avec
MSVC, sans en modifier une ligne : la seule chose qui manque à Windows, `<dlfcn.h>` — que `PythiaStdlib.h`
inclut sans condition et dont `Plugins.cc` se sert pour charger des greffons —, est fournie par
`backends/pythia/compat/dlfcn.h`, une trentaine de lignes au-dessus de `LoadLibrary`.

```powershell
# 1. les sources, depuis https://pythia.org (n'importe quelle version 8.3)
curl.exe -L -o pythia8318.tar.gz https://gitlab.com/Pythia8/releases/-/archive/pythia8318/releases-pythia8318.tar.gz
mkdir "$env:LOCALAPPDATA\TreeLevel MC Engine\src"
tar.exe xzf pythia8318.tar.gz -C "$env:LOCALAPPDATA\TreeLevel MC Engine\src"

# 2. le module
cd win\backends\pythia
.\build.ps1 -Pythia "$env:LOCALAPPDATA\TreeLevel MC Engine\src\pythia8318"
```

Le script trouve Visual Studio et son CMake tout seul, construit pour l'architecture de la machine (`-Arch x64`
ou `-Arch arm64` pour en changer) et installe le pilote **et son `xmldoc`** dans
`%LOCALAPPDATA%\TreeLevel MC Engine\Modules\pythia8`, où le moteur va les chercher. Le runtime C++ est lié
statiquement : le module tourne sur une machine sans redistribuable Visual C++.

Les 107 unités de compilation de Pythia prennent quelques minutes la première fois.

```powershell
treelevel-mc capabilities     # pythia8 doit apparaître, avec sa version
```

## Herwig 7 et Sherpa 3 : le conteneur

Aucun des deux n'a de version Windows, et ce n'est pas une affaire de drapeaux de compilation : Sherpa charge
ses modules avec `dlopen` et s'appuie sur `sys/resource.h`, Herwig repose sur le dépôt de classes chargées à
l'exécution de ThePEG, sur autotools et sur du Fortran. Les porter, ce serait maintenir un fork de code GPL
amont. Ils tournent donc dans un conteneur Linux, que l'utilisateur récupère d'une commande :

```powershell
docker pull ghcr.io/gpasa/treelevel-mc-engine:0.2.0
```

Le moteur qui tourne dans l'image est **le même programme** que celui de Windows, compilé pour Linux : il lit
le même `job.json` et écrit le même `status.json`. Le dossier de travail est monté tel quel, donc rien n'est
copié ni converti — voir [`docker/README.md`](../docker/README.md) pour ce que l'image contient et d'où
viennent ses sources.

Côté Windows, le moteur s'en occupe seul : il vérifie que le démon Docker répond, que l'image est **déjà**
présente (`docker image inspect` — rien n'est jamais téléchargé sans qu'on le demande), puis lance

```
docker run --rm -v "<dossier de travail>:/job" <image> run /job
```

et laisse le conteneur écrire lui-même sa progression. Si Docker n'est pas là, les deux générateurs ne sont pas
proposés, et un travail qui les demande échoue tout de suite avec la raison.

> **Machines virtuelles.** Docker Desktop fait tourner son moteur dans WSL2, c'est-à-dire dans une machine
> virtuelle Hyper-V. Sur un PC réel la virtualisation est active d'origine ; dans un invité Windows, il faut
> que l'hôte expose la **virtualisation imbriquée** — sur un Mac, une puce M3 ou M4 avec Parallels 19+.
> Sans elle, Docker s'installe mais son moteur ne démarre pas. Pythia, lui, tourne partout.

### Le repli : WSL à la main

Pour qui a déjà construit Herwig ou Sherpa dans sa distribution, le moteur les y trouve encore. Il interroge
`Herwig --version` et `Sherpa --version` à chaque appel de `capabilities`, et une installation cassée disparaît
de la liste au lieu d'échouer au milieu d'un travail.

```bash
# dans Ubuntu ; les contournements imposés par macOS (gcc plutôt que clang, _Static_assert, -fno-range-check)
# n'ont pas lieu d'être ici, gcc est le compilateur du système
sudo apt install -y build-essential gfortran autoconf automake libtool python3-dev zlib1g-dev libboost-dev libgsl-dev
wget https://herwig.hepforge.org/downloads/herwig-bootstrap && chmod +x herwig-bootstrap
./herwig-bootstrap --lite -j $(nproc) ~/herwig7        # une à deux heures
echo 'source ~/herwig7/bin/activate' >> ~/.bashrc
```

Le moteur lance ses commandes avec `bash -lc`, donc le `PATH` que cette ligne pose est celui qu'il voit. C'est
exactement la recette de l'image, en plus long — d'où l'image.

## Différences avec macOS

* Les chemins du support sont `%LOCALAPPDATA%\TreeLevel MC Engine\` au lieu de
  `~/Library/Application Support/TreeLevel MC Engine/`.
* Le moteur est écrit en C# plutôt qu'en Swift ; le protocole, lui, est le même fichier de part et d'autre
  (`MCEngineProtocol.cs` ↔ `Protocol/MCEngineProtocol.swift`), y compris la forme exacte du JSON que
  `Codable` produit : clés en camel, énumérations en minuscules, dates en secondes depuis le 1er janvier 2001.
* Herwig et Sherpa tournent dans un conteneur Linux au lieu de tourner nativement ; c'est le même moteur
  qui s'exécute dedans, compilé pour Linux.

## Mesuré

Pythia 8.318 construit avec MSVC 14.51 (Visual Studio 2026) sur Windows 11 ARM64, puis, sur 200 événements
e⁻e⁺ → b b̄ à 200 GeV écrits par TreeLevel :

```
treelevel-mc run <dossier>
  → 200 événements gerbés et hadronisés en 1,0 s, aucune erreur Pythia
  → σ = 3.11399 pb, celle du fichier d'entrée, reportée telle quelle dans status.json
  → feyn analyze : 31,9 photons, 24,2 pions, 3,6 kaons et 1,3 nucléon par événement en moyenne,
    2,06 jets (anti-k_T), thrust piqué à 0,95 — deux jets, avec la queue à trois jets du rayonnement de gluon
```

Trois choses seulement manquaient à Pythia pour compiler avec MSVC, et aucune ne demande de toucher à ses
sources : `<dlfcn.h>` et `clock_gettime`, fournis par `compat/`, et trois définitions passées au compilateur
(`_USE_MATH_DEFINES` pour `M_E`, `fjcore_EXPORTS` pour les membres statiques de FJcore, `XMLDIR` pour le
chemin de repli des données).
