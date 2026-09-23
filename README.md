# TreeLevel MC Engine

Gerbe partonique et hadronisation des événements produits par [TreeLevel](https://treelevel.pasahome.org),
sur votre machine. TreeLevel écrit ses événements au niveau partonique dans un dossier local ; ce programme les
passe à **Pythia 8** ou **Herwig 7** et réécrit le résultat en HepMC3, que TreeLevel relit. Rien ne transite par
le réseau, aucun compte, aucun service.

Il est distribué séparément parce que Pythia et Herwig sont sous licence **GPL** : ce dépôt est GPL v3, TreeLevel
ne contient aucun de leur code.

## Ce que ça fait

```
TreeLevel                    dossier de travail                 TreeLevel MC Engine
  σ, |M|², événements  →   job.json + events.lhe       →   Pythia 8 / Herwig 7
  histogrammes, détecteur  ←   events.hepmc + status.json  ←   gerbe, hadronisation, désintégrations
```

Le dossier de travail est dans le conteneur de TreeLevel
(`~/Library/Containers/org.pasahome.Feyn/Data/Library/Application Support/MCJobs/<id>`) : les deux programmes y
accèdent, personne d'autre.

## Où vivent les exécutables

Une seule règle : **tout ce qui se lance est dans `~/Applications`** — `TreeLevel MC Engine.app` et, pendant le
développement, `TreeLevel (dev).app`. Les dossiers `build/` et `.build/` des dépôts ne contiennent que des
résultats de compilation jetables ; `scripts/install.sh` dépose la version bonne à l'emploi dans
`~/Applications` et retire les copies de compilation du registre de LaunchServices, pour qu'elles ne soient
jamais lancées par erreur. `/Applications` reste réservé aux applications installées par l'App Store.

```bash
scripts/install.sh      # construit et installe dans ~/Applications, avec le module Pythia
scripts/release.sh      # construit, signe, notarise et fabrique le .dmg à distribuer
```

## Installation

1. Télécharger `TreeLevel MC Engine.app` depuis les *releases* et la glisser dans `/Applications`.
2. Installer un générateur :
   - **Pythia 8** — `sudo port install pythia` (MacPorts), puis `make -C Backends/pythia install` : cela
     construit le petit pilote `treelevel-pythia` et le place dans
     `~/Library/Application Support/TreeLevel MC Engine/Modules/pythia8/`. Le Makefile trouve Pythia par
     `pythia8-config` s'il existe, sinon dans les dispositions habituelles de MacPorts, de Homebrew ou d'une
     compilation locale. **HepMC3 n'est pas nécessaire** : le pilote écrit lui-même le fichier HepMC3 (le port
     `pythia` de MacPorts ne fournit ni Pythia8Plugins ni HepMC3). Avec un Pythia compilé avec son interface
     HepMC3, `make WITH_HEPMC3=1` l'utilise à la place.
   - **Herwig 7** — il n'existe pas de port MacPorts ; utiliser le script d'installation officiel
     (`herwig-bootstrap`) ou un autre gestionnaire. Le moteur cherche `Herwig` dans
     `~/Library/Application Support/TreeLevel MC Engine/Modules/herwig7/bin`, puis dans `/opt/local/bin`,
     `/usr/local/bin` et `/opt/homebrew/bin`, et ignore une installation cassée (bibliothèque manquante).
3. Lancer l'application une fois : elle écrit `capabilities.json` dans son dossier de support, et TreeLevel
   propose alors les générateurs trouvés.

## En ligne de commande

```bash
swift build -c release
.build/release/treelevel-mc capabilities          # ce que cette installation sait faire
.build/release/treelevel-mc run /chemin/du/dossier  # exécute job.json
```

Le dossier contient `job.json` (généré par TreeLevel, format décrit dans `Protocol/MCEngineProtocol.swift`),
`events.lhe` en entrée, puis `status.json`, `engine.log` et `events.hepmc` en sortie.

Chaque travail reçoit un numéro (compteur gardé dans le dossier de support), l'heure de début et de fin, et
s'ajoute à la liste `jobs.json` que la fenêtre affiche — elle survit aux relancements, un clic droit sur une
ligne ouvre le dossier du travail ou son journal, et « Vider la liste » l'oublie sans rien effacer sur le disque.

Trois générateurs : `pythia8`, `herwig7` et `passthrough` (aucune gerbe — les événements sont convertis tels
quels, pour vérifier la chaîne ou comparer avec le processus dur).

## Construire le pilote Pythia

`Backends/pythia/main.cpp` est un programme d'une centaine de lignes : il lit le fichier de commandes écrit par
le moteur et écrit le HepMC3. Il faut Pythia 8 compilé avec HepMC3.

```bash
make -C Backends/pythia          # ./treelevel-pythia
make -C Backends/pythia install  # dans Modules/pythia8/
```

## Construire le module Herwig 7

Aucun gestionnaire de paquets macOS ne fournit Herwig : ni MacPorts, ni Homebrew hors d'un tap non maintenu
(dont les binaires sont liés à une version de GSL qui n'existe plus). Il se construit donc depuis les sources,
avec le bootstrap officiel, et quatre précautions que la chaîne d'outils de 2026 impose :

```bash
# gcc de MacPorts, jamais clang : les constructeurs globaux de ThePEG appellent std::string avant que
# l'initialiseur de libc++ ait tourné, et l'allocation typée d'Apple clang 21 avorte à cet endroit précis.
printf '#!/bin/sh\nexec /opt/local/bin/gfortran-mp-15 -fno-range-check "$@"\n' > ~/Library/TreeLevelMC/tools/gfortran-tl
chmod +x ~/Library/TreeLevelMC/tools/gfortran-tl

curl -LO https://herwig.hepforge.org/downloads/herwig-bootstrap
env PATH="$HOME/Library/TreeLevelMC/tools:/opt/local/bin:/usr/bin:/bin" \
    CC=/opt/local/bin/gcc-mp-15 CXX=/opt/local/bin/g++-mp-15 FC="$HOME/Library/TreeLevelMC/tools/gfortran-tl" \
    python3.13 herwig-bootstrap --lite -j 12 \
      --with-gsl=/opt/local --with-boost=/opt/local \
      --with-fastjet="$HOME/Library/TreeLevelMC/herwig7" \
      "$HOME/Library/TreeLevelMC/herwig7"

ln -s ~/Library/TreeLevelMC/herwig7 ~/Library/Application\ Support/TreeLevel\ MC\ Engine/Modules/herwig7
```

Les quatre pièges, pour mémoire :

- **FastJet** : le greffon `D0RunIICone`, activé par `--enable-allcxxplugins`, ne compile plus (`this->_Et`,
  recherche de nom en deux phases). Herwig n'en a pas besoin : construire FastJet à part sans les greffons
  optionnels, et le passer par `--with-fastjet`.
- **LHAPDF** : son enrobage Python ne trouve pas `libpython` dans un *framework* MacPorts. Configurer avec
  `--disable-python` — et récupérer alors les jeux de PDF à la main, le script `lhapdf install` important ce
  même module.
- **ThePEG** : voir ci-dessus, d'où gcc plutôt que clang. Toute la pile (FastJet, HepMC3, LHAPDF) doit suivre,
  sans quoi les ABI C++ ne s'accordent pas.
- **LoopTools** : `parameter (nz2 = -2147483648)` déborde pour gfortran 15, d'où le `-fno-range-check` glissé
  dans le compilateur enrobé — `configure` écrase `FCFLAGS`, le drapeau ne peut pas passer par l'environnement.

Le dossier `lib/ThePEG` contient des greffons liés à `@rpath/libHepMC3`, dont le rpath est celui de la machine
de construction ; le moteur pose `DYLD_FALLBACK_LIBRARY_PATH` sur les `lib` du module, donc il n'y a rien à
retoucher.

Mesuré sur un e⁻e⁺ → W⁺W⁻ à 200 GeV, 10 000 événements partoniques écrits par TreeLevel : **12,2 s** de
cascade et d'hadronisation (Pythia 8 : 6,4 s).

## Construire les modules Sherpa, WHIZARD et CalcHEP

Tous avec le même gcc 15 de MacPorts que Herwig — les ABI C++ doivent s'accorder — et en réutilisant les
HepMC3, LHAPDF et FastJet installés dans le préfixe `herwig7`.

```bash
export PATH=/opt/local/bin:/usr/bin:/bin
export CC=/opt/local/bin/gcc-mp-15 CXX=/opt/local/bin/g++-mp-15 FC=/opt/local/bin/gfortran-mp-15
DEPS=~/Library/TreeLevelMC/herwig7

# Sherpa 3.0.5 — CMake. `_Static_assert` est un mot-clé du C que clang accepte aussi en C++ et
# que gcc refuse ; mach/port.h s'en sert, et ATOOLS/Org/RUsage.C inclut mach/mach.h.
cmake -S . -B build -DCMAKE_INSTALL_PREFIX=~/Library/TreeLevelMC/sherpa3 \
  -DCMAKE_CXX_FLAGS="-D_Static_assert=static_assert" \
  -DSHERPA_ENABLE_LHAPDF=ON -DLHAPDF_DIR=$DEPS \
  -DSHERPA_ENABLE_HEPMC3=ON -DHepMC3_DIR=$DEPS \
  -DSHERPA_ENABLE_FASTJET=ON -DFASTJET_DIR=$DEPS
cmake --build build -j 12 && cmake --install build

# WHIZARD 3.1.6 — autotools, OCaml de MacPorts pour O'Mega. mcfio/StdHEP mélange long et int32_t
# dans ses appels XDR, ce dont gcc 15 fait des erreurs.
export CFLAGS="-O2 -std=gnu17 -Wno-incompatible-pointer-types -Wno-implicit-function-declaration -Wno-int-conversion"
./configure --prefix=~/Library/TreeLevelMC/whizard3 --with-hepmc=$DEPS --with-lhapdf=$DEPS \
            --with-fastjet=$DEPS --disable-latex && make -j 12 && make install

# CalcHEP 3.9.2 — un simple make, mais il faut le construire là où il vivra : ses bibliothèques
# portent leur chemin absolu.
make
```

Puis un lien depuis le dossier de modules, comme pour Herwig :

```bash
cd ~/Library/Application\ Support/TreeLevel\ MC\ Engine/Modules
ln -s ~/Library/TreeLevelMC/sherpa3 ~/Library/TreeLevelMC/whizard3 ~/Library/TreeLevelMC/calchep3 .
```

### Ce que chacun attend

Sherpa, WHIZARD et CalcHEP n'ont pas de lecteur Les Houches : on leur décrit le processus (`MCProcess`
du protocole) et ils calculent tout eux-mêmes. Trois détails appris à leurs dépens :

- **Sherpa** écrit son HepMC3 dans le fichier dont on lui donne le nom de base, et sa section efficace dans
  la ligne `C` du format Asciiv3.
- **WHIZARD** refuse `?ps_isr_active` ailleurs que sur une collision hadronique, et n'écrit aucune section
  efficace dans son HepMC3 : elle se lit dans la dernière ligne de sa table d'intégration, en femtobarns.
  Le rayonnement QED d'un faisceau leptonique est `?isr_active`, laissé éteint — il déplacerait σ.
- **CalcHEP** s'arrête au niveau partonique : ni gerbe ni hadronisation. Un travail tourne dans une copie
  de son arbre faite par `mkWORKdir`, et ses événements Les Houches gzippés sont convertis en HepMC3 par
  le même code que le passe-plat.

### Mesuré : e⁻e⁺ → W⁺W⁻ à 200 GeV

| moteur | σ | remarque |
|---|---|---|
| TreeLevel | 19,22 pb | à l'arbre, M_W imposée par G_F |
| WHIZARD 3.1.6 | 19,441 ± 0,006 pb | O'Mega, schéma propre |
| CalcHEP 3.9.2 | 20,42 pb | autre schéma de couplages |
| Sherpa 3.0.5 | 18,2 ± 1,1 pb | rayonnement initial QED activé par défaut |

Les écarts sont des choix de schéma, pas des erreurs : le couplage entre à la puissance quatre.

## Publier une version

Tout se passe sur la machine du développeur : la clé Developer ID ne quitte pas le trousseau, rien n'est confié
à un service d'intégration continue.

```bash
scripts/release.sh                 # construit, signe, notarise, agrafe, fabrique le .dmg
scripts/release.sh 0.2.0           # idem en fixant le numéro de version (project.yml et sources)
scripts/release.sh --no-notarize   # s'arrête après la signature, pour vérifier hors ligne
scripts/release.sh --upload        # crée en plus la release GitLab (GITLAB_PROJECT et GITLAB_TOKEN)
```

Préalables, une seule fois :

- un certificat **Developer ID Application** dans le trousseau (Xcode › Réglages › Comptes › Gérer les
  certificats) — il est inclus dans l'adhésion au programme développeur, il n'y a rien de plus à payer ;
- les identifiants de notarisation :
  `xcrun notarytool store-credentials "TreeLevelMC" --apple-id <identifiant> --team-id 9LVGAJ594U --password <mot de passe pour app>`.

Le script produit dans `build/release/` : l'application signée et agrafée, le `.dmg` (avec un lien vers
`/Applications`, le README et la licence), le `.zip`, `SHA256SUMS.txt` et un brouillon de notes de version.
La vérification finale, `spctl -a -t open --context context:primary-signature -v`, doit répondre `accepted`.

## Licence

GNU General Public License v3 ou ultérieure — voir `LICENSE`. Le fichier `Protocol/MCEngineProtocol.swift`,
partagé avec TreeLevel, est sous licence MIT (voir son en-tête) pour que les deux programmes puissent le lire.

## Windows

Le port Windows est dans [`win/`](win/) : le moteur en C#, le module Pythia 8 construit avec MSVC (`win/backends/pythia`),
Herwig et Sherpa dans WSL. Le protocole est le même : un dossier de travail écrit sur un Mac se relit sur
Windows et inversement. Voir [`win/README.md`](win/README.md).
