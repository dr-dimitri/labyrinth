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
| 3 | #8 Sichere Verstärkungen | Offen |
| 4 | #10 Richtungsfeedback und räumlicher Sound | Offen |
| 5 | #1 Nahschatten | Offen |
| 6 | #2 Ego-Waffen und Hände | Offen |
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
