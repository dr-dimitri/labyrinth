# NACHTGANG auf macOS und Windows

Die Desktop-App bündelt das Spiel mit Electron. Spielgrafik, Labyrinthgenerator und Audio laufen lokal; eine Internetverbindung ist beim Spielen nicht erforderlich. Zum Erstellen werden Node.js 22.12 oder neuer, npm und ein Internetzugang für die Build-Abhängigkeiten benötigt. Erstelle macOS-Pakete auf einem Mac und Windows-Pakete auf Windows.

## Lokal starten

Im Projektverzeichnis:

```sh
npm ci
npm run desktop
```

`desktop` erstellt zuerst die Spieldateien und öffnet anschließend das Anwendungsfenster. Änderungen am Quellcode werden beim nächsten Start übernommen. Für die Entwicklung mit automatischer Aktualisierung im Browser: `npm run dev`.

Das Menü **Ansicht → Vollbild** schaltet zwischen Fenster und Vollbild um: unter macOS mit **Ctrl + Cmd + F**, unter Windows mit **F11**. **Esc** bleibt der Spielpause und dem Freigeben der Maus vorbehalten. Auf Windows blendet **Alt** die Menüleiste ein. Nach dem Schließen des letzten Fensters bleibt die App unter macOS im Dock; **Cmd + Q** beendet sie.

## Installationspakete erstellen

```sh
npm test
npm run dist -- --publish never
```

Die Dateien erscheinen unter `release/`. Standardmäßig wird die Architektur des Build-Rechners verwendet.

| System | Ausgabe |
| --- | --- |
| macOS | `.dmg` und `.zip` mit `NACHTGANG.app` |
| Windows | `…-Setup.exe` mit Installationsassistent und `…-Portable.exe` ohne Installation |

Für eine bestimmte Zielarchitektur:

```sh
# Auf macOS: Apple Silicon beziehungsweise Intel
npm run dist -- --mac --arm64 --publish never
npm run dist -- --mac --x64 --publish never

# Auf Windows: 64 Bit
npm run dist -- --win --x64 --publish never
```

Für einen schnellen lokalen Test kann nur der entpackte Anwendungsordner gebaut werden:

```sh
npm run dist -- --dir --publish never
```

Auf Apple Silicon liegt die App danach unter `release/mac-arm64/NACHTGANG.app`, auf Intel-Macs unter `release/mac/NACHTGANG.app` und auf Windows unter `release/win-unpacked/NACHTGANG.exe`. Die Windows-Anwendung benötigt die übrigen Dateien in ihrem Ordner; zum Weitergeben eignet sich das vollständige Installations- oder Portable-Paket.

## Automatische Builds

Der Workflow `.github/workflows/build.yml` prüft das Spiel mit `npm ci`, `npm test` und `npm run build` und erzeugt anschließend separate Pakete auf macOS für Apple Silicon und Intel sowie auf Windows für x64. Er startet bei Pull Requests, Änderungen auf `main`/`master`, Versions-Tags und manuell über **Actions → Desktop builds → Run workflow**. Nach erfolgreichem Lauf stehen die Installer 14 Tage als Workflow-Artefakte bereit. Es wird kein Release veröffentlicht; eigene Signatur-Secrets sind für diese Entwicklungsbuilds nicht erforderlich.

## Entwicklungsbuilds und Veröffentlichung

macOS-Builds erhalten eine lokale Ad-hoc-Signatur, sind aber weder mit einer Developer ID signiert noch von Apple notarisiert. Windows-Builds haben kein Herausgeberzertifikat. Deshalb können heruntergeladene Pakete von Gatekeeper beziehungsweise SmartScreen beanstandet werden. Diese Build-Konfiguration dient lokalen Tests und einer kontrollierten Testphase.

Für eine öffentliche Veröffentlichung werden die macOS-Signatur und Notarisierung sowie eine Windows-Codesignatur als eigener Release-Schritt eingerichtet. Dabei müssen unter `mac` die Entwicklungswerte `identity: '-'`, `hardenedRuntime: false` und `notarize: false` durch die passende Signaturkonfiguration ersetzt werden. Die offizielle [Electron-Anleitung zur Codesignatur](https://www.electronjs.org/docs/latest/tutorial/code-signing) beschreibt die Verteilung auf beiden Systemen.

Die Desktop-Hülle aktiviert Renderer-Sandbox und Context Isolation, deaktiviert Node.js im Spielfenster und blockiert Navigation, neue Fenster und Netzwerkzugriffe. Mausfang und Vollbild sind nur für die lokale Spielseite erlaubt. Hintergrund: [Electron-Sicherheitsempfehlungen](https://www.electronjs.org/docs/latest/tutorial/security).
