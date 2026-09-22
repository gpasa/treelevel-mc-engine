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

## Installation

1. Télécharger `TreeLevel MC Engine.app` depuis les *releases* et la glisser dans `/Applications`.
2. Installer un générateur :
   - **Pythia 8** — `brew install pythia` (ou MacPorts, ou une compilation locale), puis
     `make -C Backends/pythia install` pour construire le petit pilote `treelevel-pythia` et le placer dans
     `~/Library/Application Support/TreeLevel MC Engine/Modules/pythia8/`.
   - **Herwig 7** — `brew install herwig` (ou l'installation officielle) ; le moteur cherche `Herwig` dans les
     emplacements habituels et dans `~/Library/Application Support/TreeLevel MC Engine/Modules/herwig7/bin`.
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

Trois générateurs : `pythia8`, `herwig7` et `passthrough` (aucune gerbe — les événements sont convertis tels
quels, pour vérifier la chaîne ou comparer avec le processus dur).

## Construire le pilote Pythia

`Backends/pythia/main.cpp` est un programme d'une centaine de lignes : il lit le fichier de commandes écrit par
le moteur et écrit le HepMC3. Il faut Pythia 8 compilé avec HepMC3.

```bash
make -C Backends/pythia          # ./treelevel-pythia
make -C Backends/pythia install  # dans Modules/pythia8/
```

## Licence

GNU General Public License v3 ou ultérieure — voir `LICENSE`. Le fichier `Protocol/MCEngineProtocol.swift`,
partagé avec TreeLevel, est sous licence MIT (voir son en-tête) pour que les deux programmes puissent le lire.
