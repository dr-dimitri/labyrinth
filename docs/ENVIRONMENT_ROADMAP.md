# Umgebung als Gameplay

Umsetzung der [Roadmap #32](https://github.com/dr-dimitri/labyrinth/issues/32)
auf `codex/environment-gameplay`, Ausgangsstand `fa3e15b`.
Die native macOS-Version bleibt ein Offline-Solo-Spiel.

## Ablauf

Jedes Issue erhält eine geprüfte Umsetzung, ein unabhängiges Review und einen
eigenen Commit. Praktisch relevante Fehler werden im betroffenen Paket behoben;
zusätzliche eigenständige Verbesserungen erhalten ein eigenes Issue.
Veröffentlichung und Schließen der Issues erfolgen nach Abschluss und Prüfung.

| Issue | Inhalt | Status |
| --- | --- | --- |
| #16 | Gemeinsame Kartendefinitionen | Umgesetzt, Review/Tests bestanden; Fensterprüfung offen |
| #17 | Vegetation und Untergrund | Offen |
| #18 | Geländeabhängiger Tarnanzug | Offen |
| #19 | Geräusche und Ablenkung | Offen |
| #20 | Strom, Licht und Servicetore | Offen |
| #23 | Lokale Kontaktmeldungen | Offen |
| #26 | Umgebung und Extraktionsentscheidung | Offen |
| #25 | Briefing und Tarnungsfeedback | Offen |
| #21 | Rauch, Dampf und Gischt | Offen |
| #22 | Durchbrechbare Zugänge | Offen |
| #24 | Drei Solo-Klassen | Offen |
| #27 | Nebelwacht | Offen |
| #28 | Sundkai | Offen |
| #29 | Kessel-9 | Offen |
| #30 | Sirocco | Offen |
| #31 | Varianten und Einsatzbericht | Offen |

## Ausgangsprüfung

`native/scripts/test.sh` besteht vor den Änderungen (103 Core-Tests und 82
gemeldete Mac-Tests; die zwei optionalen Audio-/GPU-Pfade werden gesondert
aktiviert). [Leistungsreferenz](native-environment/baseline.json): Core aus
einem separaten Archiv des unveränderten Commits, Grafik mit dem vorherigen
Release-Build ohne parallelen Blacksite-Menüprozess. Auf dem Apple M2 Pro
benötigt der Core im Median 8,64 µs je Schritt bei zwölf Gegnern; der
Grafikbenchmark bei 2560 × 1600 meldet GPU-P95 13,22 ms (High) bzw. 12,59 ms
(Balanced) und 1204,39 bzw. 332,02 MiB GPU-Allokationen. Diese Messungen
belegen keine gesamte Spielbildrate. Tests prüfen Regeln und Erreichbarkeit;
native Bedien- und Bildprüfungen ergänzen sie.

## Prüfprotokoll

### #16 – Kartendefinitionen

Die Simulation liest Grenzen, Navigationsraster, Starts, Eintrittspunkte,
Missionsanker, Oberflächen und Terrain aus einer gemeinsamen Kartendefinition.
Renderer und Effekte verwenden deren Scenery, Ressourcen, Atlas-Ausschnitte,
Schattenraum und sichtbare Auflagen. Ladevalidierung und atomare GPU-Übernahme
erhalten beim Fehler die vorige Szene. Ein versetztes Prüfgelände oberhalb
18 m belegt die Trennung von den bisherigen Koordinaten und Höhenlimits.

Unabhängiges Review abgeschlossen. Behoben wurden der zurückgesetzte
Startblickwinkel, die abweichende Blacksite-Schattenausdehnung, zu spät
zurückgesetzte Effekte in Prüfszenen, fehlende Charakterressourcen und die
ungültige Schattenbasis bei senkrechter Sonne. Der alte Pine-Atlas-Ausschnitt
steht nun im Ressourcenmanifest statt implizit im Loader.

Validierung: vollständiger Paketlauf mit 111 Core- und 86 Mac-Tests bestanden;
nach den letzten Ergänzungen gezielt neun Kartentests und 13 Grafik-/Textur-/
Schattentests bestanden. Release-Paket gebaut, Ad-hoc-Signatur und Smokecheck
gültig. Metal-validierte Blacksite-/Fremdkartenbilder und zwei vollständige
Karten-Rundwechsel bestanden. Die wiederholten GPU-Allokationen bleiben bei
identischen Karten konstant. Der Blacksite-Bildvergleich zeigt eine mittlere
RGB-Abweichung unter 0,001 von 255 (24 von 1.024.000 Pixeln über acht Stufen).
[Messdaten](native-environment/issue16.json).

Die direkte native Fensterprüfung (Start, Pause, Retry) ist noch offen: Der Mac
war bei der Prüfung gesperrt. Sie wird vor Veröffentlichung nachgeholt.
