#!/bin/bash
# Fabrique un module distribuable à partir d'un préfixe construit localement : arbre relogeable,
# bibliothèques MacPorts embarquées, noms d'installation réécrits, tout signé, image disque notarisée.
#
#   scripts/package_module.sh sherpa3 ~/Library/TreeLevelMC/sherpa3 3.0.5
#   scripts/package_module.sh sherpa3 ~/Library/TreeLevelMC/sherpa3 3.0.5 --no-notarize
#
# Le résultat va dans build/modules/. Les sources correspondantes se publient à part (GPL) :
# voir scripts/package_sources.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=${1:?nom du module}
PREFIX=${2:?préfixe construit}
VERSION=${3:?version}
NOTARIZE=1
[ "${4:-}" = "--no-notarize" ] && NOTARIZE=0
IDENTITY=${IDENTITY:-"Developer ID Application"}
PROFILE=${NOTARY_PROFILE:-TreeLevelMC}

OUT="$(pwd)/build/modules"
STAGE="$OUT/stage/$NAME"
VENDOR="$STAGE/lib/vendor"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Copie de l'arbre"
rm -rf "$STAGE"; mkdir -p "$STAGE" "$OUT"
# Ni les sources ni la documentation : l'utilisateur ne les lira pas, et la GPL est satisfaite par
# l'archive de sources publiée à côté.
# Les deux jeux de PDF que le dépôt de Herwig charge à l'initialisation (CT14lo et CT14nlo) ; les MMHT
# ne sont référencés nulle part dans ses défauts et pèsent 50 Mo pour rien.
EXCLUDES=(--exclude src --exclude 'share/doc' --exclude '*.dSYM' --exclude 'Process'
          # Le dossier de travail par défaut de CalcHEP : le moteur en crée un par travail, et celui-ci
          # contient un lien symbolique absolu que la signature d'un paquet refuse.
          --exclude 'work'
          --exclude 'share/SHERPA-MC/Examples'
          --exclude 'share/LHAPDF/MMHT2014lo68cl' --exclude 'share/LHAPDF/MMHT2014nlo68cl')
# En-têtes, scripts *-config et fichiers d'aide à la compilation : inutiles à l'exécution, et ils portent
# les chemins des bibliothèques contre lesquelles on a compilé. CalcHEP fait exception — lui compile
# vraiment, chez l'utilisateur, et a besoin de ses en-têtes.
if [ ! -f "$PREFIX/mkWORKdir" ]; then
  EXCLUDES+=(--exclude 'include' --exclude 'bin/*-config' --exclude 'bin/activate*'
             --exclude 'share/Herwig/Makefile-UserModules' --exclude 'share/Herwig/Doc'
             --exclude 'share/SHERPA-MC/makelibs'
             # Passerelles vers MadGraph, GoSam, UFO et outils de fusion de grilles : aucun rôle ici, et
             # elles portent le chemin de construction.
             --exclude 'bin/*2herwig' --exclude 'bin/herwig-*'
             # Les dépôts compilés portent des chemins absolus dans un flux binaire, irréparables : le
             # moteur en reconstruit un au premier lancement, à partir des fichiers `defaults`.
             --exclude '*.rpo')
fi
# WHIZARD installe un compilateur d'éléments de matrice par modèle — MSSM, NMSSM, UED, petit Higgs… —, soit
# 450 des 452 Mo de son bin. Le Sindarin que le moteur écrit porte « model = SM » en dur : on garde celui du
# Modèle standard et le pilote générique, on laisse les soixante autres. Les règles d'inclusion passent avant
# l'exclusion, rsync retenant la première qui correspond.
if [ -x "$PREFIX/bin/whizard" ]; then
  EXCLUDES+=(--include 'bin/omega_SM.opt' --include 'bin/omega3.opt' --exclude 'bin/omega_*')
fi
rsync -a "${EXCLUDES[@]}" "$PREFIX/" "$STAGE/"
mkdir -p "$VENDOR"

machos() { find "$1" -type f -perm -u+x -o -type f -name '*.dylib' -o -type f -name '*.so' | sort -u; }
is_macho() { file -b "$1" 2>/dev/null | grep -q "Mach-O"; }

say "Bibliothèques externes"
# Fermeture transitive des dépendances hors du système : tout ce qui vient de /opt/local est embarqué.
take() {                      # copie une bibliothèque dans vendor, une seule fois, puis suit ses propres dépendances
  local source=$1 base; base=$(basename "$source")
  [ -f "$VENDOR/$base" ] && return 0
  cp -f "$source" "$VENDOR/$base"; chmod u+w "$VENDOR/$base"
  echo "  $base"
  collect "$VENDOR/$base"
}

collect() {
  local file=$1 dep base found
  for dep in $(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}'); do
    case "$dep" in
      /opt/local/*|/usr/local/*|/opt/homebrew/*) take "$dep" ;;
      @rpath/*)
        # Une dépendance @rpath que l'arbre ne contient pas se résolvait par un rpath de construction :
        # elle vient d'ailleurs et doit voyager avec nous (Sherpa et libzip, par exemple).
        base=$(basename "$dep")
        found=$(find "$STAGE" -name "$base" -type f -print -quit 2>/dev/null)
        if [ -z "$found" ] && [ ! -f "$VENDOR/$base" ]; then
          for dir in /opt/local/lib /usr/local/lib /opt/homebrew/lib; do
            [ -f "$dir/$base" ] && { take "$dir/$base"; break; }
          done
        fi ;;
    esac
  done
}
for f in $(machos "$STAGE"); do is_macho "$f" && collect "$f"; done

say "Réécriture des chemins"
# Tous les dossiers qui contiennent des bibliothèques, embarquées comprises.
LIBDIRS=$(for d in $(find "$STAGE" -name '*.dylib' -o -name '*.so' | xargs -n1 dirname 2>/dev/null | sort -u); do
            echo "$d"
          done)
LIBDIRS="$VENDOR $LIBDIRS"
rpaths() { otool -l "$1" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/path /{print $2; r=0}'; }

fix() {
  local file=$1 dir rel dep base
  dir=$(dirname "$file")
  # D'abord retirer les rpath de construction — sinon la machine qui a compilé résout tout par accident et
  # le test de relocalisation ment. Les retirer d'abord libère aussi la place de leurs remplaçants : ces
  # binaires n'ont pas été liés avec -headerpad_max_install_names, leur en-tête ne s'étire pas.
  for old_rpath in $(rpaths "$file"); do
    case "$old_rpath" in
      /opt/local/*|/usr/local/*|/opt/homebrew/*|"$PREFIX"*)
        install_name_tool -delete_rpath "$old_rpath" "$file" 2>/dev/null || true ;;
    esac
  done
  # Un rpath par dossier de bibliothèques de l'arbre, plus celui des embarquées : une référence
  # @rpath/libX écrite à la construction ne se résout que si son dossier est nommé. Sherpa range les
  # siennes dans lib/SHERPA-MC, Herwig dans lib/Herwig et lib/ThePEG.
  for target in $LIBDIRS; do
    rel=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$target" "$dir")
    install_name_tool -add_rpath "@loader_path/$rel" "$file" 2>/dev/null || {
      case "$(otool -l "$file" | grep -c "@loader_path/$rel")" in
        0) echo "  ⚠ rpath refusé (en-tête saturé) : $file" >&2 ;;
      esac
    }
  done
  for dep in $(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}'); do
    case "$dep" in
      /opt/local/*|/usr/local/*|/opt/homebrew/*)
        base=$(basename "$dep")
        install_name_tool -change "$dep" "@rpath/$base" "$file" 2>/dev/null || true ;;
      "$PREFIX"/*)
        # Chemin absolu vers notre propre arbre : le rendre relatif au binaire qui le charge.
        local target="${dep#$PREFIX/}"
        local back; back=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$STAGE/$target" "$dir")
        install_name_tool -change "$dep" "@loader_path/$back" "$file" 2>/dev/null || true ;;
    esac
  done
}
for f in "$VENDOR"/*; do
  [ -f "$f" ] && is_macho "$f" && install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
done
for f in $(machos "$STAGE"); do is_macho "$f" && fix "$f"; done

# CalcHEP se repère par la variable CALCHEP, qu'il écrit en dur dans ses scripts à la compilation. Un jeton
# n'y suffirait pas : ces scripts tournent avant que le moteur ne puisse substituer quoi que ce soit, donc
# ils se localisent eux-mêmes. Et le compilateur qu'il invoque pour chaque nouveau processus devient `cc`,
# celui des outils Xcode, présent chez l'utilisateur — pas le gcc de MacPorts, qui ne partira pas avec nous.
if [ -f "$STAGE/mkWORKdir" ]; then
  say "CalcHEP : scripts auto-localisants"
  # La ligne « CALCHEP=<préfixe> » écrite par la compilation est remplacée par une qui se repère seule :
  # ce script tourne avant que le moteur n'ait pu substituer quoi que ce soit.
  python3 - "$STAGE/mkWORKdir" "$PREFIX" <<'PYEOF'
import re, sys
path, prefix = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^\s*CALCHEP=" + re.escape(prefix) + r"\s*$",
              'CALCHEP=$(cd "$(dirname "$0")" && pwd)', text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PYEOF
  # Le compilateur invoqué pour chaque nouveau processus doit exister chez l'utilisateur : `cc` des outils
  # Xcode, et non le gcc de MacPorts, qui ne part pas avec nous.
  for f in "$STAGE/FlagsForMake" "$STAGE/FlagsForSh"; do
    [ -f "$f" ] && /usr/bin/sed -i '' "s|/opt/local/bin/gcc-mp-15|cc|g; s|/opt/local/bin/gfortran-mp-15|gfortran|g" "$f"
  done
fi

say "Chemins de construction dans les fichiers texte"
# configure grave son préfixe dans des fichiers de données (Herwig : defaults/PDF.in). Le remplacer par un
# jeton que le moteur substituera à l'exécution — et, accessoirement, aucun chemin personnel ne part avec
# le paquet.
COUNT=0
while IFS= read -r f; do
  grep -Iq . "$f" 2>/dev/null || continue          # -I : ignorer les fichiers binaires
  if grep -q "$PREFIX" "$f" 2>/dev/null; then
    /usr/bin/sed -i '' "s|$PREFIX|@TREELEVEL_MODULE@|g" "$f"
    COUNT=$((COUNT + 1))
  fi
done < <(find "$STAGE" -type f ! -name '*.rpo' ! -name '*.dylib' ! -name '*.so' ! -name '*.a')
echo "  $COUNT fichiers réécrits"

say "Signature"
# CalcHEP charge des bibliothèques qu'il vient de compiler chez l'utilisateur : elles ne porteront jamais
# notre signature, d'où la dérogation. Les autres n'en ont pas besoin.
#
# Deux fonctions plutôt qu'un tableau : bash 3.2, celui de macOS, traite l'expansion d'un tableau vide
# comme une variable non définie sous `set -u` et interrompt le script — silencieusement, ici, puisque le
# message partait dans un filtre. Toutes les signatures avaient sauté sans que rien ne le dise.
if [ -f "$STAGE/mkWORKdir" ]; then
  sign_one() { codesign --force --options runtime --timestamp \
                        --entitlements "$(pwd)/scripts/calchep.entitlements" --sign "$IDENTITY" "$1"; }
else
  sign_one() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"; }
fi
SIGNED=0
for f in $(machos "$STAGE"); do
  is_macho "$f" || continue
  sign_one "$f" 2>/dev/null || { echo "  échec de signature : $f" >&2; exit 1; }
  SIGNED=$((SIGNED + 1))
done
echo "  $SIGNED fichiers signés"
# Vérifier plutôt que croire : une signature ad hoc passerait la notarisation à la trappe.
ADHOC=$(for f in $(machos "$STAGE"); do
          is_macho "$f" && codesign -dv "$f" 2>&1 | grep -q adhoc && echo "$f"
        done || true)
if [ -n "$ADHOC" ]; then
  echo "  ⚠ restés en signature ad hoc :" >&2
  echo "$ADHOC" | head -5 | sed 's/^/     /' >&2
  exit 1
fi

say "Vérification"
# Rien de ce qui part ne doit porter un chemin de cette machine : ni le préfixe de construction, ni un
# chemin sous le dossier personnel. Le vérifier ici, une fois, vaut mieux que de le découvrir publié.
# `| head` fermerait le tuyau et, sous `set -e` avec pipefail, tuerait le script sans un mot : la coupe
# se fait après coup.
# Un lien symbolique absolu sort du paquet : codesign refuse de signer un bundle qui en contient.
DANGLING=$(find "$STAGE" -type l -lname '/*' 2>/dev/null || true)
if [ -n "$DANGLING" ]; then
  echo "  ⚠ liens symboliques absolus :" >&2
  echo "$DANGLING" | head -10 | sed 's/^/     /' >&2
  exit 1
fi
LEAKS=$(grep -rIl "$HOME" "$STAGE" 2>/dev/null || true)
if [ -n "$LEAKS" ]; then
  echo "  ⚠ chemins personnels encore présents :" >&2
  echo "$LEAKS" | head -20 | sed 's/^/     /' >&2
  exit 1
fi
echo "  aucun chemin personnel"

say "Image disque"
DMG="$OUT/$NAME-$VERSION-macos-$(uname -m).dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format ULFO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  say "Notarisation"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG" | tee -a "$OUT/SHA256SUMS.txt"
say "Prêt : $DMG ($(du -h "$DMG" | cut -f1))"
