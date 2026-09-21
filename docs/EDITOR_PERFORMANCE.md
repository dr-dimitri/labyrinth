# Editorabnahme auf Apple Silicon

Gemessen am 21.09.2026: Mac14,10, Apple M2 Pro, 16 GiB gemeinsamer Speicher,
macOS 27.0 (26A428), optimierter ARM64-Build, 1280 × 800 Pixel. Spielgrafik:
**Ausgewogen**, Editor: SceneKit mit 2× MSAA. Die Anwendung ist auf 30 Bilder/s
begrenzt. Alle Ressourcen waren lokal vorhanden.

Reproduzieren: `make build`, dann
`release/Blacksite.app/Contents/MacOS/BlacksiteMac --editor-check --output-directory /tmp/blacksite-editor-check`.
Der Check erstellt dieselben Beispielrezepte wie die Oberfläche, speichert sie,
liest die Dateien erneut, validiert Navigation, startet die echte Simulation,
zeichnet mit SceneKit und Metal und schreibt JSON sowie Bilder. Die erstellten
Beispiele sind unter `native/Examples/editor-*.blacksite-level.json` versioniert.

## Messergebnisse

| Beispiel | Größe / Instanzen | Speichern | Laden | Auswahl inkl. Inspector | Verschieben inkl. Inspector | Erster Szenenaufbau |
|---|---|---:|---:|---:|---:|---:|
| Übungsgelände | 32 × 32 m / 5 | 1,15 ms | 0,75 ms | 3,11 ms | 4,27 ms | 1,79 ms |
| Außenposten | 64 × 64 m / 13 | 1,59 ms | 1,57 ms | 3,14 ms | 5,86 ms | 2,70 ms |
| Waldgebiet | 128 × 128 m / 500 | 7,72 ms | 10,00 ms | 5,05 ms | 37,32 ms | 27,60 ms |

Auswahl: zehn wechselnde Objekte, Verschieben: fünf Änderungen mit vollständiger
Dokumentvalidierung und Oberflächenaktualisierung. Kein bloßes Timing leerer
Callbacks. Speichern umfasst Schreiben/Synchronisieren/atomisches Umbenennen;
Laden umfasst Lesen, JSON-Decodierung und Integritätsprüfung.

Die reine Auswahlaktualisierung der 500-Objekt-Szene sank von **28,35 auf 0,24 ms**:
Terrain und Geometrie bleiben jetzt erhalten, nur Markierung und Griffe ändern
sich. Ein Regressionstest prüft Identität der Geometrie und korrekten Neuaufbau
nach tatsächlicher Dokumentänderung.

| Beispiel | Editor: serielles Offscreen-Bild | Entsprechende Offscreen-Rate | Spiel: serielles Metal-Bild | GPU-Zeit Spiel |
|---|---:|---:|---:|---:|
| Übungsgelände | 2,31 ms | 434 Bilder/s | 1,70 ms | 1,11 ms |
| Außenposten | 2,74 ms | 364 Bilder/s | 1,72 ms | 1,20 ms |
| Waldgebiet | 4,75 ms | 210 Bilder/s | 2,67 ms | 1,94 ms |

Dies sind **Offscreen-Messungen**, keine Behauptung einer interaktiven Bildrate von
210 Bildern/s. SceneKit misst 30 synchrone Snapshots inklusive CPU-Rücklesen nach
zehn Aufwärmbildern; Metal misst 60 Bilder nach zehn Aufwärmbildern. Das Spiel wurde
vorher eine Sekunde simuliert. Die Messung deckt die Referenzgeometrie und aktuelle
Spielansicht ab, nicht jede denkbare Kampflast. Die tatsächliche Oberfläche bleibt
auf 30 Bilder/s begrenzt; der gemessene Grafikaufwand hat dafür deutlichen Spielraum.

## Speicher und Grenzen

Der letzte Messlauf belegte während des Waldtests rund 268 MiB residenten
Prozessspeicher. Nach zehn vollständigen Laden/Editoraufbau/Spielrenderer/Freigabe-
Zyklen lagen die letzten fünf Messpunkte bei 171,3 / 162,3 / 157,7 / 150,6 / 150,9 MiB.
Die vom Metal-Gerät gemeldete verbleibende Allokation betrug konstant 1,77 MiB.
Ein früherer Lauf lag nach dem Aufwärmen bei etwa 467–489 MiB; residente Seiten
schwanken durch Speicherverwaltung und andere Prozesse. In beiden Läufen entstand
kein fortlaufender Anstieg. Drei zusätzliche echte Editor-Spieltest-Fensterzyklen
prüfen per schwacher Referenz, dass der jeweilige GameCoordinator freigegeben wird
und Dokument/Kamera erhalten bleiben.

**Empfohlener, gemessener Arbeitsumfang: 500 gemischte Objekte auf höchstens
128 × 128 m.** Auswahl bleibt unter 6 ms, vollständige Transformation unter 40 ms
auf dieser Maschine. Deshalb zeigt der Inspector diese Referenz ausdrücklich.
Das Format bewahrt bis zu 1000 Objekte; dieser Speicherhöchstwert ist keine
Leistungszusage für 1000 komplexe Gebäude oder andere Macs. 40 Undo-Schritte,
256 Gruppen/Marker, acht Material- und vier Wasserflächen begrenzen weitere Last.
Prüfen, Beispielaufbau und Bibliothekslesen laufen im Hintergrund mit Abbruch;
Laden/Speichern einzelner begrenzter Dateien liegt hier unter 11 ms.

## Durchgängige Bedienprüfung

Alle drei Beispiele wurden über **Beispiel erstellen** aufgebaut und in der
Bibliothek gespeichert. Nach vollständigem Beenden und Neustart wurden alle drei
über **Eigene Levels → Spielen** geladen, in der echten Simulation gestartet,
pausiert und zum unveränderten Editor zurückgeführt. Keine JSON-Datei wurde dazu
von Hand verändert. Name, Maße, Instanzzahl und Auftrag blieben erhalten.

Die vollständige Core-Suite umfasst 279 Tests. Die native Suite umfasst jetzt 225 Tests,
davon vier separat aktivierbare Audio-/Metaltests; die drei echten Editor-Spieltests
wurden zusätzlich aktiviert. Ein veralteter Hauptmenütest wurde um die neue
Editor-Schaltfläche ergänzt, anschließend bestanden alle sieben HUD-Tests.

Rohdaten: [finaler Lauf](editor-metrics/m2-pro.json),
[Lauf vor Auswahloptimierung](editor-metrics/m2-pro-before-selection-cache.json).
