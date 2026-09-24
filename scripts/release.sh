#!/bin/bash
# Builds, signs, notarises and packages TreeLevel MC Engine for distribution outside the App Store.
# Everything happens on this machine: the Developer ID key never leaves the keychain.
#
#   scripts/release.sh                 build, sign, notarise, staple, make the disk image
#   scripts/release.sh 0.2.0           the same, with that version number
#   scripts/release.sh --no-notarize   stop after signing (offline check of the build)
#   scripts/release.sh --upload        also create the GitLab release (needs the two variables below)
#
# Prerequisites, done once:
#   • a "Developer ID Application" certificate in the keychain (Xcode › Settings › Accounts › Manage Certificates)
#   • notarisation credentials:  xcrun notarytool store-credentials "TreeLevelMC" \
#         --apple-id <apple id> --team-id 9LVGAJ594U --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${IDENTITY:-"Developer ID Application"}
PROFILE=${NOTARY_PROFILE:-TreeLevelMC}
NOTARIZE=1
UPLOAD=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --upload) UPLOAD=1 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) VERSION=$arg ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- Checks -----------------------------------------------------------------
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
  echo "no '$IDENTITY' certificate in the keychain — create one in Xcode › Settings › Accounts › Manage Certificates" >&2
  exit 1
}
if [ "$NOTARIZE" = 1 ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
    echo "no notarisation credentials named '$PROFILE' — run: xcrun notarytool store-credentials \"$PROFILE\" …" >&2
    exit 1
  }
fi
command -v xcodegen >/dev/null || { echo "xcodegen is needed to generate the project" >&2; exit 1; }

# --- Version ----------------------------------------------------------------
if [ -n "$VERSION" ]; then
  /usr/bin/sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" App/project.yml
  /usr/bin/sed -i '' "s/let engineVersion = \".*\"/let engineVersion = \"$VERSION\"/" Sources/treelevel-mc/main.swift
  /usr/bin/sed -i '' "s/let version = \".*\"/let version = \"$VERSION\"/" App/Sources/EngineApp.swift
else
  VERSION=$(grep -m1 'MARKETING_VERSION' App/project.yml | sed 's/.*"\(.*\)".*/\1/')
fi
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
say "TreeLevel MC Engine $VERSION (build $BUILD)"

OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT"

# --- Build ------------------------------------------------------------------
say "Command line tool"
/usr/bin/swift build -c release
say "Application"
(cd App && xcodegen generate >/dev/null)
xcodebuild -project App/TreeLevelMCEngine.xcodeproj -scheme TreeLevelMCEngine -configuration Release \
  -derivedDataPath App/build CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGNING_ALLOWED=NO | grep -E "error:|warning: unable|BUILD" || true
APP_SRC="App/build/Build/Products/Release/TreeLevel MC Engine.app"
[ -d "$APP_SRC" ] || { echo "the application was not built" >&2; exit 1; }
APP="$OUT/TreeLevel MC Engine.app"
cp -R "$APP_SRC" "$APP"
cp .build/release/treelevel-mc "$APP/Contents/MacOS/treelevel-mc"

# --- Modules -----------------------------------------------------------------
# L'utilisateur n'installe qu'une application : les générateurs voyagent dedans. Ils ont été rendus
# relogeables et signés par scripts/package_module.sh, qui a aussi vérifié qu'aucun chemin de cette
# machine ne les accompagne.
MODULES_SRC="build/modules/stage"
if [ -d "$MODULES_SRC" ]; then
  say "Modules embarqués"
  mkdir -p "$APP/Contents/Resources/Modules"
  for module in "$MODULES_SRC"/*/; do
    name=$(basename "$module")
    rsync -a "$module" "$APP/Contents/Resources/Modules/$name/"
    echo "  $name ($(du -sh "$module" | cut -f1))"
  done
else
  echo "  (aucun module : scripts/package_module.sh n'a pas tourné)"
fi

# --- Sign -------------------------------------------------------------------
# Nested binaries first, then the bundle; hardened runtime and a secure timestamp, both required for notarisation.
say "Signature"
find "$APP/Contents/MacOS" -type f -perm +111 -print0 | while IFS= read -r -d '' binary; do
  [ "$binary" = "$APP/Contents/MacOS/TreeLevel MC Engine" ] && continue
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$binary"
done
# Les modules sont déjà signés — CalcHEP avec sa dérogation de validation de bibliothèques, que
# --force écraserait : ne toucher qu'à ce qui ne l'est pas encore.
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

# --- Notarise the application ------------------------------------------------
ZIP="$OUT/TreeLevelMCEngine-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
if [ "$NOTARIZE" = 1 ]; then
  say "Notarisation de l'application"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
fi

# --- Disk image --------------------------------------------------------------
say "Image disque"
DMG="$OUT/TreeLevelMCEngine-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
cp README.md "$STAGE/Lisez-moi.md"
cp LICENSE "$STAGE/LICENSE"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TreeLevel MC Engine $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ "$NOTARIZE" = 1 ]; then
  say "Notarisation de l'image"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG" || true
fi

# --- Checksums and notes ------------------------------------------------------
(cd "$OUT" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt)
cat > "$OUT/release-notes.md" <<NOTES
# TreeLevel MC Engine $VERSION

Générateurs Monte-Carlo externes pour TreeLevel, sur votre machine — rien ne sort d'ici.

- Glisser \`TreeLevel MC Engine.app\` dans \`/Applications\`, la lancer une fois.
- Installer au moins un générateur (voir le README) :
  - **Pythia 8** et **Herwig 7** habillent les événements de TreeLevel : gerbe, hadronisation, désintégrations.
  - **Sherpa 3**, **WHIZARD 3** et **CalcHEP 3** calculent eux-mêmes le processus décrit par le diagramme.
- TreeLevel propose alors, dans l'espace Génération, ceux qu'il a trouvés.

Signé et notarisé par Apple. Sommes de contrôle dans \`SHA256SUMS.txt\`.
NOTES
say "Prêt"
ls -lh "$OUT" | sed 's/^/  /'

# --- Optional: publish on GitHub ---------------------------------------------
# Le dépôt public est https://github.com/gpasa/treelevel-tools ; `gh` doit être authentifié.
if [ "$UPLOAD" = 1 ]; then
  say "Publication"
  command -v gh >/dev/null || { echo "gh n'est pas installé" >&2; exit 1; }
  gh release create "v$VERSION" --title "TreeLevel MC Engine $VERSION" \
     --notes-file "$OUT/release-notes.md" "$OUT"/*.dmg "$OUT"/*.zip "$OUT/SHA256SUMS.txt" \
     && echo "  release v$VERSION créée"
fi
