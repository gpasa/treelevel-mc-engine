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
