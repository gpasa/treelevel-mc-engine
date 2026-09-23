# L'image : les cinq générateurs, prêts à tourner

Pythia 8, Herwig 7, Sherpa 3, WHIZARD 3 et CalcHEP 3. Aucun des quatre derniers n'existe pour Windows, et les
construire à la main demande une soirée à qui voulait seulement gerber quelques événements. L'image les porte
déjà construits, avec le moteur lui-même, et TreeLevel n'a plus qu'à tendre un dossier de travail :

```
docker run --rm -v "<dossier>:/job" ghcr.io/gpasa/treelevel-mc-engine:<version> run /job
```

Le moteur qui tourne dedans est exactement celui de Windows — même code, même protocole. Il lit `/job/job.json`,
écrit `status.json`, `engine.log` et `events.hepmc` dans le même dossier : le montage *est* le protocole, rien
ne passe par le réseau.

## Pour l'utilisateur

```powershell
docker pull ghcr.io/gpasa/treelevel-mc-engine:0.2.0
```

C'est tout — TreeLevel voit alors les cinq générateurs apparaître dans sa liste. L'image n'est
**jamais** tirée sans qu'on le demande : le moteur regarde si elle est là (`docker image inspect`), et si elle
n'y est pas, il ne propose rien plutôt que de lancer un téléchargement d'un gigaoctet dans le dos de quelqu'un.

Il faut Docker Desktop (ou Podman, ou Rancher Desktop) et, sous Windows, la virtualisation activée — elle l'est
d'origine sur une machine réelle. Dans une machine virtuelle, il faut que l'hôte expose la virtualisation
imbriquée : sur un Mac, cela veut dire une puce M3 ou M4 avec Parallels 19+.

## Ce que l'image contient

| | |
|---|---|
| Base | Debian 12 (bookworm) |
| `/opt/treelevel-mc` | Herwig 7 et sa pile (ThePEG, FastJet, LHAPDF, HepMC3) par le bootstrap officiel en `--lite`, puis Sherpa 3, Pythia 8 et WHIZARD 3 dans le même préfixe |
| `/opt/treelevel-mc/calchep` | CalcHEP 3, construit à son emplacement définitif — ses scripts portent des chemins absolus |
| `/opt/treelevel-mc/bin/treelevel-pythia` | notre pilote Pythia, le même fichier que Windows compile avec MSVC |
| `/usr/local/bin/treelevel-mc` | le moteur, compilé pour l'architecture de l'image |
| `/job` | le point de montage du dossier de travail |
| Architectures | `linux/amd64` et `linux/arm64`, réunies sous un seul tag |

`--lite` laisse de côté les bibliothèques de boucles (VBFNLO, MadGraph, LoopTools) : c'est TreeLevel qui fournit
le processus dur, rien ici ne calcule de boucle.

L'image garde un compilateur — `gcc`, `gfortran`, `make` et les en-têtes C —, ce qui est inhabituel pour une
image d'exécution. C'est que WHIZARD écrit du Fortran et CalcHEP du C **pendant le calcul**, pour chaque
processus qu'on leur demande : sans compilateur, ils ne démarrent pas. S'y ajoute `perl-modules-5.36`, dont
`calchep_batch` a besoin, et `libx11-dev` pour le lien que CalcHEP refait à l'exécution.

## Construire l'image

La CI le fait à chaque étiquette `v*` (`.github/workflows/image.yml`), chaque architecture sur un runner de la
même architecture — le bootstrap de Herwig prend une à deux heures nativement et une journée sous émulation.

En local, pour une seule architecture :

```bash
docker build -f docker/Dockerfile -t treelevel-mc-engine:dev .
TREELEVEL_MC_IMAGE=treelevel-mc-engine:dev treelevel-mc capabilities
```

**C'est sur macOS que l'image s'éprouve.** Docker y fait tourner des conteneurs arm64 nativement, sans
virtualisation imbriquée — ce qu'un Windows invité d'un Mac n'a pas et n'aura pas. Une image fraîche se
vérifie en une commande, avec le travail d'essai que porte le dépôt :

```bash
cd docker/test-job
docker run --rm -v "$PWD:/job" ghcr.io/gpasa/treelevel-mc-engine:0.2.0 run /job && cat status.json
```

Attendu : `state` à `finished`, `eventsWritten` à 200, `crossSection` toujours 3.11399 — le générateur gerbe et
hadronise, il ne recalcule pas la section efficace.

La variable `TREELEVEL_MC_IMAGE` dit au moteur quelle image utiliser, ce qui sert à essayer une construction
locale sans toucher à celle qui est publiée.

## Licences et sources

Herwig 7 est sous **GPL-3.0-only**, ThePEG sous **GPL-3.0-or-later**, Sherpa sous **GPL-3.0** (son fichier
`LICENCE` liste en outre des codes tiers sous leurs propres conditions) ; les dépendances embarquées suivent :
GSL (GPL-3), LHAPDF (GPL-3), FastJet (GPL-2), HepMC3 (LGPL-3).

Distribuer ces binaires oblige à publier les sources correspondantes. Elles le sont de trois façons :

1. le `Dockerfile` de ce dossier **est** la recette de construction, et il est versionné ici ;
2. l'image porte `/opt/treelevel-mc/share/treelevel-mc/SOURCES.txt`, la liste des archives exactes que la
   construction a téléchargées — relevée pendant le bootstrap, pas écrite à la main ;
3. le moteur lui-même est dans ce dépôt, sous GPL v3.

```bash
docker run --rm --entrypoint cat ghcr.io/gpasa/treelevel-mc-engine:0.2.0 \
  /opt/treelevel-mc/share/treelevel-mc/SOURCES.txt
```

## Ce que l'image ne porte pas

**Les modèles de WHIZARD autres que le Modèle standard.** WHIZARD installe un compilateur d'éléments de
matrice par modèle qu'il connaît — MSSM, NMSSM, UED, petit Higgs, dimensions supplémentaires : soixante et un
fichiers, 704 Mo, le quart de l'image. Le Sindarin que le moteur écrit porte `model = SM`, et rien dans
TreeLevel n'en propose un autre ; seul `omega_SM.opt` est conservé.

La conséquence, pour être franc : `model = MSSM` glissé dans les réglages supplémentaires échouera. Si ce
besoin apparaît, la ligne `find … -delete` du Dockerfile est à retirer et l'image reprend 650 Mo.

**Les jeux de PDF `cteq6l1` et `CT10`**, que WHIZARD réclame pour son `--enable-lhapdf` : le bootstrap `--lite`
installe CT14lo et CT14nlo, pas ceux-là. Sans objet pour l'e⁺e⁻ que vise TreeLevel ; à revoir le jour où des
faisceaux de hadrons seront au programme.

**Les arbres de compilation.** Le bootstrap laisse 1,8 Go de sources dépliées et d'objets dans `$PREFIX/src` ;
ils sont supprimés avant que l'étape finale ne copie quoi que ce soit. La GPL demande que les sources soient
*disponibles*, non embarquées : elles le restent par ce Dockerfile, par `SOURCES.txt` et par le dépôt.
