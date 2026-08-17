#!/bin/bash
#
# Costruisce CBCTMac.app da questo pacchetto SwiftPM, senza Xcode.
#
# SwiftPM produce un eseguibile nudo. Su macOS un eseguibile nudo che apre finestre SwiftUI
# funziona a metà: non ha identità di bundle, quindi le finestre di dialogo dei file si
# comportano in modo irregolare, non compare fra le applicazioni, non ha icona nel Dock con un
# nome sensato e non può dichiarare i tipi di documento che sa aprire. Serve un vero .app.
#
# Uso:
#   ./Tools/make-app-bundle.sh              # release, il caso normale
#   ./Tools/make-app-bundle.sh debug        # più lento all'uso, ma con i simboli
#
# Il risultato è ./CBCTMac.app, apribile con doppio clic o con `open CBCTMac.app`.

set -euo pipefail

CONFIGURATION="${1:-release}"
BUNDLE_ID="it.raptor7.cbctmac"
VERSION="0.1.0"

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/CBCTMac.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Questo script assembla un bundle macOS e va eseguito su macOS." >&2
    exit 1
fi

echo "▸ Compilazione ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product CBCTMacApp

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/CBCTMacApp"

if [ ! -x "$EXECUTABLE" ]; then
    echo "Eseguibile non trovato in $EXECUTABLE" >&2
    exit 1
fi

echo "▸ Assemblaggio del bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Il nome dell'eseguibile dentro il bundle è quello che appare nel Dock e in Monitoraggio
# Attività, quindi non resta «CBCTMacApp».
cp "$EXECUTABLE" "$APP/Contents/MacOS/CBCTMac"

# Bundle di risorse di SwiftPM: contengono gli shader Metal.
#
# Vengono copiati in **due** posti di proposito. L'accessore `Bundle.module` che SwiftPM genera
# cerca in una lista di candidati che comprende sia `Bundle.main.resourceURL`
# (Contents/Resources) sia la cartella dell'eseguibile; quale dei due vinca dipende dalla
# versione di SwiftPM, e i file in gioco sono tre sorgenti da pochi kilobyte. Duplicarli costa
# nulla e togliere l'incertezza vale più dei kilobyte risparmiati.
shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_PATH"/*.bundle)
if [ ${#RESOURCE_BUNDLES[@]} -eq 0 ]; then
    echo "Nessun bundle di risorse in $BIN_PATH: gli shader Metal mancherebbero." >&2
    exit 1
fi
for resource in "${RESOURCE_BUNDLES[@]}"; do
    cp -R "$resource" "$APP/Contents/Resources/"
    cp -R "$resource" "$APP/Contents/MacOS/"
    echo "  risorse: $(basename "$resource")"
done
shopt -u nullglob

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CBCTMac</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>CBCTMac</string>
    <key>CFBundleDisplayName</key>
    <string>CBCTMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.medical</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Senza questa chiave macOS 14 e successivi stampano a ogni avvio un avviso sul
         ripristino dello stato. Dichiararla evita rumore nella console. -->
    <key>NSSupportsSecureRestorableState</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>CBCTMac — software non certificato come dispositivo medico. Uso non diagnostico.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Piano CBCTMac</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.json</string>
            </array>
        </dict>
        <!-- Una cartella: uno studio DICOM è un insieme di file, non un file singolo, e si
             apre scegliendo la cartella che li contiene. -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>Cartella di studio DICOM</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Firma ad-hoc. Su Apple Silicon un binario non firmato viene ucciso all'avvio; la firma ad-hoc
# non richiede alcun certificato e basta per eseguire l'app sulla macchina che l'ha costruita.
# Per distribuirla ad altri servirebbero un Developer ID e la notarizzazione.
echo "▸ Firma ad-hoc…"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
    || echo "  firma non riuscita: l'app potrebbe non avviarsi su Apple Silicon" >&2

echo
echo "✓ Pronto: $APP"
echo
echo "  open CBCTMac.app"
echo
echo "  All'avvio compare il fantoccio sintetico. Per aprire uno studio vero usa il pulsante"
echo "  «Apri» e scegli la **cartella** che contiene i file DICOM della serie."
