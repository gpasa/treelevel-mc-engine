# L'image : Herwig 7 et Sherpa 3, prêts à tourner

Ni l'un ni l'autre n'existe pour Windows, et les construire à la main demande une soirée à qui voulait
seulement gerber quelques événements. L'image les porte déjà construits, avec le moteur lui-même, et TreeLevel
n'a plus qu'à tendre un dossier de travail :

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

C'est tout — TreeLevel voit alors Herwig et Sherpa apparaître dans la liste des générateurs. L'image n'est
**jamais** tirée sans qu'on le demande : le moteur regarde si elle est là (`docker image inspect`), et si elle
n'y est pas, il ne propose rien plutôt que de lancer un téléchargement d'un gigaoctet dans le dos de quelqu'un.

Il faut Docker Desktop (ou Podman, ou Rancher Desktop) et, sous Windows, la virtualisation activée — elle l'est
d'origine sur une machine réelle. Dans une machine virtuelle, il faut que l'hôte expose la virtualisation
imbriquée : sur un Mac, cela veut dire une puce M3 ou M4 avec Parallels 19+.

## Ce que l'image contient

| | |
|---|---|
| Base | Debian 12 (bookworm) |
| `/opt/treelevel-mc` | Herwig 7 et sa pile (ThePEG, FastJet, LHAPDF, HepMC3), construits par le bootstrap officiel en mode `--lite`, puis Sherpa 3 dans le même préfixe |
| `/usr/local/bin/treelevel-mc` | le moteur, compilé pour l'architecture de l'image |
| `/job` | le point de montage du dossier de travail |
| Architectures | `linux/amd64` et `linux/arm64`, réunies sous un seul tag |

`--lite` laisse de côté les bibliothèques de boucles (VBFNLO, MadGraph, LoopTools) : c'est TreeLevel qui fournit
le processus dur, rien ici ne calcule de boucle.

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
