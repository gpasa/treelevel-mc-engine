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
# Les dépendances d'un binaire, sans les en-têtes : pour un binaire universel, `otool -L` répète le nom du
# fichier suivi de « (architecture arm64): » avant chaque tranche, et cette ligne-là n'est pas une
# bibliothèque. La lire comme telle faisait crier la vérification sur des modules sains.
deps() { otool -L "$1" 2>/dev/null | tail -n +2 | grep -v ':$' | awk '{print $1}'; }
rpaths() { otool -l "$1" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/path /{print $2; r=0}'; }

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
      /usr/lib/*|/System/*) ;;                     # fournies par le système, elles restent dehors
      /*) take "$dep" ;;                           # tout autre chemin absolu manquera chez l'utilisateur
      @rpath/*)
        # Une dépendance @rpath que l'arbre ne contient pas se résolvait par un rpath de construction :
        # elle vient d'ailleurs et doit voyager avec nous (Sherpa et libzip, par exemple).
        base=$(basename "$dep")
        found=$(find "$STAGE" -name "$base" -type f -print -quit 2>/dev/null)
        if [ -z "$found" ] && [ ! -f "$VENDOR/$base" ]; then
          # D'abord là où la construction la trouvait : dans les rpath du fichier, qu'on effacera
          # plus tard. Sans cela, libHepMC3search part d'un module et manque à l'autre.
          for dir in $(rpaths "$file" | grep '^/' || true) /opt/local/lib /usr/local/lib /opt/homebrew/lib; do
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
fix() {
  local file=$1 dir rel dep base
  dir=$(dirname "$file")
  # D'abord retirer les rpath de construction — sinon la machine qui a compilé résout tout par accident et
  # le test de relocalisation ment. Les retirer d'abord libère aussi la place de leurs remplaçants : ces
  # binaires n'ont pas été liés avec -headerpad_max_install_names, leur en-tête ne s'étire pas.
  for old_rpath in $(rpaths "$file"); do
    case "$old_rpath" in
      @*) ;;                                       # relatif au module : c'est ce qu'on veut
      *) install_name_tool -delete_rpath "$old_rpath" "$file" 2>/dev/null || true ;;
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
      /usr/lib/*|/System/*) ;;
      /*)
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
# L'identité d'une bibliothèque est un chemin, elle aussi : celle que la compilation a posée désigne le
# préfixe de construction, qui n'existera pas chez l'utilisateur. On la réécrit pour toutes, pas seulement
# pour les embarquées — CalcHEP livre des .so dont l'identité pointait encore vers l'arbre d'origine.
for f in $(machos "$STAGE"); do
  is_macho "$f" || continue
  case "$(otool -D "$f" 2>/dev/null | tail -1)" in
    /*) install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true ;;
  esac
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
  # Les scripts de CalcHEP ne protègent pas leurs chemins : posés dans « …/Application Support/TreeLevel MC
  # Engine/Modules/calchep3 », chaque espace coupe un mot et tout échoue avec « No such file or directory ».
  # Sans cela CalcHEP ne peut vivre ni dans le dossier de support, ni dans le paquet de l'application, dont
  # le nom porte lui aussi des espaces. On protège donc les trois variables de chemin, en laissant les
  # jokers dehors pour qu'ils s'étendent encore.
  for f in "$STAGE/mkWORKdir" "$STAGE/calchep_batch" "$STAGE/calchep" "$STAGE/bin/run_batch" "$STAGE/sbin/ld_n"; do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PYEOF'
import re, sys
path = sys.argv[1]
texte = open(path, encoding="utf-8", errors="surrogateescape").read()
# run_batch est un script Perl, et « \$CALCHEP/… » vit dans un heredoc : l'échappement le fait traverser
# Perl pour arriver littéral dans le script engendré. Poser un guillemet devant donnerait « \"$CALCHEP" »,
# où Perl interpole alors sa *propre* variable, vide, et le chemin disparaît — le script produit appelle
# « ""/bin/s_calchep ». Les guillemets doivent donc être échappés comme la variable. Seuls les emplois en
# chemin (suivis d'une barre) sont touchés ; la prose des pages d'aide reste telle quelle.
texte = re.sub(r'(?<!")\\\$(CALCHEP|USR)\b(?=/)', r'\\"\\$\1\\"', texte)
# « $CALCHEP/chose » → « "$CALCHEP"/chose » : le guillemet s'arrête avant la barre, donc *.mdl glob encore.
texte = re.sub(r'(?<![\\"])\$(CALCHEP|USR)\b(?!")', r'"$\1"', texte)
# Le même heredoc grave le chemin en clair par une variable Perl : « CALCHEP=$CH_PATH ». Sans guillemets,
# un espace le couperait dès la première ligne du script engendré.
texte = texte.replace('CALCHEP=$CH_PATH\n', 'CALCHEP="$CH_PATH"\n')
# Puis les arguments de position employés comme chemins.
texte = re.sub(r'\b(mkdir|cd|cp -r|cp)\s+\$1\b', r'\1 "$1"', texte)
# mkWORKdir *engendre* deux scripts par un echo entre guillemets : « CALCHEP=$CALCHEP » y devient la
# valeur nue, espaces compris. Il faut que les guillemets arrivent dans le fichier produit, donc les
# échapper ici.
texte = texte.replace('CALCHEP="$CALCHEP"\n', 'CALCHEP=\\"$CALCHEP\\"\n')
open(path, "w", encoding="utf-8", errors="surrogateescape").write(texte)
PYEOF
  done
  echo "  chemins protégés dans les scripts"

  # Les greffons de lib/ (sqme_aux.so, lhapdf.so) portent désormais un nom d'installation « @rpath/… », pour
  # qu'ils suivent le module. Mais leur consommateur, n_calchep, n'est pas construit ici : CalcHEP le lie à
  # chaque processus par sbin/ld_n, qui ne pose aucun rpath. Sans cela le binaire se charge sur « no
  # LC_RPATH's found ». On donne donc à ld_n les deux chemins qu'il connaît : la bibliothèque du module et
  # le dossier du processus, où atterrissent les greffons engendrés.
  if [ -f "$STAGE/sbin/ld_n" ] && ! grep -q -- "-rpath" "$STAGE/sbin/ld_n"; then
    python3 - "$STAGE/sbin/ld_n" <<'PYEOF2'
import sys
chemin = sys.argv[1]
texte = open(chemin, encoding="utf-8").read()
texte = texte.replace('$CC   $CFLAGS   -o n_calchep',
                      '$CC   $CFLAGS   -Wl,-rpath,"$cLib" -Wl,-rpath,"$PWD"   -o n_calchep', 1)
open(chemin, "w", encoding="utf-8").write(texte)
PYEOF2
    echo "  rpath posé dans sbin/ld_n"
  fi

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
# Deux racines à effacer, pas une : le préfixe d'installation, et l'arbre de sources d'où la compilation
# s'est faite. WHIZARD grave le second dans `bin/whizard-gml` — une branche de test qui ne s'exécutera
# jamais chez l'utilisateur, mais un chemin personnel qui partirait avec le paquet, et que la vérification
# refuse à juste titre. On remplace donc aussi tout ce qui pend sous notre racine de construction.
BUILDROOT="$HOME/Library/TreeLevelMC"
COUNT=0
while IFS= read -r f; do
  grep -Iq . "$f" 2>/dev/null || continue          # -I : ignorer les fichiers binaires
  ECRIT=0
  if grep -q "$PREFIX" "$f" 2>/dev/null; then
    /usr/bin/sed -i '' "s|$PREFIX|@TREELEVEL_MODULE@|g" "$f"; ECRIT=1
  fi
  if grep -q "$BUILDROOT" "$f" 2>/dev/null; then
    /usr/bin/sed -i '' "s|$BUILDROOT[^\"' ]*|@TREELEVEL_MODULE@|g" "$f"; ECRIT=1
  fi
  [ "$ECRIT" = 1 ] && COUNT=$((COUNT + 1))
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

# `grep` ne lit que les fichiers texte : il ne voit ni les rpath ni les noms d'installation, qui sont des
# commandes de chargement. C'est par là qu'un module est parti avec un rpath vers l'arbre d'un *autre* :
# Sherpa chargeait alors le HepMC3 de Herwig, mourait dans son propre gestionnaire de signal, et rien ne
# se voyait sur la machine qui avait compilé. On regarde donc aussi les commandes de chargement.
BAD=""
for f in $(machos "$STAGE"); do
  is_macho "$f" || continue
  for r in $(rpaths "$f"); do
    case "$r" in @*) ;; *) BAD="$BAD
  rpath absolu        $r   ($(basename "$f"))" ;; esac
  done
  for d in $(deps "$f"); do
    case "$d" in
      /usr/lib/*|/System/*|@*) ;;
      *) BAD="$BAD
  dépendance absolue  $d   ($(basename "$f"))" ;;
    esac
    case "$d" in
      @rpath/*) base=${d#@rpath/}
        [ -n "$(find "$STAGE" -name "$base" -type f -print -quit 2>/dev/null)" ] || BAD="$BAD
  introuvable         $base   (demandée par $(basename "$f"))" ;;
    esac
  done
done
if [ -n "$BAD" ]; then
  echo "  ⚠ le module ne se suffit pas à lui-même :" >&2
  printf '%s\n' "$BAD" | grep -v '^$' | sort -u | head -25 >&2
  exit 1
fi
echo "  aucune dépendance hors du module, aucune manquante"

say "Image disque"
DMG="$OUT/$NAME-$VERSION-macos-$(uname -m).dmg"
rm -f "$DMG"
# L'image porte un dossier unique, nommé comme le module : l'utilisateur le glisse dans Modules/ et c'est
# fini. Poser l'arbre à la racine du volume l'obligerait à créer le dossier lui-même, à l'orthographier
# juste, et une faute ne se verrait qu'à l'absence du générateur dans la liste.
RACINE="$OUT/stage/dmg-$NAME"
rm -rf "$RACINE"; mkdir -p "$RACINE"
ditto "$STAGE" "$RACINE/$NAME"
cat > "$RACINE/Installation.txt" <<TXTEOF
$NAME $VERSION — module pour TreeLevel Tools

Glissez le dossier « $NAME » dans :

  ~/Library/Application Support/TreeLevel Tools/Modules/

Dans le Finder : menu Aller > Aller au dossier…, puis collez le chemin ci-dessus.
Créez le dossier Modules s'il n'existe pas encore. Gardez le nom « $NAME » tel quel :
c'est ainsi que le moteur reconnaît le générateur.

Relancez ensuite TreeLevel Tools une fois ; le générateur apparaît alors dans TreeLevel.
TXTEOF
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$RACINE" -ov -format ULFO "$DMG"
rm -rf "$RACINE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  say "Notarisation"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG" | tee -a "$OUT/SHA256SUMS.txt"
say "Prêt : $DMG ($(du -h "$DMG" | cut -f1))"
