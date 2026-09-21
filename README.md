# NACHTGANG — BLACKSITE

Ein nativer 3D-Actionshooter für **macOS auf Apple Silicon**, entwickelt mit Swift, AppKit und Metal.
Die App läuft vollständig offline und enthält ihre Grafik- und Audioressourcen.

## Starten

Voraussetzungen: ein Mac mit Apple Silicon, macOS 13 oder neuer, Xcode Command Line
Tools mit Swift 5.10 oder neuer und Python 3 für die Offline-Ressourcenprüfung.
Für die Tests werden Swift 6 und macOS 14 oder neuer benötigt.

```sh
make run                 # Release-App bauen und starten
make build               # Nur release/Blacksite.app erstellen
make test                # Swift-Tests für Spielregeln und native Anwendung
make verify-assets       # Fotografische Ressourcen offline prüfen
make smoke-test          # App bauen und ein tatsächliches Metal-Bild erzeugen
make benchmark           # Reproduzierbaren CPU-Simulationsbenchmark ausführen
```

Die fertige **`release/Blacksite.app`** lässt sich im Finder öffnen oder in den
Programme-Ordner kopieren. Sie funktioniert unabhängig vom Projektordner. Der Build
erzeugt ausschließlich ARM64, signiert die App lokal ad hoc und
prüft ihre Signatur. Die App ist nicht notarisiert.

Die Skripte sind auch direkt nutzbar:

```sh
./native/scripts/run.sh --debug
./native/scripts/test.sh --filter Grenade
```

[Ausführliche Bauanleitung, Bedienung und Grafikprüfungen](docs/NATIVE_MACOS.md).

## Spielen

- **Fünf Karten:** Blacksite, Nebelwacht, Sundkai, Kessel-9 und Sirocco mit eigenen
  Landschaften, Zugängen und taktischen Möglichkeiten.
- **Aufträge und Einsatzvarianten:** Wellen abwehren, Daten bergen oder Funk sichern;
  Missionsphasen, Vorbereitung und Evakuierung hängen vom gewählten Schauplatz ab.
- **Taktische Umgebung:** Begehbare Hügel, Deckung, Vegetation, Oberflächengeräusche,
  Rauch, Licht, Tore und zerstörbare Zugänge beeinflussen Bewegung und Wahrnehmung.
- **Kampf:** AR-4, M82 mit Zielfernrohr, Granaten, Klettern und liegende Haltung;
  Gegner suchen Wege und reagieren auf Sichtkontakte und Geräusche.
- **Ausrüstung:** Solo-Klassen, Tarnanzüge und Umweltwerkzeuge; ein Einsatzbericht
  hält das Ergebnis fest.
- **Einstellungen:** Anpassbare Tastenbelegung, Maus- und Zielsteuerung,
  Grafikstufen und Audio.

| Eingabe | Standardaktion |
| --- | --- |
| Maus / W A S D | Umsehen / bewegen |
| Umschalttaste / Leertaste | Sprinten / springen |
| C oder Control | Hinlegen / aufstehen |
| Linke Maustaste / Q | Schießen |
| Rechte Maustaste | Zielen / Zielfernrohr |
| 1 / 2 / Mausrad | Waffe wechseln |
| R / G | Nachladen / Granate werfen |
| E | Klettern / an Missionsstationen zum Interagieren halten |
| Escape / F5 | Pause / Leistungsanzeige |

## Projektstruktur

| Pfad | Inhalt |
| --- | --- |
| `native/Sources/BlacksiteCore` | Simulation, Karten, Gelände und Spielregeln |
| `native/Sources/BlacksiteMac` | AppKit-Oberfläche, Metal-Renderer, Eingabe und Audio |
| `native/Tests` | Tests für Spielregeln und native Darstellung |
| `native/Assets` | Lokale Texturen, Soldatenmodell und Herkunftsnachweise |
| `native/AppIcon` | App-Symbol und SVG-Vorlage |
| `native/scripts` | Build, Tests, Ressourcenprüfung und Benchmarks |
| `docs` | Native Dokumentation, Quellen und Prüfprotokolle |

GitHub Actions prüft Tests und Release-Builds auf Apple Silicon und
stellt die ARM64-App als ZIP-Artefakt bereit. Laufende Prüfungen veralteter
Branch-Stände werden bei neuen Änderungen abgebrochen.

Der native [Leveleditor](docs/LEVEL_EDITOR.md) bietet Landschaftswerkzeuge,
46 Objektvorlagen, Gruppen und Undo/Redo, Missionsmarker, direkte Spieltests sowie
eine lokale Levelbibliothek mit Import/Export und Wiederherstellung. Ein externes Beispiellevel lässt
sich bereits über `--level-file native/Examples/training-ground.blacksite-level.json`
laden und spielen.

## Ressourcen und Lizenzen

Der Spielcode steht unter [MIT](LICENSE). Fotografische Materialien und Himmel
stehen unter CC0; für den integrierten SWAT-Charakter gelten gesonderte Bedingungen.
Die [Ressourcendokumentation](docs/ASSETS.md) enthält Herkunft, Lizenzen und
Prüfverfahren. Alle zum Bauen benötigten Spielressourcen sind im Repository
enthalten; ein Download ist nur zur gezielten Wiederherstellung erforderlich.

Weitere Entwicklungs- und Prüfprotokolle:
[Native Grafik und Bedienung](docs/NATIVE_ROADMAP.md),
[Umgebung und Gameplay](docs/ENVIRONMENT_ROADMAP.md).
