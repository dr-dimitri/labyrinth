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
| 6 | #2 Ego-Waffen und Hände | In Umsetzung |
| 7 | #3 Einschläge und Explosionen | Offen |
| 8 | #5 Texturbudget | Offen |
| 9 | #4 Schadensstufen und Trümmer | Offen |
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
Richtungsfehler behoben. Interaktive Bedienprüfung vorerst durch gesperrten Mac
unterbrochen; vollständiger nativer Paketbuild und automatisierte Tests geprüft.

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
