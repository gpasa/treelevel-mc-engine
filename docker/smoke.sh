#!/bin/sh
# Éprouve une image : les six générateurs, un vrai travail pour chacun, et la section efficace qu'il rend.
#
#   docker/smoke.sh ghcr.io/gpasa/treelevel-mc-engine:0.2.0
#
# La CI le lance sur un runner de chaque architecture, et il se lance aussi bien à la main — c'est la même
# suite des deux côtés, ce qui évite qu'elles divergent. Rien n'est écrit dans le dépôt : chaque travail part
# dans un dossier temporaire.
#
# Les bornes sur σ sont larges à dessein. Il ne s'agit pas de mesurer la physique — le Mac l'a fait, et les
# écarts entre générateurs sont expliqués — mais d'attraper un générateur qui se tairait en rendant zéro, ou
# qui rendrait un nombre sans rapport.
#
# Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later.

set -eu
image="${1:?usage: smoke.sh <image>}"
ici=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
travail=$(mktemp -d)
trap 'rm -rf "$travail"' EXIT
echecs=0

lire() {                       # lire <fichier> <clé>  → la valeur JSON, sans dépendre de jq
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\).*/\1/p' "$1" | head -1
}

essai() {                      # essai <générateur> <modèle> <σ min> <σ max>
  generateur=$1; modele=$2; bas=$3; haut=$4
  dossier="$travail/$generateur"
  mkdir -p "$dossier"
  cp "$ici/$modele/job.json" "$dossier/job.json"
  [ -f "$ici/$modele/events.lhe" ] && cp "$ici/$modele/events.lhe" "$dossier/"
  # Pas de « sed -i » : BSD le veut avec un argument et GNU sans, et cette suite tourne des deux côtés.
  sed "s/\"generator\"[[:space:]]*:[[:space:]]*\"[a-z0-9]*\"/\"generator\" : \"$generateur\"/" \
      "$dossier/job.json" > "$dossier/job.tmp" && mv "$dossier/job.tmp" "$dossier/job.json"

  if ! docker run --rm -v "$dossier:/job" "$image" run /job > "$dossier/sortie.txt" 2>&1; then
    printf '%-12s ÉCHEC — le moteur a rendu un code non nul\n' "$generateur"
    tail -3 "$dossier/sortie.txt" | sed 's/^/             /'
    echecs=$((echecs + 1)); return
  fi
  etat=$(lire "$dossier/status.json" state)
  n=$(lire "$dossier/status.json" eventsWritten)
  sigma=$(lire "$dossier/status.json" crossSection)
  version=$(lire "$dossier/status.json" generatorVersion)
  if [ "$etat" != "finished" ] || [ "${n:-0}" -le 0 ]; then
    printf '%-12s ÉCHEC — état « %s », %s événements\n' "$generateur" "$etat" "${n:-0}"
    echecs=$((echecs + 1)); return
  fi
  # La comparaison en flottant se fait avec awk : le shell ne sait compter qu'en entiers.
  if ! awk -v s="${sigma:-0}" -v b="$bas" -v h="$haut" 'BEGIN { exit !(s >= b && s <= h) }'; then
    printf '%-12s ÉCHEC — σ = %s, attendue entre %s et %s pb\n' "$generateur" "${sigma:-néant}" "$bas" "$haut"
    echecs=$((echecs + 1)); return
  fi
  printf '%-12s %4s év.  σ = %-12s %s\n' "$generateur" "$n" "$sigma" "$version"
}

printf '=== %s\n' "$image"
docker run --rm "$image" capabilities > "$travail/capabilities.json"
for g in passthrough pythia8 herwig7 sherpa3 whizard3 calchep3; do
  if ! grep -q "\"$g\"" "$travail/capabilities.json"; then
    printf '%-12s ABSENT de capabilities\n' "$g"; echecs=$((echecs + 1))
  fi
done

# Les trois qui lisent les événements de TreeLevel rendent la section efficace du fichier, intacte.
essai passthrough test-job        3.1139 3.1140
essai pythia8     test-job        3.1139 3.1140
essai herwig7     test-job        3.1139 3.1140
# Les trois qui calculent leur propre élément de matrice rendent la leur.
essai sherpa3     test-job-sherpa 10     30
essai whizard3    test-job-sherpa 2.5    3.6
essai calchep3    test-job-sherpa 2.5    3.6

if [ "$echecs" -gt 0 ]; then printf '\n%d échec(s)\n' "$echecs"; exit 1; fi
printf '\nles six générateurs répondent\n'
