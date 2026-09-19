# Native macOS-Anwendung

Die native Ausgabe von **NACHTGANG — BLACKSITE** verwendet Swift, AppKit und Metal. Sie enthält weder Electron noch Chromium, JavaScript oder einen lokalen Webserver. Die Browser- und Electron-Ausgaben bleiben eigenständige Startmöglichkeiten im Projekt.

## 1. Voraussetzungen

- macOS 13 oder neuer und eine Metal-fähige GPU.
- Xcode Command Line Tools mit Swift 5.10 oder neuer; bei Bedarf mit `xcode-select --install` installieren.
- Für Spiel und Grafikprüfung eine angemeldete grafische macOS-Sitzung.

Der Build verwendet die Architektur des ausführenden Macs. Auf Apple Silicon entsteht eine ARM64-App. Auf einem Intel-Mac kann derselbe Quellcode mit einem passenden Apple-SDK als x86_64 gebaut werden; ein Universal-Binary wird durch dieses Skript nicht erzeugt.

## 2. Optimierte App erstellen

Im Projektordner:

```bash
./native/scripts/build-app.sh
```

Das Ergebnis liegt in `release/Blacksite.app`. Diese App lässt sich im Finder doppelklicken oder in den persönlichen Programme-Ordner kopieren. Sie enthält die verwendeten Texturen und läuft ohne Verbindung zum Internet und ohne die Quelldateien des Projekts.

Das Skript baut standardmäßig die Swift-Release-Konfiguration. Compiler- und Paket-Caches liegen unter `native/.build`; wiederholte Builds können sie wiederverwenden. Die nativen Landschaftsressourcen aus `native/Assets` werden vollständig mitgeliefert. Unverwendete Web-Ressourcen und Modelle bleiben außerhalb der App.

Zum Bauen und unmittelbaren Starten:

```bash
./native/scripts/run.sh
```

## 3. Steuerung

Die Tabelle zeigt die Standardbelegung. Unter **Einstellungen → Tasten** lassen
sich bis zu zwei Eingaben je Spielaktion zuweisen: normale Tasten, Shift/Control/Alt,
die ersten fünf Maustasten und für Einzelaktionen das Mausrad. Escape und F5 sowie
macOS-Systemtasten bleiben reserviert. Bei einer bereits belegten Eingabe wird der
Konflikt angezeigt; ein Tausch muss ausdrücklich gewählt werden. Tastenbezeichnungen
folgen dem aktuellen macOS-Tastaturlayout.

| Eingabe | Aktion |
| --- | --- |
| Maus | Blickrichtung |
| W, A, S, D | Bewegen |
| Umschalttaste | Sprinten |
| Leertaste | Springen |
| C oder Control | Hinlegen / aufstehen |
| E | Klettern; an einer Missionsstation zum Interagieren halten |
| Linke Maustaste / Q | Schießen |
| Rechte Maustaste halten | Zielen; beim Scharfschützengewehr durch das Zielfernrohr |
| 1 / 2 / Mausrad | Sturmgewehr / Scharfschützengewehr wechseln |
| R | Nachladen |
| G | Handgranate werfen |
| Escape | Pausieren / Maus freigeben |
| F5 | Leistungsanzeige ein-/ausblenden |

Pfeil hoch/runter bewegt vorwärts/rückwärts; Pfeil links/rechts dreht den Blick.
Bild hoch/runter steuert den vertikalen Blick. Das Feldhandbuch zeigt alle aktuell
belegten Alternativen. HUD, Kletter- und Missionshinweise verwenden dieselben
Belegungen.

Unter **Einstellungen → Maus** sind freier Blick, normales Zielen und Zielfernrohr
getrennt einstellbar. Dort lassen sich die vertikale Mausachse invertieren und
Zielen sowie Sprinten zwischen Halten und Umschalten wechseln. Diese Optionen
ändern die weiterhin gehaltene Interaktion an Missionsstationen nicht. Speichern
übernimmt den Entwurf; Abbrechen verwirft ihn. „Steuerung zurücksetzen“ stellt nur
Eingabewerte wieder her und erhält Grafik, Schwierigkeit und Audio. Pause,
Fokusverlust und ein neuer Einsatz löschen gehaltene und umgeschaltete Aktionen.

Das Hauptmenü bietet drei Aufträge: **Wellen** mit anschließender Evakuierung,
**Daten bergen** im Containerhof und am Nordtor evakuieren sowie **Funk sichern**
in der Wartungszone. Zum Laden von Daten oder Aktivieren der Station wird die
Interaktionstaste gehalten; Verlassen oder Loslassen setzt diesen kurzen Vorgang
zurück. Die anschließende Funkkontrolle dauert 45 Sekunden und pausiert außerhalb
des Bereichs, ohne Bodenkontakt oder bei anwesenden Gegnern. Ihr Fortschritt bleibt
erhalten. Die Evakuierung benötigt drei ununterbrochene Sekunden am Boden im
markierten Ring.

Deckung entsteht durch die Geometrie der Arena: Gegner benötigen Sichtkontakt. Hinter Kisten und Containern oder in liegender Haltung kann man sich ihrer Sicht entziehen; zerstörte Deckung schützt nicht mehr.

Das begehbare Gelände besitzt nahe Hügel bis rund 4,7 Meter und Mulden bis zwei Meter Tiefe. Darstellung, Bewegung, Sicht- und Schussprüfungen sowie Granaten- und Hülsenphysik verwenden dieselbe Geländeoberfläche. Erhebungen können damit tatsächlich Deckung bieten. Die zentrale Straße und die Fundamente der vorhandenen Gebäude und Container bleiben eben.

Die Gegner verwenden ein zusammenhängendes, texturiertes Charaktermodell mit menschlichem Gesicht und einem animierten Skelett. Separate 2K-Farb- und Normalenkarten für Kopf und Körper zeigen Haut, Gewebestruktur, Nähte und abgenutzte matte Ausrüstung. Haut und Kleidung erhalten unterschiedliche Materialeigenschaften. Es handelt sich um ein gestaltetes Spielmodell, nicht um einen fotografischen Menschenscan. Ihre Körperhaltung folgt dem Kampfverhalten: Sie laufen und rennen, ducken sich an Deckung, springen und richten die sichtbaren Gewehre beim Zielen aus. Die Hände folgen den Griffpunkten des tatsächlichen Waffenmodells.

AR-4 und M82 besitzen eigene Waffenmodelle mit geformten Konturen, abgeschrägten Bauteilen und unterschiedlichen Metall-, Polymer- und Glasmaterialien. Rückstoß, Verschluss und Magazin bewegen sich passend zum Schießen und Nachladen. Bei jedem tatsächlich abgegebenen Schuss wird eine Messinghülse ausgeworfen. Sie rotiert, fällt unter Schwerkraft und prallt an Boden, Containern und anderen festen Objekten ab; leise, räumlich gepannte Aufprallgeräusche begleiten die Kontakte. Nachladen und Abdrücken ohne abgegebenen Schuss erzeugen keine zusätzliche Hülse. Pause friert die Effekte ein, ein neuer Einsatz setzt sie zurück.

## 4. Umgesetzte Optimierungen

Die Landschaft verwendet fotografische **4K-Farbtexturen** für Erde, Waldboden, Rinde, Felsen, verwitterten Beton und Asphalt. Dazu kommen **2K-Normalenkarten** für Oberflächendetails und **1K-Rauheitskarten**. Diese unterschiedlichen Auflösungen erhalten sichtbare Details, ohne sämtliche Materialdaten unnötig in 4K im Grafikspeicher zu halten. Der fotografische Himmel ist ein unverändertes **8K-Panorama**; es dient als Hintergrund, nicht als vollständige HDR-Beleuchtung. Die Quellen, Lizenzen, Originalauflösungen und Prüfsummen sind in `native/Assets/texture-sources.json`, `docs/native-foliage-sources.json` und `docs/native-sky-sources.json` dokumentiert.

- **Instancing und Culling:** Wiederholte Geometrie wird pro Mesh zusammengefasst und mit instanzierten Metal-Zeichenbefehlen ausgegeben. Eine Prüfung von Sichtfeld, Objektgröße und Entfernung reduziert die Objekte im Hauptdurchlauf; die Schatten berücksichtigen weiterhin relevante Objekte außerhalb des Kamerabilds.
- **Vegetation nach Entfernung:** Kiefern besitzen räumliche Äste und texturierte Nadelbüschel. Drei Geometriestufen reduzieren die Zahl entfernter Zweige. Nur der verwendete Bereich des Nadelatlas wird in den Grafikspeicher geladen; die vollständigen Originalbilder bleiben im App-Paket erhalten. Feine Grashalme bilden kleine Büschel und bewegen sich leicht im Wind.
- **Drei wiederverwendete GPU-Puffer:** Instanz- und Kameradaten rotieren zwischen drei vorbereiteten Puffersätzen. Ein Metal-Fertigstellungssignal verhindert, dass die CPU Daten überschreibt, die die GPU noch benötigt. Geometrie, Texturen und Render-Pipelines werden nach der Initialisierung wiederverwendet.
- **Skelettanimation auf der GPU:** Alle Gegner teilen sich das indizierte Charaktermesh und dessen Texturen. Doppelte Vertices werden beim Import zusammengefasst. Die CPU berechnet Animation und Gelenkstellungen; Metal verformt die Vertices anhand der Gewichte. Dreifach gepufferte Gelenkmatrizen werden für Haupt- und Schattenbild gemeinsam verwendet. Körper, Gesicht und Helmausrüstung benötigen zusammen sechs instanzierte Zeichenbefehle einschließlich Schatten, unabhängig von der Gegnerzahl.
- **Gespeicherte KI-Navigation:** Das begehbare Raster wird zwischengespeichert und nach zerstörter Deckung aktualisiert. Wegsuche verwendet wiederverwendete Suchpuffer; Sichtprüfungen und neue Routen werden zeitlich verteilt. Die Simulation rechnet mit festen 120-Hz-Schritten unabhängig von der Bildrate.
- **Gemeinsames Geländeraster:** Ein einmal berechneter Höhenpuffer von etwa 1 MiB vermeidet wiederholte Landschaftsberechnungen. Innerhalb der Arena verwenden Grafik und Physik dieselben Dreiecke eines 1-Meter-Rasters. Strahlen durchlaufen die betroffenen Rasterzellen und prüfen deren Flächen direkt; dadurch treffen auch horizontale Schüsse auf Hügel, ohne das Gelände nur in groben Abständen abzutasten.
- **Begrenzte Hülsenphysik:** Höchstens 96 Hülsen werden gleichzeitig gehalten und nach 14 Sekunden simulierter Zeit entfernt. Ihre Physik verwendet feste 240-Hz-Teilschritte; ruhende Hülsen sparen weitere Bewegungsschritte, solange ihre Auflage bestehen bleibt. Vorbereitete Waffenteile und instanzierte Hülsengeometrie verwenden die vorhandenen Metal-Ressourcen weiter.
- **Begrenzte Grafiklast:** „Ausgewogen“ reduziert die interne Auflösung und verwendet einfaches Sampling; „Hoch“ nutzt bei Unterstützung 4× MSAA. Die Renderbreite ist begrenzt. Texturen besitzen Mipmaps, Effekte feste Mengenlimits, das HUD wird höchstens 30-mal pro Sekunde aktualisiert.
- **Pause spart laufende Arbeit:** Pause, Ergebnisansicht und ein inaktives Fenster stoppen die kontinuierliche Metal-Zeichenschleife. Die Spielsimulation und Audioausgabe pausieren ebenfalls. Bei Bedarf, etwa nach einer Größenänderung, kann ein einzelnes Bild neu gezeichnet werden. Das Hauptmenü läuft mit 30 FPS, im Spiel sind 60 oder 120 FPS als Limit wählbar.

## 5. Prüfung und Entwicklung

Die Tests benötigen Swift 6 und, mit der hier verwendeten Swift-Testing-Bibliothek, macOS 14 oder neuer. Die App selbst zielt weiterhin auf macOS 13.

```bash
# Das vollständige native Paket bauen und seine Swift-Tests ausführen.
./native/scripts/test.sh

# Optimierte App bauen, tatsächlichen Metal-Frame rendern und PNG speichern.
./native/scripts/build-app.sh --smoke-test

# Optimierte CPU-Simulation mit reproduzierbarem Szenario messen.
./native/scripts/benchmark-core.sh

# Grafikleistung bei 2560×1600 Pixeln und hoher Qualität messen.
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --graphics-benchmark

# Hochauflösendes Bild der tatsächlichen Metal-Szene ausgeben.
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --smoke-test \
  --width 2560 --height 1600 --output release/native-landscape-hd.png

# Debug-Konfiguration mit Swift-Laufzeitprüfungen starten.
./native/scripts/run.sh --debug
```

Der Grafiktest speichert `release/native-smoke.png`. Er benötigt eine nutzbare Metal-GPU und prüft auch die Ressourcen im App-Bundle. Der Frame verwendet die tatsächlichen Material-, Schatten- und, bei Unterstützung, 4×-MSAA-Pipelines. Er ersetzt keinen manuellen Durchlauf von Bewegung, Kampf, Klettern und Fokuswechseln.

### Gelände und Soldaten gezielt prüfen

Diese Szenen aus `NativeBattlefieldCheck.swift` erzeugen reproduzierbare Bilder mit dem tatsächlichen Metal-Renderer. `soldiers` und `soldiers-side` zeigen festgelegte stehende, geduckte und springende Posen aus zwei Blickrichtungen. `soldier-close`, `soldier-profile`, `soldier-back`, `soldier-crouch` und `soldier-dead` zeigen Nahansichten des Charakters. `terrain` zeigt die nahen Hügel, `hollow` eine Mulde. `firefight` lässt die Kampfsimulation fortschreiten und gibt außerdem beobachtete Gegneraktionen und Schusszahlen als JSON aus.

`squad` zeigt neun Soldaten mit verschiedenen Haltungen für die Prüfung mehrerer gleichzeitiger Skelettpaletten und für reproduzierbare Grafikmessungen. Die JSON-Ausgabe nennt außerdem ausgegebene Soldaten, Dreiecke, Texturbreite sowie ungültige oder ausgelassene Posen; beide Fehlerzähler sollen null bleiben.

```bash
# Vier feste Ansichten; Metal-API-Validierung einschalten.
for scene in soldiers soldiers-side terrain hollow; do
  MTL_DEBUG_LAYER=1 ./release/Blacksite.app/Contents/MacOS/BlacksiteMac \
    --smoke-test --scene "$scene" --output "release/native-$scene.png"
done

# Vier Sekunden tatsächliche Kampfsimulation vor dem Bild.
MTL_DEBUG_LAYER=1 ./release/Blacksite.app/Contents/MacOS/BlacksiteMac \
  --smoke-test --scene firefight --seconds 4 --output release/native-firefight.png
```

`--seconds` betrifft die Szene `firefight`, verwendet standardmäßig vier Sekunden und begrenzt den Fortschritt auf 0 bis 20 Sekunden. Die PNGs unter `release/native-*.png` enthalten die Metal-Szene; das separate AppKit-HUD ist darin nicht enthalten.

### Waffen und Hülsen gezielt prüfen

Die folgenden CLI-Szenarien prüfen die Verbindung zwischen Schussereignissen und Hülsenauswurf und erzeugen Bilder der jeweiligen Waffenansicht. Mit `MTL_DEBUG_LAYER=1` vor dem Aufruf lässt sich zusätzlich die Metal-API-Validierung einschalten.

```bash
# Einzelner Sturmgewehrschuss, kurz nach dem Auswurf.
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --smoke-test \
  --weapon rifle --shots 1 --effect-seconds 0.025 \
  --output release/native-rifle-ejection.png

# Scharfschützengewehr im Liegen und beim Zielen.
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --smoke-test \
  --weapon sniper --shots 1 --prone --aim --effect-seconds 0.08 \
  --output release/native-sniper-prone-aim.png

# Teilmagazin nachladen; Bild bei 45 Prozent des Nachladevorgangs.
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --smoke-test \
  --weapon rifle --shots 3 --reload-preview --effect-seconds 0 \
  --output release/native-rifle-reload.png

# Mehr Schussversuche als Patronen: 30 / 5 erfolgreiche Schüsse erwartet.
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --smoke-test \
  --weapon rifle --shots 32 --effect-seconds 1 --look-down \
  --output release/native-rifle-empty.png
./release/Blacksite.app/Contents/MacOS/BlacksiteMac --smoke-test \
  --weapon sniper --shots 7 --effect-seconds 1 --look-down \
  --output release/native-sniper-empty.png
```

`--weapon` akzeptiert `rifle` und `sniper`; `--shots` begrenzt die angeforderten Versuche auf Magazinkapazität plus zwei. Vor dem anschließenden Effektfortschritt vergleicht der Prüfpfad erfolgreiche Schussereignisse mit der Zahl erzeugter Hülsen. `--reload-preview` fordert zusätzlich Nachladen an und prüft, dass dabei keine weitere Hülse entsteht. `--effect-seconds` lässt danach zwischen 0 und 16 Sekunden verstreichen; `--look-down` richtet die abschließende Kamera nach rechts unten zur Landestelle der Hülsen. Nach längerer Wartezeit können Hülsen regulär abgelaufen sein. Die JSON-Ausgabe enthält unter anderem `acceptedShots`, `shellCount`, `shellEventCheck` und `shellImpacts`.

Die PNGs erfassen die Metal-Szene einschließlich des Sniper-Zooms. Das AppKit-HUD mit Zielfernrohrblende und Absehen wird separat im laufenden App-Fenster geprüft.

### Tests und Messverfahren

Das Testskript verwendet dieselben lokalen Caches wie der App-Build und findet das Swift-Testing-Makro-Plugin in der aktiven Apple-Toolchain bei Bedarf automatisch. Zusätzliche Optionen werden an `swift test` weitergereicht, beispielsweise `./native/scripts/test.sh --filter Grenade`.

Der CPU-Benchmark baut die Spielsimulation mit `-O` und Whole-Module-Optimierung. Nach einer Aufwärmphase misst er fünf Durchläufe mit jeweils 60 simulierten Sekunden, zwölf alarmierten Gegnern und vorgegebenen Bewegungen in der tatsächlichen Arena. Nach einem Spielertod beginnt das Szenario erneut, damit die Messung laufenden Kampf abdeckt. Die JSON-Ausgabe enthält CPU-Zeit, Zeit pro Simulationsschritt, Median und Prüfsummen für die Reproduzierbarkeit. Rendering und Audio sind nicht Teil dieses CPU-Benchmarks.

Der Grafikbenchmark zeichnet die tatsächliche Arena samt Schatten und Vegetation in einen wiederverwendeten Metal-Puffer: zehn Aufwärmbilder, dann 120 Messbilder. Er erfasst CPU-Vorbereitung, GPU-Dauer, 95. Perzentil, Zeichenbefehle und belegten GPU-Speicher. Das ist eine feste Render-Szene ohne Bildratenlimit; die Ergebnisse sind keine garantierte Bildrate für eine vollständige Spielsitzung. Mit `--balanced --width 1440 --height 900` lässt sich die sparsamere Einstellung vergleichen.

Die Metal-Shader werden beim App-Start aus der mitgelieferten Datei `Shaders.metal` kompiliert. Deshalb ist zum Bauen keine separat installierte Metal-Compiler-Komponente erforderlich. Nach der Initialisierung werden die fertigen GPU-Pipelines wiederverwendet.

### Durchgeführte Validierung

Die aktuelle Umsetzung und ihre Prüfungen stehen im
[Roadmap-Protokoll](NATIVE_ROADMAP.md), einschließlich Schatten, Waffen, Effekten,
Grafikspeicher, Schauplätzen, Missionen und Steuerung. Die folgenden Messungen
dokumentieren die früheren Ausbaustufen und sind keine Leistungswerte des aktuellen
Gesamtstands.

Der Ausgangsstand mit texturierten menschlichen Soldaten wurde auf einem **Apple M2 Pro** gebaut und geprüft:

| Prüfung | Ergebnis |
| --- | --- |
| Vollständiger Paketbuild und Swift-Tests | **63 von 63 bestanden**: 53 Spiel-/Physiktests, drei AppKit-Menütests und sieben neue Charaktertests |
| Modell und Materialien | 19.450 Dreiecke; ursprüngliche 58.350 Vertices auf 12.584 zusammengefasst, bei erhaltenen UV-Nähten und Gelenkgewichten; drei korrekt getrennte Materialgruppen |
| Charaktertests | Skelett-/Vertexlayout, Bindpose, Materialgruppen, Kopf-/Handpositionen bei Zielen und Ducken, Fingerkrümmung, reale Meshgrenzen auf Gelände und bei Tod, Animationsübergänge/Reset und fehlerhafte Dateien |
| Release-App und Bundlesignatur | Eigenständige ARM64-App, ca. **147 MiB**; `codesign --verify --strict` und Metal-Starttest erfolgreich |
| Metal-Grafikprüfung | **Neun Szenarien** mit `MTL_DEBUG_LAYER=1` erfolgreich: fünf Nahansichten, drei Kampfhaltungen, neun gleichzeitige Gegner, simuliertes Gefecht sowie Neunergruppe in ausgewogener Grafik |
| Grafikergebnis | Keine ungültigen oder ausgelassenen Skelettposen; alle vier Charaktertexturen in 2048²; sechs instanzierte Charakter-Zeichenbefehle einschließlich Schatten |
| Visuelle Prüfung | Gesicht, Helm, Rücken, Hände, Ducken, Springen, Todespose und Gefecht in tatsächlichen Metal-Frames kontrolliert |

Die Ergebnisse stehen in `release/native-soldier-checks.json`. Die Szene `squad` mit neun Gegnern erreichte bei **2560×1600 und 4× MSAA** über 120 Messbilder durchschnittlich **5,78 ms GPU-Zeit** (P95 **7,54 ms**) und **3,35 ms CPU-Vorbereitung**. Die gesamte Szene benötigt 30 Zeichenbefehle und rund 1,10 GiB Metal-Speicher. Details: `release/native-soldier-benchmark.json`. Das ist eine reproduzierbare Render-Szene mit festen Kampfhaltungen, keine Zusage für die Bildrate eines vollständigen Einsatzes.

Beim damaligen Ausgangsstand war die erneute interaktive Fensterprüfung durch
Timeouts blockiert. Diese Prüfung wurde im Rahmen der Roadmap nachgeholt;
die erfolgreichen Bedienprüfungen sind dort protokolliert. Zum Laden einer neu
gebauten Version muss eine bereits gestartete App-Instanz beendet und neu geöffnet
werden.

Der vorherige Stand mit prozeduralen Soldaten und dem gemeinsamen Gelände wurde ebenfalls auf einem **Apple M2 Pro** geprüft:

| Prüfung | Ergebnis |
| --- | --- |
| Vollständiger Paketbuild und Swift-Tests | **56 von 56 bestanden**: 22 bestehende Spieltests, neun Hülsen-, neun Gelände-, 13 Gegner-/Gelände- und drei AppKit-Menütests |
| Release-App und Bundlesignatur | Eigenständige ARM64-App, ca. **120 MiB**; `codesign --verify --strict` erfolgreich |
| Metal-Grafikprüfung | Alle fünf neuen Szenen bei **2560×1600** mit `MTL_DEBUG_LAYER=1` erfolgreich; Front-/Seitenansicht, Hügel, Mulde und Gefecht visuell kontrolliert |
| Tatsächliches KI-Gefecht | Nach vier Sekunden wurden Rennen, Ducken, Luftphasen und Zielen sowie drei gegnerische Schüsse erfasst; Einsatz weiter aktiv |
| Native Bedienung | Menü, Einsatzstart, Schussabgabe und Pause im AppKit-Fenster geprüft |

Die AppKit-Menütests prüfen die tatsächlich gezeichneten Klickflächen bei mehreren Fenstergrößen, stabile Button-Sichtbarkeit während laufender HUD-Aktualisierung und die Klickdurchgabe im Spiel. Menübuttons werden nur noch bei echten Zustandsänderungen ein- oder ausgeblendet; wiederholtes Layout unterbricht dadurch keine laufende Klickverfolgung.

Die Ergebnisse der fünf Grafikszenen stehen in `release/native-battlefield-checks.json`. Die Soldatenansicht `soldiers-side` erreichte bei **2560×1600 und 4× MSAA** über 120 Messbilder durchschnittlich **5,53 ms GPU-Zeit** (P95 **8,07 ms**) und **2,33 ms CPU-Vorbereitung**. Dabei wurden 19.662 Instanzen in 35 Zeichenbefehlen ausgegeben; der belegte Metal-Speicher lag bei rund 1,02 GiB. Die Messung mit drei festgelegten Soldatenposen ist in `release/native-battlefield-benchmark.json` gespeichert und beschreibt keine garantierte Bildrate eines vollständigen Einsatzes.

Der optimierte CPU-Benchmark mit dem neuen Höhenfeld und zwölf alarmierten Gegnern benötigte im Median **8,50 µs pro 120-Hz-Simulationsschritt**. Alle fünf Durchläufe lieferten denselben Zustandsprüfwert. Details: `release/native-battlefield-core-benchmark.json`.

Auf einem **Apple M2 Pro** wurden für den vorherigen Waffenstand, vor der Erweiterung von Gelände und Soldaten, folgende Prüfungen erfolgreich abgeschlossen:

| Prüfung | Ergebnis |
| --- | --- |
| Vollständiger Paketbuild mit `native/scripts/test.sh` | Erfolgreich, einschließlich des nativen App-Targets |
| Swift-Tests der Spielsimulation | **30 von 30 bestanden**; darunter 22 Tests für Bewegung, Klettern, Waffen, Granaten, Deckung, Gegner-KI und Einsatzabschluss sowie acht Tests der Hülsenphysik |
| Optimierter Release-Build | Eigenständige ARM64-App, ca. **120 MiB** inklusive hochauflösender Ressourcen |
| Ad-hoc-Bundlesignatur | `codesign --verify --strict` erfolgreich |
| Nativer Grafiktest | Echter Metal-Frame mit Texturen, Schatten und 4× MSAA erfolgreich gerendert und als PNG gespeichert |
| Hochauflösende Landschaft | 23 Originalbilder samt Pixelmaßen und Prüfsummen verifiziert; 2560×1600-Frame mit aktivierter Metal-API-Validierung erfolgreich |
| Unabhängiges App-Paket | Kopie außerhalb des Projektordners lädt ihre eigenen Ressourcen; Grafiktest mit aktivierter Metal-API-Validierung erfolgreich |
| Native Bedienung | Start, Waffenwechsel, Hinlegen, Granatenwurf, Pause, Vollbild und Einstellungsdialog im AppKit-Fenster geprüft |
| Waffen und Hülsenauswurf | Elf GPU-Prüfszenarien mit `MTL_DEBUG_LAYER=1` bestanden: beide Waffen, Schießen, Zielen, Sniper-Zoom, Hinlegen, Nachladen, leere Magazine und Hülsen am Boden; Ergebnisse in `release/native-weapon-checks.json` |

Eine **frühere Messung der Landschaft vor der Erweiterung der Waffen, Hülsen, Soldaten und des Geländes** erreichte auf dem M2 Pro bei **2560×1600 Pixeln und 4× MSAA** über 120 Messbilder eine mittlere GPU-Dauer von **6,76 ms** (95. Perzentil: 11,83 ms) und mittlere CPU-Vorbereitung von **2,51 ms**. Die damalige Szene enthielt 228 Bäume; im gemessenen Blickfeld wurden 19.723 Instanzen in 15 Zeichenbefehlen gerendert. Der Metal-Speicherbedarf lag bei rund **1,01 GiB**, einschließlich des echten 8192-Pixel-Himmels. Die Messwerte sind in `release/native-graphics-benchmark.json` dokumentiert und beschreiben ausschließlich diesen früheren Stand. Die tatsächliche Bildrate hängt außerdem von Ansicht, Fensterausgabe, HUD und anderen laufenden Anwendungen ab; F5 zeigt sie im Spiel an.

Eine spätere Messung des damaligen Waffenstands mit überarbeitetem Sturmgewehr und drei ausgeworfenen Hülsen erreichte bei denselben 2560×1600 Pixeln und 4× MSAA durchschnittlich **6,00 ms GPU-Zeit** und **1,80 ms CPU-Vorbereitung** (120 Messbilder, GPU-P95 12,25 ms). Dabei wurden 19.849 Instanzen mit 22 Zeichenbefehlen ausgegeben. Die Werte stehen in `release/native-weapon-benchmark.json` und stammen ebenfalls **vor dem gemeinsamen Gelände und den neuen Soldaten**. Sie sind keine Messung des aktuellen Stands und keine Zusage für die Bildrate während eines vollständigen Einsatzes.

## 6. Signierung und Weitergabe

Das Build-Skript versieht die App standardmäßig mit einer lokalen Ad-hoc-Signatur und prüft anschließend die Integrität des Bundles. `--no-sign` überspringt diesen Schritt. Eine Ad-hoc-Signatur ist keine Developer-ID-Signatur; die App ist nicht von Apple notarisiert. Für eine reguläre öffentliche Verteilung benötigt man eine eigene Developer-ID-Signierung und Notarisierung.

Die mitgelieferten Poly-Haven-Texturen stehen unter CC0; Quellcode und eigene Geometrie unter der Projektlizenz. Die App enthält `ASSET-CREDITS.txt`, `ASSETS.md` und `LICENSE.txt` in `Contents/Resources`. Die vollständige Herkunft der ursprünglichen Ressourcen ist in [ASSETS.md](ASSETS.md) dokumentiert.
