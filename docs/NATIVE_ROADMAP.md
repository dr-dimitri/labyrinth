# Native Spielverbesserungen

Umsetzung der [Roadmap #13](https://github.com/dr-dimitri/labyrinth/issues/13),
begonnen am 19.09.2026 auf `codex/native-game-roadmap`.
Die Änderungen werden in Roadmap-Reihenfolge geprüft und einzeln lokal committet.

## Ausgangsstand

`cc17b8c` sichert den vorher vorhandenen nativen Spielstand samt benötigten Assets.
63 Tests bestanden (53 Kern-/Physiktests, zehn AppKit-/Charaktertests).
Browser-/Electron-Arbeiten sind nicht Teil dieser nativen Umsetzung.

## Arbeitspakete

| Reihenfolge | Issue | Stand |
| --- | --- | --- |
| 1 | #12 Evakuierungshinweis | Umgesetzt und geprüft |
| 2 | #7 Faire Sichtwahrnehmung | Umgesetzt und geprüft |
| 3 | #8 Sichere Verstärkungen | Umgesetzt und geprüft |
| 4 | #10 Richtungsfeedback und räumlicher Sound | Umgesetzt und geprüft |
| 5 | #1 Nahschatten | Umgesetzt und geprüft |
| 6 | #2 Ego-Waffen und Hände | Umgesetzt und geprüft |
| 7 | #3 Einschläge und Explosionen | Umgesetzt und geprüft |
| 8 | #5 Texturbudget | Umgesetzt und geprüft |
| 9 | #4 Schadensstufen und Trümmer | Umgesetzt und geprüft |
| 10 | #6 Schauplätze und alternative Wege | Offen |
| 11 | #9 Missionsvarianten | Offen |
| 12 | #11 Steuerung und Zielkomfort | Offen |

## Prüfprotokoll

### #12 – Evakuierungshinweis

Die Simulation sendet beim Freigeben der Extraktion ein eigenes einmaliges
`extractionUnlocked`-Ereignis. HUD und Hinweiston verwenden dieses Ereignis;
die Zwischenwellen behalten ihren bisherigen Ablauf. Der Regressionstest
durchläuft beide Zwischenwellen, die Extraktion und einen neuen Einsatz.

Validierung: 64 Tests bestanden; unabhängiges Review ohne Befund.

### #7 – Faire Sichtwahrnehmung

Gegner verwenden einen horizontalen 120°-Sichtkegel und eine kurze Erkennungsphase.
Wachgänge, Geräuschuntersuchung, Suche und Kampf haben erkennbare Zustände.
Feste Anrückziele und kurze Patrouillen verhindern untätige Gegner. Nach
Sichtverlust bricht die Schussvorbereitung ab; Geräusch- und Explosionsquellen
verraten keine späteren verdeckten Bewegungen. Deckungswahl verwendet ebenfalls
nur bekannte Positionen. Wiederholte Schüsse am selben Ort erzwingen keine
Wegsuche pro Patrone.

Validierung: 71 Tests bestanden, darunter sieben neue Verhaltenstests für
Sichtfeld, Reaktionszeit, Suche, Geräusche, Explosionen, Patrouillen und Pause.
Unabhängiges Code-Review abgeschlossen. Bestehende Sprung- und Deckungstests
behalten ihre Verhaltensprüfungen; die Blickrichtung ist nun explizit.

### #8 – Sichere Verstärkungen

Ausstehende Gegner bleiben in der Welle erhalten. Alle 0,5 Sekunden prüft ein
begrenzter Versuch freie, verdeckte und erreichbare Eintrittspunkte. Der ganze
Körper muss hinter der Kamera oder einem gemeinsamen intakten Hindernis liegen.
Navigationskomponenten berücksichtigen auch dünne Hindernisse zwischen
Rasterzellen. Das HUD zählt lebende und ausstehende Gegner getrennt; tatsächliche
Anrückrichtungen werden zusammengefasst gemeldet. Wellenende und Extraktion
warten im Wellenmodus auf alle angekündigten Gegner.

Validierung: 77 Tests bestanden. Sechs neue Tests prüfen unter anderem verzögerte
Verstärkungen und vollständigen Missionsabschluss. 144 reale Kartenkonfigurationen
(Dächer, Hügel, verschiedene Blickrichtungen und Pitch ±1,4, zerstörte Deckung)
setzen alle neun Gegner innerhalb von zwei Sekunden ein. Unabhängiges Review
abgeschlossen; unnötige Hindernisprüfungen bei der Auswahl der nächsten
Navigationszelle wurden dabei vermieden. Release-Kernbenchmark: Median 9,724 µs
je 120-Hz-Schritt, fünf identische Prüfsummen bei je 60 simulierten Sekunden und
zwölf Gegnern. Dies misst die Simulation, nicht die Gesamtbildrate.

### #10 – Richtungsfeedback und räumlicher Sound

Beschuss zeigt kurzlebige, kamerabezogene Pfeile mit Text; bis zu drei nahe
Granaten erhalten nummerierte Richtungen und den echten Zünder-Countdown.
Vertikale Gefahren werden als oben/unten bezeichnet. Hinweise funktionieren
ohne Ton und ohne reine Farbcodierung, einschließlich Accessibility-Text.
Pause friert ihre Simulationszeit ein; ein neuer Einsatz setzt sie zurück.
Gegnerschüsse, Explosionen und Hülsen werden nach Richtung und Entfernung
gemischt. Musik und Effekte besitzen unabhängig gespeicherte Regler mit Migration
des bisherigen Lautstärkewertes. Ein gemeinsamer PeakLimiter schützt den Mix.

Validierung: 87 reguläre Tests bestanden; zusätzlich echter Offline-Audiotest
mit 16 gleichzeitigen Explosionen und einzeln stummgeschalteten Bussen bestanden.
Der System-Audiotest benötigt `BLACKSITE_TEST_SYSTEM_AUDIO=1` und Zugriff auf die
macOS-AudioUnits; die normalen Tests benötigen keine Audioausgabe.
Unabhängiges Review abgeschlossen und den dabei gefundenen vertikalen
Richtungsfehler behoben. Interaktive Bedienprüfung nach Entsperren des Macs bestanden: Mission starten,
Pause, getrennte Audio-Regler öffnen, unverändert speichern und zum Pausemenü
zurückkehren. Vollständiger nativer Paketbuild und automatisierte Tests geprüft.

### #1 – Nahschatten und Bodenkontakt

Ein texelstabilisiertes 40-Meter-Nahschattenfeld ergänzt die vorhandenen
Fernschatten. Die Grafikstufen verwenden 2048² beziehungsweise 1024² für das
Nahfeld. Beide verwenden dieselbe vorberechnete Soldatenpose; Lichtfrustum-Culling
und vereinfachte Schattenmodelle für entfernte Bäume begrenzen die Kosten.
Empfängerflächen erhalten gefilterte, ebenenkorrigierte Schatten. Kleine,
oberflächengeprüfte Kontaktflächen unter den tatsächlichen animierten Sohlen
bleiben auch im Bunkerschatten sichtbar und verschwinden bei abgehobenen Füßen.

Validierung: 97 reguläre Tests bestanden. Neue Prüfungen decken Stabilisierung,
Sohlenpositionen, geneigten Boden, Dachkanten und fliegende Figuren ab. Fünf
Metal-validierte Ansichten prüfen Straße, Hügel, Containerdach, Balanced und
eine kleine Kameraverschiebung; keine ungültigen Charakterposen oder GPU-Fehler.
Unabhängiges Review behob Shader-Ableitungen in divergenten Zweigen und eine
inkorrekte lineare Tiefenfilterung. [Vorher](native-roadmap/shadows-before.png)
und [nachher](native-roadmap/shadows-after.png) zeigen dieselbe 1280×800-Ansicht.

Drei abwechselnde Vergleichsläufe je Grafikstufe auf Apple M2 Pro, 2560×1600,
neun Soldaten, je zehn Aufwärm- und 120 vollständig abgeschlossene Messframes:
High CPU-P95 4,149 → 3,550 ms, GPU-P95 13,399 → 12,641 ms;
Balanced CPU-P95 3,641 → 3,505 ms, GPU-P95 11,493 → 9,034 ms.
Die Werte sind Mediane der Einzelläufe, keine garantierte Spielbildrate.
GPU-Allokation steigt um 20,16 MiB; das zusätzliche Schattenbudget von 1 ms
wird eingehalten. [Messdaten](native-roadmap/shadow-performance.json).

### #14 – Sichtbare Deckung auf Kollisionshöhe

Im Schattenreview fiel auf, dass Container- und Bunkerdächer über ihren
Kollisionsflächen lagen und Betonbarrieren darunter endeten. Das separat angelegte
[Bug-Issue #14](https://github.com/dr-dimitri/labyrinth/issues/14) korrigiert die
sichtbaren Oberkanten. Container verwenden ihre vorhandene Dachfläche; beim
Bunker treffen Wand und Dach ohne überlagerte Flächen aufeinander. Dadurch stehen
Figuren und Kontaktschatten auf der sichtbaren Deckung.

Validierung: unabhängiges Geometriereview, Metal-Containerdachansicht und die
vollständige Testsuite einschließlich Klettern bestanden. Separater lokaler
Commit `3d1fa82`.

### #2 – Ego-Waffen, Hände und Eigenbeschattung

AR-4 und M82 verwenden fotografische Metall-/Stoffkarten mit getrennten
Farb-, Normalen- und Rauheitsdaten. Sechs unveränderte CC0-JPEGs mit dokumentierter
Herkunft werden offline auf Maße und Prüfsummen geprüft. Nachladen besteht aus
Greifen, Entnehmen, Einsetzen und Verschlussbetätigung. Magazin und linke Hand
verwenden gekoppelte Transformationen; die Ärmel bleiben mit den Handgelenken
verbunden. Die Obergrenzen für die sichtbaren Unterarme sind 34 und 31 cm.

An naher Deckung weicht die Waffe sofort aus und kehrt anschließend weich in
Schussposition zurück. HUD-Zielfernrohr, Zoom und Zielgeschwindigkeit verwenden
denselben sichtbaren Zielzustand. Mündung und Hülsenauswurf benutzen die aktuelle
Waffenpose, auch bei einem Schuss unmittelbar nach einer Drehung zur Wand.

Eine separate 512²-Schattenkarte beschattet Waffen und Hände mit ihrer tatsächlichen
Geometrie und Pose. Die bisherigen Nah- und Fernschatten der Umgebung wirken
weiter auf sie; kameragebundene Arme werfen keinen losgelösten Schatten auf das
Gelände. Ein Vergleich mit ausschließlich deaktivierter Eigenbeschattung änderte
16.313 Pixel innerhalb der Waffen-/Armregion und keinen Pixel außerhalb.

Validierung: 105 reguläre Tests bestanden, darunter acht neue Prüfungen für
Nachladeübergänge, Griffkontakt, Verschluss und Wand-/Geländeabstand. 22
Metal-validierte Ansichten zeigen beide Waffen beim Zielen, Liegen, an Wänden
und in fünf Nachladephasen; unabhängige Bildprüfung ohne offenen Befund.
Zusätzlich Dach, Umgebungsschatten und Balanced geprüft. Jede gültige Patrone
erzeugt weiterhin genau eine Hülse; Nachladen erzeugt keine zusätzliche.
Reviewbefunde zu Normalmap-Ausrichtung und veralteter Wandpose vor dem
Hülsenauswurf wurden behoben.

[Vorher](native-roadmap/weapons-before.png),
[nachher](native-roadmap/weapons-after.png) und
[Magazinentnahme](native-roadmap/weapon-reload.png).
Drei abwechselnde Vergleichsläufe je Stufe, Apple M2 Pro, 2560×1600,
neun Soldaten, je zehn Aufwärm- und 120 abgeschlossene Messframes:
High CPU-P95 2,283 → 2,368 ms, GPU-P95 6,070 → 6,165 ms;
Balanced CPU-P95 2,306 → 2,273 ms, GPU-P95 4,667 → 4,874 ms.
Mediane der Einzelläufe; das High-Zielbudget von zusätzlich höchstens 0,5 ms
wird eingehalten. GPU-Allokation steigt um 57,61 MiB. Die nächste Texturbudget-
Aufgabe berücksichtigt auch diese Materialkarten.
[Messdaten](native-roadmap/weapon-performance.json).

### #3 – Materialeinschläge und Explosionen

Schüsse melden die tatsächlich getroffene Oberfläche mit Material, Normale und
stabiler Objektkennung, auch bei sofortiger Zerstörung. Erde, Asphalt, Beton,
Metall und Holz erhalten passende Staub-, Funken- und Splittereffekte. Fehlschüsse
erzeugen keine Lufttreffer. Einschlagspuren folgen den sichtbaren Deckungsflächen,
einschließlich Containerstegen und Warnstreifen; kleine Kanten begrenzen ihre Größe.
Zerstörung entfernt die zugehörigen Spuren sofort.

Explosionen zeigen einen kurzen Blitz, Splitter und anschließend abklingenden
Staub/Rauch. Transparente Partikel werden nach Kameratiefe sortiert und an der
tatsächlichen Gelände- oder Dachfläche weich ausgeblendet. Sie werfen keine
undurchsichtigen Kugelschatten. Einschlagspuren empfangen die vorhandenen Nah- und
Fernschatten. Hoch begrenzt die Wirkung auf 256 Partikel und 80 Spuren,
Ausgewogen auf 128 und 40; maximal drei zusätzliche instanzierte Zeichenaufrufe.
Partikel leben höchstens vier Sekunden, Spuren zwölf; Neustart leert beide Pools.

Validierung: 119 reguläre Tests bestanden, darunter sechs neue Trefferprüfungen
und acht Geometrieprüfungen für sichtbare Trefferflächen und echte Auflagehöhen.
21 Metal-validierte Ansichten prüfen alle Materialien, drei gleichzeitige
Explosionen in fünf Zeitphasen, Hügel, Containerdach, Ausgewogen, Poolüberlauf,
Zerstörung, Ablauf und Neustart. Unabhängiges Code- und Bildreview abgeschlossen.
Die dabei gefundenen harten Bodenschnitte und verdeckten Warnstreifentreffer
wurden behoben. [Vorher](native-roadmap/effects-before.png),
[nachher](native-roadmap/effects-after.png), [Rauchphase](native-roadmap/effects-smoke.png).

Drei abwechselnde Vergleichsläufe je Grafikstufe, Apple M2 Pro, 2560×1600,
neun Soldaten und drei identische Explosionen im Alter von 0,2 Sekunden:
High CPU-P95 2,000 → 2,283 ms, GPU-P95 5,191 → 5,798 ms;
Balanced CPU-P95 1,878 → 1,864 ms, GPU-P95 4,157 → 4,561 ms.
Das High-Zielbudget von zusätzlich höchstens 1 ms wird mit 0,607 ms eingehalten.
Die GPU-Allokation steigt um 0,047 MiB. Der Vergleichsbuild enthält ausschließlich
die neuen CLI-Prüfeingaben neben dem vorherigen Renderer, damit beide Versionen
dieselben Explosionen erhalten. Mediane aus je zehn Aufwärm- und 120 vollständig
abgeschlossenen Messframes; [Messdaten](native-roadmap/effect-performance.json).

### #5 – Texturbudget und sicherer Qualitätswechsel

Ausgewogen dekodiert Fotos vor dem GPU-Upload mit halbierten Seitenlängen;
Hoch behält sämtliche Originalpixel. Der Pine-Ausschnitt erfolgt anschließend
mit denselben relativen Koordinaten. Farbbilder verwenden sRGB, Normalen-,
Rauheits- und Maskendaten lineare Formate. Einkanalbilder bleiben kompakt.

| Texturtyp | Hoch, maximale Größe | Ausgewogen, maximale Größe |
| --- | --- | --- |
| Landschaft, Farbe / Normale / Rauheit | 4096² / 2048² / 1024² | 2048² / 1024² / 512² |
| Himmel | 8192×4096 | 4096×2048 |
| Pine, Farbe und Maske nach Ausschnitt | 1024×2048 | 512×1024 |
| Pine, Normale und Rauheit nach Ausschnitt | 512×1024 | 256×512 |
| Soldaten | 2048² | 1024² |
| Waffen, Farbe / Normale / Rauheit | 2048² / 1024² / 1024² | 1024² / 512² / 512² |
| Fern- / Nah- / Waffenschatten | 2048² / 2048² / 512² | 2048² / 1024² / 512² |

Richtbudgets für die geprüfte Szene auf Apple M2 Pro: fotografische Texturen
höchstens 1024 MiB in Hoch beziehungsweise 256 MiB in Ausgewogen;
gesamte GPU-Allokation bei 2560×1600 höchstens 1280 beziehungsweise 384 MiB.
Der Benchmark meldet echte, nach Ursprungsressource deduplizierte Allokationen
für Landschaft, Vegetation, Himmel, Soldaten, Waffen, Schatten und Renderziele.
Texturansichten und Alias-Slots werden nicht doppelt gezählt. Treiber-Gesamtwerte
enthalten zusätzlich beispielsweise Geometrie- und Instanzpuffer.

Start lädt unmittelbar das gespeicherte Profil. Ein Wechsel bereitet alle
Materialien und genau eine aktive Nahschattenkarte vollständig vor, bevor er
den bisherigen Satz ersetzt. Fehler lassen Ressourcen und Einstellungen
unverändert. Es gibt keinen dauerhaften zweiten Textursatz; bereits abgeschickte
GPU-Frames behalten ihre Ressourcen bis zum Abschluss.

Die Bildprüfung fand im verkleinerten macOS-Bildformat einen tatsächlichen
Kanal-/Alpha-Fehler sowie eine ignorierte sRGB-Uploadoption. Der Loader korrigiert
das betroffene RGBX-Layout und erzeugt Mipmaps erst über dem endgültigen
sRGB- beziehungsweise linearen Format. Ein zusätzlicher echter GPU-Readbacktest
schlug beim alten Lader reproduzierbar fehl und besteht nach der Korrektur:
36 aufeinanderfolgende Uploads prüfen RGB, deckendes Alpha, beide Bildursprünge,
URL-/eingebettete Quellen und die letzte Mipmap-Stufe. Aktivierung:
`BLACKSITE_TEST_METAL_TEXTURES=1 native/scripts/test.sh --filter NativeTextureUploadTests`.

Validierung: 124 reguläre Tests sowie der gesonderte GPU-Test bestanden.
Unabhängiges Code- und Bildreview abgeschlossen; acht Metal-validierte Ansichten.
Alle vier Hoch-Bilder sind [pixelidentisch](native-roadmap/textures-high-comparison.json)
zum vorherigen Build. Ausgewogen: [vorher](native-roadmap/textures-balanced-before.png),
[nachher](native-roadmap/textures-balanced-after.png),
[Soldatengesicht](native-roadmap/textures-balanced-soldier.png).

Identische Squad-Szene mit neun Soldaten, 2560×1600: Ausgewogen sinkt von
1096,30 auf 332,02 MiB GPU-Allokation (**−69,71 %**, Ziel mindestens −25 %).
Hoch sinkt durch die entfernte ungenutzte Nahschattenkarte von 1207,42 auf
1203,39 MiB. Drei vollständige Hin-/Rückwechsel mit abgeschlossenen Frames
ergaben für jede Stufe exakt denselben Wert, ohne Speicherwachstum oder
Metal-Validierungsfehler. [Wechselmessung](native-roadmap/texture-quality-cycles.json),
reproduzierbar mit `--graphics-benchmark --scene squad --width 2560 --height 1600 --quality-cycles 3`.

Zeitmessungen streuten unter Hintergrundlast deutlich. Ein erster Vergleich mit
drei Paaren und ein Kontrolllauf mit fünf Paaren liefern daher **keinen belastbaren
Bildratengewinn**. Im Kontrolllauf: High CPU-P95 2,838 → 2,943 ms,
GPU-P95 14,397 → 12,299 ms; Balanced CPU-P95 2,645 → 2,742 ms,
GPU-P95 13,175 → 11,991 ms. Je zehn Aufwärm- und 120 abgeschlossene Messframes;
Mediane der Einzelläufe. Der reproduzierbare Vorteil ist die Speicherreduktion.
[Erste Messung](native-roadmap/texture-performance.json),
[Kontrollmessung](native-roadmap/texture-performance-confirmation.json).

### #4 – Schadensstufen und begrenzte Trümmer

Kisten, Fässer, Container und Betonbarrieren wechseln bei halben Hitpoints in
sichtbar beschädigte Materialien. Holz splittert entlang der Bretter, Beton
zeigt kurze unregelmäßige Risse, Metall verliert Lack und erhält Kratzer sowie
Brandspuren. Containerstege werden eingedrückt; zugehörige alte Einschussmarken
werden beim Geometriewechsel entfernt, neue Treffer folgen der aktuellen Fläche.
Intakte Kollisionsvolumen bleiben bis zur Zerstörung geschlossen.

Holzreste bleiben zwölf, Fassreste acht, Containerbleche fünfzehn und Betonreste
zwanzig Sekunden sichtbar. Die Simulationszeit pausiert mit dem Spiel.
Höchstens 24 zerstörte Objekte mit insgesamt 96 dekorativen Fragmenten bleiben
aktiv; älteste Einträge werden samt möglichem Collider entfernt. Kleine Fragmente
richten sich am tatsächlichen Boden aus und schrumpfen zum Ablauf. Dieselbe
Geometrie geht in Hauptbild und beide Schattenfelder ein.

Beton hinterlässt eine feste, 0,5 Meter über der ursprünglichen Basis endende
Restdeckung. Am Hang reicht deren Unterseite bis unter das Gelände; Darstellung,
Sichtprüfung, Beschuss, Navigation und Kollision verwenden denselben Quader.
Erhöhte Deckung behält ihre Unterstützungshöhe. Der feste Rest verschwindet
zusammen mit seinem Collider. Kettenexplosionen werden vollständig abgearbeitet,
bevor neue Reste die Sicht blockieren können. Wiederholter Beschuss vergibt
weder zusätzliche Punkte noch erneute Zerstörungsereignisse.

Validierung: 135 reguläre Tests bestanden, darunter elf neue Prüfungen für
Schadensschwellen, Treffer, Kettenreaktionen, Lebensdauer, Spielerfall/Klettern,
Gegnersprünge, Navigation, Poolgrenzen, Neustart und Hangkontakt. 22
Metal-validierte Bildprüfungen plus sieben gezielte Wiederholungen nach dem
Review. Gefundene schwebende Einschussmarken, zu regelmäßige Rissmuster und
Hangspalten wurden behoben. Keine verbliebenen Restschatten nach Ablauf.
[Beschädigt](native-roadmap/destruction-damaged.png),
[Restdeckung](native-roadmap/destruction-remnants.png),
[Hangkontakt](native-roadmap/destruction-hill.png),
[Prüfzähler](native-roadmap/destruction-checks.json).
Reproduzierbar beispielsweise mit `--smoke-test --scene destruction-barrier
--destruction-phase destroyed --destruction-hill`; weitere Phasen sind
`intact`, `damaged` und `expired`, Neustart über `--destruction-reset`.
