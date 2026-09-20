#!/usr/bin/env bash
# Costruisce «OpenMRI Dental.app»: il programma che si apre con un doppio clic.
#
# # Perché un involucro e non un'applicazione vera
#
# Il programma è un server locale più una pagina, ed è una buona architettura: il calcolo pesante
# sta in Python, il rendering nel browser, e tutto resta sul computer. Quello che manca non è
# potenza, è **la forma**: un'icona nel Dock, una finestra senza barra degli indirizzi, un doppio
# clic invece di tre comandi nel terminale.
#
# Questo script dà la forma senza toccare la sostanza. Il pacchetto avvia il server come farebbe
# `npm run up` — quindi installa da sé le dipendenze la prima volta — e poi apre una finestra
# dedicata, senza schede e senza barra, con Chrome, Edge o Brave se ce n'è uno; altrimenti ripiega
# sul browser predefinito, che è una finestra normale ma funziona.
#
# Un'applicazione vera — Electron, Tauri — è la strada dopo, e costa duecento megabyte o una
# catena di compilazione in Rust. Questa costa venti secondi e nessuna dipendenza.
#
#   Tools/make-mac-app.sh              costruisce il pacchetto nella radice del repository
#   Tools/make-mac-app.sh --install    lo costruisce e lo copia in /Applications

set -euo pipefail

RADICE="$(cd "$(dirname "$0")/.." && pwd)"
NOME="OpenMRI Dental"
PACCHETTO="$RADICE/$NOME.app"
INSTALLA=0
[ "${1:-}" = "--install" ] && INSTALLA=1

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Questo pacchetto serve a macOS. Su Linux si usa 'npm run up'." >&2
    echo "Lo costruisco lo stesso, così si può controllare che cosa contiene." >&2
fi

rm -rf "$PACCHETTO"
mkdir -p "$PACCHETTO/Contents/MacOS" "$PACCHETTO/Contents/Resources"

# MARK: - L'eseguibile
#
# Sta tutto qui dentro, di proposito: chi vuole sapere che cosa fa il doppio clic apre un file di
# testo e lo legge, invece di doversi fidare di un binario.

cat >"$PACCHETTO/Contents/MacOS/openmri-dental" <<LANCIATORE
#!/bin/bash
# Avvia il server locale e apre la finestra del programma.
REPOSITORY="$RADICE"
LANCIATORE

cat >>"$PACCHETTO/Contents/MacOS/openmri-dental" <<'LANCIATORE'
URL="http://127.0.0.1:4173"
REGISTRO="$HOME/Library/Logs/OpenMRI Dental.log"
mkdir -p "$(dirname "$REGISTRO")"

# Un'applicazione lanciata dal Finder non eredita il PATH del terminale: Homebrew va aggiunto a
# mano, altrimenti «node non trovato» su un computer dove node c'è.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ferma() {
    /usr/bin/osascript -e "display dialog \"$1\" with title \"OpenMRI Dental\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1
    exit 1
}

vivo() { /usr/bin/curl -fsS --max-time 2 "$URL/api/health" 2>/dev/null | grep -q openmri; }

[ -d "$REPOSITORY/web" ] || ferma "Non trovo il programma in $REPOSITORY. Ricostruisci il pacchetto con Tools/make-mac-app.sh."
cd "$REPOSITORY/web" || ferma "Non riesco ad aprire $REPOSITORY/web."

command -v node >/dev/null 2>&1 || ferma "Node.js non è installato. Installalo da nodejs.org, oppure con: brew install node"

if ! vivo; then
    # Il primo avvio installa le dipendenze e compila: sono minuti, e senza un segno sembra che
    # il doppio clic non abbia fatto niente.
    /usr/bin/osascript -e 'display notification "Avvio in corso. Il primo avvio richiede qualche minuto." with title "OpenMRI Dental"' >/dev/null 2>&1
    bash scripts/server.sh start --no-open >>"$REGISTRO" 2>&1 || ferma "Il server non è partito. Il registro è in: $REGISTRO"
fi

for _ in $(seq 1 300); do
    vivo && break
    sleep 1
done
vivo || ferma "Il server non ha risposto. Il registro è in: $REGISTRO"

# Una finestra dedicata, senza schede e senza barra degli indirizzi: è ciò che distingue un
# programma da una pagina web aperta. Il profilo separato evita che la finestra erediti sessioni,
# estensioni e schede del browser di tutti i giorni.
PROFILO="$HOME/Library/Application Support/OpenMRI Dental/window"
for BROWSER in "Google Chrome" "Microsoft Edge" "Brave Browser" "Chromium"; do
    if [ -d "/Applications/$BROWSER.app" ]; then
        open -na "$BROWSER" --args --app="$URL/dental" --user-data-dir="$PROFILO" --window-size=1440,960
        exit 0
    fi
done

# Nessun browser con la modalità finestra: si apre quello predefinito. Funziona uguale, si vede
# la barra degli indirizzi.
open "$URL/dental"
LANCIATORE

chmod +x "$PACCHETTO/Contents/MacOS/openmri-dental"

# MARK: - La carta d'identità del pacchetto

cat >"$PACCHETTO/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NOME</string>
    <key>CFBundleDisplayName</key><string>$NOME</string>
    <key>CFBundleIdentifier</key><string>it.levius29.openmri-dental</string>
    <key>CFBundleExecutable</key><string>openmri-dental</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# MARK: - L'icona
#
# Disegnata da `make-app-icon.py`, che non ha dipendenze. Se `iconutil` non c'è — cioè fuori da
# macOS — il pacchetto resta senza icona invece di fallire: il resto funziona lo stesso.

ICONSET="$(mktemp -d)/AppIcon.iconset"
if python3 "$RADICE/Tools/make-app-icon.py" "$ICONSET" >/dev/null 2>&1; then
    if command -v iconutil >/dev/null 2>&1; then
        iconutil -c icns "$ICONSET" -o "$PACCHETTO/Contents/Resources/AppIcon.icns"
    else
        echo "iconutil non c'è: il pacchetto resta senza icona." >&2
        cp "$ICONSET/icon_512x512.png" "$PACCHETTO/Contents/Resources/AppIcon.png" 2>/dev/null || true
    fi
else
    echo "Non sono riuscito a disegnare l'icona; il pacchetto la fa senza." >&2
fi
rm -rf "$(dirname "$ICONSET")"

echo "Fatto: $PACCHETTO"

if [ "$INSTALLA" = "1" ]; then
    rm -rf "/Applications/$NOME.app"
    cp -R "$PACCHETTO" "/Applications/"
    echo "Copiato in /Applications/$NOME.app"
    echo "Ora sta nel Launchpad: doppio clic e parte."
else
    echo "Trascinalo in Applicazioni, oppure rilancia con --install."
fi
