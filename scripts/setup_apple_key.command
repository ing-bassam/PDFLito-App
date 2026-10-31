#!/bin/bash
# Hinterlegt den App-Store-Connect-API-Schlüssel als GitHub-Secrets für PDFLito.
# Per Doppelklick starten, nachdem die Datei AuthKey_XXXXXXXXXX.p8 im Ordner "Downloads" liegt.
set -euo pipefail

REPO="ing-bassam/PDFLito-App"
GH="$HOME/.local/bin/gh"
[ -x "$GH" ] || GH="$(command -v gh)"

echo "PDFLito – Apple-Schlüssel bei GitHub hinterlegen"
echo

KEY_FILE=$(ls -t "$HOME"/Downloads/AuthKey_*.p8 2>/dev/null | head -1 || true)
if [ -z "$KEY_FILE" ]; then
  echo "Keine Datei AuthKey_….p8 im Ordner Downloads gefunden."
  echo "Bitte in App Store Connect › Benutzer und Zugriff › Integrationen einen Schlüssel (Zugriff: Admin) erzeugen und herunterladen."
  read -r -p "Enter zum Schließen"
  exit 1
fi

KEY_ID=$(basename "$KEY_FILE" .p8)
KEY_ID=${KEY_ID#AuthKey_}
echo "Gefunden: $(basename "$KEY_FILE")  (Schlüssel-ID $KEY_ID)"
echo
echo "Die Issuer-ID steht in App Store Connect auf derselben Seite oben über der Schlüsselliste"
echo "(Format: 12345678-1234-1234-1234-123456789012)."
read -r -p "Issuer-ID einfügen und Enter drücken: " ISSUER_ID
ISSUER_ID=$(echo "$ISSUER_ID" | tr -d '[:space:]')
if ! [[ "$ISSUER_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "Das sieht nicht wie eine Issuer-ID aus: $ISSUER_ID"
  read -r -p "Enter zum Schließen"
  exit 1
fi

"$GH" secret set ASC_KEY_P8 -R "$REPO" < "$KEY_FILE"
printf '%s' "$KEY_ID" | "$GH" secret set ASC_KEY_ID -R "$REPO"
printf '%s' "$ISSUER_ID" | "$GH" secret set ASC_ISSUER_ID -R "$REPO"

echo
echo "Fertig. Die drei Secrets sind bei GitHub hinterlegt:"
"$GH" secret list -R "$REPO"
echo
echo "Tipp: Die Datei $(basename "$KEY_FILE") kannst du jetzt an einem sicheren Ort aufbewahren (z. B. Passwort-Manager)."
read -r -p "Enter zum Schließen"
