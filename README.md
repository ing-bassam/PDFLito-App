# PDFLito – PDF-Scanner für iPhone

Scannt Dokumente, lässt nur scharfe und lesbare Seiten durch, benennt die PDF nach der größten Überschrift
(oder der Betreffzeile) und speichert sie stark komprimiert – in der App, in einem festen Ordner
(z. B. Google Drive über die Dateien-App) oder an einem beliebigen Ort. Keine Anmeldung, keine Cookies,
kein Tracking, keine Netzwerkverbindung.

## Aufbau

| Bereich | Datei |
| --- | --- |
| Schärfe- und Lesbarkeitsprüfung | `PDFLito/Services/QualityChecker.swift` |
| Texterkennung (auf dem Gerät) | `PDFLito/Services/TextRecognizer.swift` |
| Dateiname aus Überschrift/Betreff, Datum | `PDFLito/Services/TitleExtractor.swift` |
| Schatten entfernen, S/W-Kompression | `PDFLito/Services/ImageProcessor.swift` |
| PDF-Erzeugung (JPEG/1-Bit + unsichtbarer OCR-Text) | `PDFLito/Services/PDFWriter.swift` |
| Speichern in App / Ordner (Google Drive …) | `PDFLito/Services/DocumentLibrary.swift` |
| Oberfläche | `PDFLito/Views/` |

Das Xcode-Projekt wird aus `project.yml` mit [XcodeGen](https://github.com/yonaskolb/XcodeGen) erzeugt.

## Bauen und veröffentlichen (ohne eigenen Mac mit Xcode 26)

Apple nimmt seit 28. April 2026 nur noch Builds mit Xcode 26 an. Deshalb läuft alles in GitHub Actions
auf macOS 26:

- **Build & Test** (`.github/workflows/ci.yml`): bei jedem Push – Unit-Tests im iPhone-Simulator und Screenshots.
- **TestFlight & App Store** (`.github/workflows/release.yml`): manuell starten – archiviert, signiert über
  Apple Cloud Signing, lädt zu TestFlight hoch, lädt Texte und Screenshots hoch und reicht optional zur Prüfung ein.

Einmalig nötig im GitHub-Repository:

| Name | Art | Inhalt |
| --- | --- | --- |
| `ASC_KEY_ID` | Secret | Schlüssel-ID des App-Store-Connect-API-Schlüssels (Rolle „Admin“) |
| `ASC_ISSUER_ID` | Secret | Issuer-ID von derselben Seite |
| `ASC_KEY_P8` | Secret | Inhalt der heruntergeladenen Datei `AuthKey_XXXX.p8` |
| `TEAM_ID` | Variable | Team-ID aus developer.apple.com › Account › Mitgliedschaft |

Außerdem muss der App-Eintrag in App Store Connect angelegt sein (Bundle-ID `de.pdflito.app`),
und Datenschutzangaben („Keine Daten erfasst“), Preis (kostenlos) und Altersfreigabe müssen einmal
im Web ausgefüllt werden.

Datenschutzerklärung, Support-Seite und Impressum liegen in `docs/` (für GitHub Pages).
