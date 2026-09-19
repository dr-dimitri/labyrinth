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
| #16 | Gemeinsame Kartendefinitionen | Umgesetzt, Review/Tests und native Bedienprüfung bestanden |
| #17 | Vegetation und Untergrund | Umgesetzt, Review/Tests und Bildprüfung bestanden |
| #18 | Geländeabhängiger Tarnanzug | Umgesetzt, Review/Tests und native Bedienprüfung bestanden |
| #19 | Geräusche und Ablenkung | Umgesetzt, Review/Tests, nativer Audiomix und Bilder bestanden |
| #20 | Strom, Licht und Servicetore | Umgesetzt, Review/Tests, Release-Build und Bilder bestanden |
| #23 | Lokale Kontaktmeldungen | Umgesetzt, unabhängige Reviews, Tests und Bilder bestanden |
| #26 | Umgebung und Extraktionsentscheidung | Umgesetzt, Reviews, Tests, Build, Bilder und native Bedienprüfung bestanden |
| #25 | Briefing und Tarnungsfeedback | Umgesetzt, Review, gezielte Tests, AppKit-Bild und native Bedienprüfung bestanden |
| #21 | Rauch, Dampf und Gischt | Umgesetzt, Reviews, Tests, GPU-Abgleich, Bilder und native Eingaben bestanden |
| #22 | Durchbrechbare Zugänge | Umgesetzt, Reviews, Tests, reale Routen, Audio und Bilder bestanden |
| #24 | Drei Solo-Klassen | Umgesetzt, Reviews, Tests, drei reale Operationswege und Bilder bestanden; native Klassenprüfung in #31 ergänzt |
| #27 | Nebelwacht | Umgesetzt, Reviews, Tests, sechs Operationswege, Grafik-/Speicherprüfung bestanden; native Eingaben in #31 ergänzt |
| #28 | Sundkai | Umgesetzt, Reviews, Tests, sechs Operationswege, Grafik-/Speicherprüfung und native Start-/Eingabeprüfung bestanden |
| #29 | Kessel-9 | Umgesetzt, Review, Tests, Release, Grafik-/Speicherprüfung und native Bedienprüfung bestanden |
| #30 | Sirocco | Umgesetzt, Review, Tests, Release, Grafik-/Speicherprüfung und native Bedienprüfung bestanden |
| #31 | Varianten und Einsatzbericht | Umgesetzt, unabhängige Reviews, 464 Tests, Release, Grafik-/Bedienprüfung bestanden; Messschwankung dokumentiert |

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

Die native Bedienprüfung wurde nach Entsperren des Macs nachgeholt: Datenauftrag
wählen, Start, Pause/Fortsetzen, Granate und neuer Einsatz funktionieren. Mit
dem Paket von #18 wurde zusätzlich die Ergebnisaktion „Erneut antreten“ geprüft.
Die UI-Automation liefert nur eine verkleinerte Stage-Manager-Aufnahme; die
Bedienzustände wurden über die tatsächlichen nativen Accessibility-Elemente
bestätigt. Die vollständige Bildprüfung stammt aus den Metal-Prüfszenen.

### #17 – Vegetation als Sichtschutz

Fünf klar abgegrenzte Gras-/Buschflächen verwenden dieselben elliptischen,
geländeabhängigen Hüllen für Grafik und Wahrnehmung. Die KI prüft weiterhin
zuerst Sichtkegel und harte Deckung; durchquertes Blattwerk verlangsamt die
Erkennung anhand dreier Körperhöhen. Die Geschwindigkeit bleibt mindestens
ein Viertel des normalen Werts. Bestätigter Kontakt, Kugeln und Explosionen
werden durch Pflanzen nicht gelöscht oder blockiert. Lokale Umweltproben
unterscheiden Boden, Blattdichte und tatsächliche Dachauflagen.

Die Grafik baut die Pflanzen beim Kartenladen. High und Balanced verwenden
identische Pflanzen, Windgrenzen und Blattmasken; Hauptbild sowie Nah-/
Fernschatten nutzen denselben Ausschnitt. Das Review korrigierte eine
zonenabhängige Ausdünnung und unsichtbare Mini-Zonen: jetzt feste Flächendichte,
maximal 96 Pflanzen je Zone, 512 je Karte und 16 Zonen, mindestens 0,6 m
Breite/Tiefe und 0,25 m Höhe. Ungültige oder leere Geometrie wird abgewiesen.
Die aktuelle Karte besitzt 160 Pflanzen in fünf zusätzlichen Grafikinstanzen.

Validierung: vollständiger Lauf mit 120 Core- und 91 gemeldeten Mac-Tests
bestanden; nach den Reviewfixes weitere 17 Core- und zehn Mac-Tests bestanden.
Acht finale Metal-Szenen prüfen Übersicht, Boden, Liegen, Rand, Containerdach
und beide Grafikprofile. Das unabhängige Code-Review ist freigegeben.
Zwei Karten-Rundwechsel halten die GPU-Allokation pro Karte konstant:
314,98 MiB für Blacksite, 196,38 MiB für das Prüfgelände (Balanced, 1280×800).
Das sind für Blacksite 6,47 MiB mehr als bei #16.

Der vergleichbare optimierte Kampftest benötigt 8,49 µs pro Schritt gegenüber
8,64 µs in der Ausgangsmessung; der kleine Unterschied ist kein belegter
Leistungsgewinn. Ein separater synthetischer Sichtquerytest mit flachem Gelände
und ohne Hindernisse misst 0,023/0,811/10,371 µs für 0/1/16 überlappende Zonen.
Er deckt insbesondere noch unbestätigte Sichtkontakte ab, misst aber keine
gesamten Frames. [Messdaten](native-environment/issue17.json).

### #18 – Geländeabhängiger Tarnanzug

Die Feldausrüstung bietet normale Kleidung, Vegetations- und Mineraltarnung.
Ein Tarnanzug ersetzt eine Splittergranate. Nach 1,5 Sekunden ruhiger Haltung
auf passendem Boden erschwert er neue Sichtkontakte auf Distanz; kurze Distanz,
Bewegung, starkes Drehen, Klettern und Schüsse begrenzen den Vorteil. Ein Schuss
sperrt ihn drei Sekunden. Bestätigte Gegnerkontakte bleiben erhalten. Die
Anzeige beschreibt nur die eigene Haltung und Bodenauflage, keine verborgenen
Gegner. Stoff und Handschuhe tragen das gewählte Muster ohne neue Texturen oder
zusätzliche Grafikinstanzen.

Unabhängiges Code- und Bildreview bestanden. Zwei Prüfszenen verloren beim
Zurücksetzen beziehungsweise Kartenwechsel den Loadout; beide sind korrigiert.
Alle 128 Core- und 97 gemeldeten Mac-Tests bestehen. Sie prüfen unter anderem
Entfernungen, tatsächliche Bewegung statt Tastendruck, Bildratenunabhängigkeit,
Schüsse gegenüber Leerabzug/Nachladen, Pause und Neustart. Sieben Metal-Szenen
prüfen beide Muster, normale Kleidung, Nachladen, Wandhaltung, Scope und Reset.
Release-Build, Signaturprüfung und Smokecheck bestehen.

In der gebauten App wurden Auswahl, Abbrechen ohne Änderung, Übernehmen,
Missionsstart mit drei Granaten, Verbrauch, Pause/Fortsetzen und Wiederholung
nach echter Niederlage geprüft. Retry stellt Gesundheit und Startvorrat wieder
her und behält das Tarnmuster. Anschließend wurde die ursprüngliche normale
Kleidung mit vier Granaten wiederhergestellt. [Prüfdaten](native-environment/issue18.json).

### #19 – Geräusche und Ablenkung

Spieler und Gegner erzeugen Schritte anhand tatsächlicher Bodendistanz. Erde,
Vegetation, Kies, Metall, Wasser, harte Flächen und Holz besitzen eigene Klänge
und Hörweiten; Tempo und Haltung beeinflussen die Stärke. Quellort und Zeitpunkt
eines Reizes bleiben eingefroren. Hindernisse dämpfen den Schall, Maschinen
maskieren ihn am Hörer begrenzt. Nahe Schüsse und Explosionen bleiben auffällig.
Die Westdachmaschine besitzt einen gemeinsamen An/Aus-Zustand für KI, Audio und
Anzeige. Die Spielerbedienung des Generators folgt in #20.

Zwei physische Geräuschköder senden jeweils höchstens sechs Impulse in zwölf
Simulationssekunden. Frischer bestätigter Kontakt/Beschuss hat Vorrang. Die
Standardtaste F ist frei belegbar; ältere eigene Belegungen bleiben erhalten.
Optionale Richtungstexte und VoiceOver nennen nur tatsächlich hörbare Quellen.
Der Audioregler verändert keine KI-Regeln. Grenzen: 64 gespeicherte Hörreize,
zwei aktive Köder, vier Maschinen, 16 Einmalstimmen und vier Maschinenloops.
Die Materialklänge werden einmalig vorberechnet.

Unabhängiges Core-/Audio-/UI-/Bildreview bestanden. Korrigiert wurden unter die
Auflage geratene Landegeräuschquellen, falsche Geräuschvererbung unter Straßen
und die bisher festen Blacksite-Grenzen der Granatenphysik. Neue Karten nutzen
nun ihre eigenen Grenzen. Ein Patrouillentest wurde korrigiert: Die ursprüngliche
Wache stoppte nach Sichtkontakt korrekt vor dem nächsten Schritt.

Validierung: 137 Core-Tests bestehen nach allen Korrekturen; alle 106 gemeldeten
Mac-Tests bestehen, einschließlich zwei ausdrücklich aktivierter AVAudioEngine-
Offlineprüfungen für tatsächliches PCM, getrennte Busse, Limiter, Maschinen,
Pause/Mute/Aus/Reset. Die optionale Metal-Texturuploadprüfung war dabei nicht
aktiviert. Drei Metal-validierte Bilder zeigen Maschine an/aus und den auf dem
Dach geworfenen Köder; Zustand, Auflage und Schatten wurden unabhängig geprüft.
Dies ist keine Hörprobe über die Lautsprecher des Macs. Der optimierte Test mit
zwölf Gegnern misst 8,90 µs pro Simulationsschritt (fünf deterministische Läufe),
gegenüber 8,64 µs im Ausgangsstand; das ist keine Gesamtbildrate.
[Prüfdaten](native-environment/issue19.json).

### #20 – Strom, Licht und Servicetore

Ein erreichbarer Generator schaltet Maschinenlärm und zwei gerichtete Strahler.
Das Servicetor verwendet für Bewegung, Sicht, Beschuss, Navigation und Schatten
seine aktuelle Geometrie. Es stoppt vor Figuren und kann nach Stromausfall von
Hand weitergeöffnet werden. Zerstörung lässt einen benutzbaren Durchgang zurück.
Ein gemeinsamer E-Kontext mit Haltefortschritt verhindert Doppelaktivierungen.

Lichtkegel, Reichweite und harte Abschattung stammen aus denselben Daten für KI
und Grafik. Zwei 512²-Schattenkarten benötigen zusammen 2 MiB. Lokale Terrain-
Ausschnitte begrenzen zusätzliche Zeichenarbeit; Kamera-unabhängige Auswahl
behält seitliche Schattenwerfer. Sonnenlicht bleibt vom Generator unabhängig.

Unabhängiges Code- und Bildreview bestanden. Korrigiert wurden unter anderem
die Generatorauflage, ungültige Lichtprojektionen und ein Stromausfall-Snapshot.
146 Core- und 118 gemeldete Mac-Tests bestehen, einschließlich aktiviertem
Offline-Audiomix. Acht Metal-validierte Bilder prüfen Wand/Gelände, einen echten
Skinned-Soldaten, Generator und fahrendes beziehungsweise manuell geöffnetes Tor.
Ein kampfisolierter Datenlauf prüft tatsächliche Aufnahme, Weg und Torpassage bis
zur Extraktion; er ersetzt keinen menschlichen Kampf-Durchlauf.

Der optimierte ARM64-Build, Ad-hoc-Signatur und Smokecheck bestehen. Gemessener
Core-Median: 9,04 µs je Schritt bei zwölf Gegnern. GPU-P95 bei 2560×1600:
13,92 ms High beziehungsweise 11,87 ms Balanced; Allokation 1213,52/341,14 MiB.
Das sind keine Messungen der gesamten Bildrate. [Prüfdaten](native-environment/issue20.json).

### #23 – Lokale Kontaktmeldungen und begrenzter Alarm

Eigener bestätigter Sichtkontakt startet einen 1,2 Sekunden langen Meldeversuch.
Sichtverlust, Verletzung und Tod brechen ihn ab. Ein Stromausfall verhindert den
Funkabschluss; ein naher Ruf bleibt möglich. Kontakte speichern Position und
Zeitpunkt beim Beginn. Empfänger untersuchen diesen Punkt, erhalten weder eine
aktuelle Spielerposition hinter Deckung noch eine automatische Feuerfreigabe.

Die erste Funkmeldung entsendet höchstens zwei vorhandene Wachen zu bekannten
Rückwegen und reserviert einmalig höchstens zwei weitere Gegner. Die bisherigen
sicheren Eintrittsprüfungen bleiben erhalten. Bereits übermitteltes Wissen und
reservierte Verstärkung verschwinden durch spätere Sabotage nicht. Grenzen:
vier gleichzeitige Melder, 16 historische Meldungen, zwei Abschlüsse je Gegner,
zwölf Sekunden Abstand; Funkhistorie läuft nach 20 Sekunden ab.

Physische Funkmodule, vier vorberechnete Audiocues und optionale Richtungstexte
verwenden die tatsächlichen Zustände beziehungsweise Hörreize. Eine hörbare
Meldung löst einmalig den Rückweg-/Anmarschhinweis aus. Der HUD-Zähler zeigt
eigene bestätigte Abschüsse statt einer unhörbar veränderten Gegnerpopulation.
Der Generatorprompt erklärt jetzt auch seine Wirkung auf den Funk.

Unabhängige Code-, Audio-, UI- und Bildreviews bestanden. Im Paketlauf bestehen
alle 130 gemeldeten Mac-Tests mit aktiviertem Offline-Audiomix und die bisherigen
146 Core-Tests. Die neun neuen Alarmtests bestehen nach drei reinen Fixture-
Korrekturen: tatsächliche Wachenzuordnung, gültige Autorendaten und kontrollierte
Sicht für die zweite Meldung. Drei Metal-validierte Szenen prüfen Anlauf,
Übermittlung und Unterbrechung durch einen echten Sniperschuss. Der kleine
LED-Farbwechsel ist im weiten Bild nicht sicher beurteilbar. Ruhiger und
alarmierter Datenlauf verwenden echte Bewegung bei isoliertem Kampf.

Der optimierte Core-Test benötigt 14.52 µs je Schritt. Er enthält jetzt
die tatsächliche Alarmantwort (zwölf Startgegner, bis zu 14 aktive Gegner).
Die Arbeitslast unterscheidet sich daher von früheren Messungen; die neue
Ausgabe weist beide Populationsgrenzen aus. [Prüfdaten](native-environment/issue23.json).

### #26 – Feldoperation und Evakuierungsentscheidung

Die Feldoperation verbindet optionale Funk-/Torvorbereitung mit der tatsächlichen
Datenaufnahme und zwei unabhängig definierten Ausgängen. Das Nordtor ist kürzer
und offen; der längere Wartungsweg nutzt die östliche Senke und Schutz durch den
festen Bunker gegenüber der Straße. Der aktive Core-Ausgang bestimmt HUD,
Fortschritt und Abschluss; ein blockierter Ausgang lässt die Alternative offen.
Verlassen, Sprung und Wechsel setzen den Timer zurück, tödlicher Schaden kann
keinen gleichzeitigen Sieg erzeugen. Vorbereitung und Alarm bleiben erhalten.

Unabhängige Core-, UI- und Grafikreviews abgeschlossen. 155 bestehende Coretests
und 140 gemeldete Mac-Tests bestanden im vollständigen Lauf; alle sieben neuen
Operationstests bestanden nach Korrektur einer zu großzügigen Spawn-Erwartung
der Diagnosekarte. Drei vollständige physische Blacksite-Routen wurden mit
isoliertem Kampf geprüft. Releasebuild, Signatur und vier Metal-Szenen bestanden.
Die nachgebesserten Diagnosekameras zeigen bodengebundene Evakuierungsringe
und physische Lampen. Native Bedienprüfung wurde nach Entsperren des Macs nachgeholt (siehe unten). [Prüfdaten](native-environment/issue26.json).

### #25 – Natives Einsatzbriefing und unveränderlicher Neustart

Das kompakte native Briefing bündelt veröffentlichte Karte, Auftrag,
Schwierigkeit, Tarnung und tatsächlichen Startvorrat. Die schematische Übersicht
zeigt bekannte Bauwerke, Wege und Ziele, ohne gegnerische Laufzeitdaten.
Abbrechen verwirft den Entwurf. Die Auswahl wird erst nach erfolgreicher
Ressourcenvorbereitung gespeichert; der Start aktiviert den vorbereiteten Einsatz
erst nach Abschluss des Sheets. Das Review beseitigte eine doppelte und dadurch
nicht atomare Ressourceninitialisierung.

Retry rekonstruiert exakt die ursprüngliche Karte samt Version, Seed, Auftrag,
Schwierigkeit und Ausrüstung; neue Menüeinstellungen ändern den laufenden
Einsatz nicht. Ein neuer Einsatz erhält einen neuen Seed. Zwölf gezielte Tests
bestanden auf einem isolierten Abbild des tatsächlich vorgemerkten Commits,
einschließlich der letzten Startkorrektur. Ein echtes AppKit-Bild belegt das
lesbare Layout bei 860×550 Punkten. Native Eingaben mit Start/Pause/Fokus/Retry wurden inzwischen zusätzlich
am gestarteten Programm geprüft (siehe unten). [Prüfdaten](native-environment/issue25.json).

Nachgeholte native Bedienprüfung für #25/#26: Das tatsächliche Briefing wurde
geöffnet, eine Mineral-Tarnung verworfen und anschließend über „Einsatz starten“
gestartet. Der HUD zeigte die Feldoperation und den passenden Vorrat. Einstellungen
während der Pause, Rauchwurf mit pausiertem Zünder, Minimieren mit automatischer
Pause, Fortsetzen und ein einzelner Schuss funktionierten. Nach tatsächlichem
Tod durch Gegner stellte Retry die ursprüngliche Ausrüstung und volle Gesundheit
wieder her. Danach wurden die vorherigen Menüwerte wiederhergestellt.

### #21 – Gemeinsame Rauchvolumen für Sicht und Grafik

Rauchgranaten zünden nach 1,5 Sekunden und lösen sich nach zehn Sekunden auf.
Höchstens vier begrenzte Volumen teilen sich mit Dampf und Sprühnebel dieselbe
Dichteberechnung in Core und Metal. Wände und geschlossene Tore begrenzen die
Wolken; Schüsse und Schaden bleiben physisch. Dichter Rauch unterbricht aktuelle
Sicht und Funkmeldung, löscht aber kein zuvor erworbenes Wissen. Der native HUD
zeigt Vorrat und tatsächliche Taste; Pause hält auch den Zünder an.

Unabhängige Reviews, 171 Core- und 152 Mac-Tests bestanden, einschließlich eines
echten Metal-Abgleichs der optischen Tiefe. Das Review fand einen praktischen
Fehler: Entfernter, optisch irrelevanter Rauch änderte den normalen Takt der
harten Sichtprüfung. Eine Prüfung der tatsächlichen optischen Strecke und ein
Bewegungsregressionstest beheben das. Zehn Metal-Szenen decken Innen-/Außensicht,
Rand, erhöhte Position, Tor, Überlagerung, Vergrößerung und Ablauf ab.

Vier aktive Wolken benötigen in der kleinen Diagnosekarte bei 2560×1600
GPU-P95 4,40 ms (High) beziehungsweise 3,61 ms (Balanced); es entstehen keine
zusätzlichen Volumen-Drawcalls. Der optimierte Core-Lauf misst 14,94 µs je Schritt.
Die korrigierte Wahrnehmung ändert Ablauf und Arbeitslast, daher ist dies kein
gleichwertiger Vorher-/Nachher-Geschwindigkeitsvergleich. Diese Messungen sind
keine vollständigen Spiel-FPS. [Prüfdaten](native-environment/issue21.json).

### #22 – Durchbrechbare Zugänge und getrennte Glasregeln

Zwei optionale Blacksite-Verbindungen lassen sich durch leichte Metallpaneele
beziehungsweise klare Glasfronten öffnen. Umwege bleiben erhalten. Glas lässt
Sicht durch, hält aber Kugeln, Körper, Granaten und Explosionen bis zum Bruch auf.
Der öffnende Schuss endet noch an der Scheibe. Öffnung, KI-Navigation, Kollision
und Schatten folgen demselben Zustand; feste Rahmen bleiben bestehen. Kleine
zeitlich begrenzte Scherben erzeugen Schritte, aber keine unsichtbare Schadens-
oder Kollisionsfläche. Matte Markierungen machen intakte Scheiben lesbar.

Reviews behoben die falsche Scherben-Auflage auf Dächern und einen widersprüchlichen
Fallback für nicht zugeordnetes Glas. 180 Core- und 163 Mac-Tests sind abgedeckt;
der korrigierte kurze Hilfetext besteht die erneute Layoutprüfung. Neun native
Audiotests einschließlich echtem Offline-Mix sowie sechs Synthese-/Hörtests
bestanden. Zwölf Metal-Szenen zeigen beide Materialien und alle drei Zustände
auf beiden Grafikstufen. Bestehende vollständige Operationswege bleiben gültig;
die neuen Zugänge verkürzen tatsächliche KI-Routen von rund 20–21 auf rund 8 m
und sind nach Öffnung physisch begehbar.

Der optimierte Core-Lauf misst 17,88 µs je Schritt mit acht zusätzlichen
Blacksite-Körpern. Das ist keine Spiel-FPS-Messung. Der optimierte Appbuild mit
Signatur und Smokecheck bestand; die abschließenden Glassicherheitsmarkierungen
wurden anschließend auf beiden Stufen durch Metal geprüft.
[Prüfdaten](native-environment/issue22.json).

### #24 – Drei feste Klassen mit Umweltwerkzeugen

Aufklärer speichern beim tatsächlichen Zielen höchstens drei selbst sichtbare
Kontaktpunkte für zwölf Sekunden und tragen einen Geräuschköder. Die Punkte
bleiben fest und verschwinden hinter Deckung oder dichtem Rauch. Pioniere
platzieren eine reale Durchbruchladung bis zwei Meter Entfernung mit drei
Sekunden Zünder und Selbstschaden; ausgewiesene Geräte bedienen sie in 35 %
weniger Zeit. Sturm besitzt zwei Rauchgranaten und mehr AR-Reserve. Alle haben
beide Waffen und dieselbe Gesundheit; Tarnung kostet klassenunabhängig eine
Splittergranate. Die neue Aktion ist frei belegbar, bestehende Würfe behalten
ihre Tasten. Briefing, HUD, Einstellungen und Retry verwenden dasselbe Kit.

191 Core- und 174 Mac-Tests bestanden vollständig; neun abschließende Tests
decken die vergrößerten Marker und das Briefing ab (insgesamt 175 Mac-Tests).
Die unabhängigen Reviews korrigierten die Auflage gefallener Ladungen auf
Hängen. Fünf Metal-Szenen und drei AppKit-Briefings bestanden die Bildprüfung.
Drei vollständige Blacksite-Operationen mit tatsächlichem Werkzeugverbrauch
und verschiedenen Ausgängen bestanden bei ausdrücklich isoliertem Kampf.
Sie belegen Wege und Zustände, nicht eine abgeschlossene menschliche
Balancingprüfung. Der optimierte Appbuild mit Signatur und Smokecheck bestand.
Die native Bedienprüfung ist wegen erneut gesperrtem Mac für den Abschluss
vorgemerkt; die App selbst startet. [Prüfdaten](native-environment/issue24.json).

### #27 – Nebelwacht

Die Fjordstation besitzt fotografische nasse Küstenmaterialien, gelbe Module,
ein geschlossenes Radom und bewegtes Meer außerhalb der Arena. Zwei echte
Kletterketten ergänzen fünf geprüfte Bodenwege. Die kurze Versorgungsextraktion
liegt rund 38 m vom Datenziel entfernt, der gedecktere Felsausgang rund 57 m.
Zwei Gischtquellen kündigen ihre reproduzierbaren Zeitfenster drei Sekunden
vorher mit Wind, Leuchten und tatsächlich hörbaren lokalen Hinweisen an.
Spieler und KI verwenden dieselbe optische Dichte; Kugeln bleiben unverändert.

Unabhängige Reviews korrigierten eine zu schmale Kletterstufe, die Position
der Gischt am Rückweg, die offene Radomunterseite, eine helle Himmelsnaht und
veraltete Dampfhinweise nach Stromverlust. 198 Core- und 191 Mac-Tests bestanden;
ein zusätzlicher Test zur veröffentlichten Karte bringt die abgedeckten
Mac-Tests auf 192. Sechs Auswahl-/Briefingtests und 17 Prüfungen einschließlich
echtem Audiomix und Metal-Texturupload bestanden nach den letzten Ergänzungen.
Alle drei Klassen schließen je einen ruhigen und alarmierten Operationsweg ab;
diese echten Bewegungs-/Interaktionsläufe isolieren den Kampf ausdrücklich.

Vierzehn finale Metal-Bilder in High/Balanced, Felsweg und AppKit-Briefing wurden
geprüft. Der Core benötigt mit Gischt im Median 9,86 µs, ohne 10,26 µs je Schritt
bei neun Startgegnern und bis zu zwei regulären Alarmverstärkungen. Unterschiedliche
KI-Entscheidungen erlauben daraus keinen isolierten Kostenvorteil der Gischt.
Bei 2560 × 1600 liegen GPU-P95 mit Gischt bei 3,95 ms/847,41 MiB (High) und
6,07 ms/240,95 MiB (Balanced); beide bleiben unter den vorher festgelegten
Budgets. Drei Kartenrundwechsel je Profil halten die Allokationen konstant.
Diese Teilsystemmessungen sind keine Spiel-FPS. [Messdaten](native-environment/issue27.json).

Die optimierte ARM64-App, Signatur und Metal-Startprüfung bestanden auch nach
Freischaltung der Karte. Die native Bedienprüfung bleibt vorgemerkt: macOS ist
gesperrt, CUA konnte das gestartete Fenster nicht übernehmen. Die bereits
angefragte Entsperrung steht noch aus; Auswahl/Retry und Darstellung wurden
zusätzlich automatisiert geprüft.


### #28 – Sundkai

Der Kühlhafen bietet einen gedeckten Lagerweg, zwei flache Watbecken und einen
höheren Dammweg. Zwei Relais können in beliebiger Reihenfolge bedient werden.
Danach lassen sich Versanddaten bergen; erst dadurch werden beide trockenen
Ausgänge freigegeben. Alle
Pflichtziele liegen im Trockenen. Drei Holzquerungen liegen auf echtem erhöhtem
Gelände; zerstörbare optionale Deckung sperrt die Hauptwege nicht. Sichtbare
Zäune markieren die tatsächlichen Arenagrenzen vor der tiefen Meereskulisse.

Wasserfläche, 25 cm tiefer Grund, Auflage und Einschläge stammen aus denselben
Daten. Tatsächlich watende Spieler und Gegner bewegen sich mit Faktor 0,65;
Schritte und Landungen erzeugen ortbare Wassergeräusche. Springen beendet den
Bodenkontakt, die Landung bleibt hörbar. Wasser bietet keine automatische
Tarnwirkung. Eine gemeinsame Wasserzeichnung ohne zusätzliche Renderziele und
höchstens 32 Kontaktringe ergänzen die begrenzten vorhandenen Effekte.

Unabhängige Reviews korrigierten von Nachbarfundamenten angehobene Bodenränder,
fehlende Wasserspritzer bei untergetauchten Granaten sowie irreführende Hinweise
zu Pflichtrelais und E-Interaktion. Alle 209 Core- und 205 Mac-Tests bestanden,
einschließlich echtem Audio, Texturupload und Metal-Rauchabgleich. Zwei ergänzte
Auswahl-/Kontaktprüfungen bringen die abgedeckten Mac-Tests auf 207; der letzte
gezielte Lauf mit 14 Tests bestand. Sechs vollständige Operationsläufe decken
alle drei Klassen und beide Relaisreihenfolgen ab. Diese tatsächlichen Bewegungs-
und Interaktionsläufe isolieren den Kampf ausdrücklich.

High/Balanced-Bilder prüfen Wasser, Ufer, Landung, Schuss, drei Explosionen,
beide Relaisreihenfolgen und Figuren auf Wasserboden, Ufer und Containerdach.
Fotografische PBR-Bilder für Schlamm und Blattwerk sind als sieben unveränderte
CC0-Originale dokumentiert; die gesamte Offline-Prüfung bestätigt 43 Bilddateien.

Der Core benötigt mit Wasser im Median 9,40 µs pro Schritt, ohne 9,93 µs.
Neun ursprüngliche Gegner, echte Alarmverstärkung und unterschiedliche
Kampfverläufe erlauben daraus keine isolierte Aussage über Wasser-Mehrkosten.
GPU-P95 bei 2560 × 1600 beträgt beim Waten 14,77 ms High bzw. 11,24 ms Balanced;
mit drei echten Wasserexplosionen 15,49 bzw. 13,45 ms. Die Allokationen betragen
1077,69 bzw. 301,28 MiB. Alle Werte liegen unter den vorher gesetzten Budgets.
Drei Kartenrundwechsel je Profil halten die Allokation pro Karte konstant.
Dies sind Teilsystemmessungen, keine Spiel-FPS. [Prüfdaten](native-environment/issue28.json).

Die optimierte ARM64-App mit Sundkai-Auswahl, Signatur und Metal-Startprüfung
besteht. Nach Verfügbarkeit des Macs wurde auch die echte native Bedienung
geprüft: Kartenauswahl, Missionsstart mit 0/2 Pflichtrelais, Pause/Fortsetzen,
Granatenwurf, Hinlegen, tatsächlicher Gegnerschaden und ein neuer Einsatz mit
vollständigem Startvorrat. Die ursprüngliche Auswahl wurde anschließend
wiederhergestellt. Deterministischer Retry und vollständige Missionswege sind
automatisiert geprüft; der native Kurztest ist kein kompletter manueller Einsatz.
Auf Wunsch des Nutzers endet die Arbeit nach diesem Issue. Weitere Karten,
Varianten und die gemeinsame Veröffentlichung bleiben offen.


### #29 – Gekoppelte Wartungsschotts in Kessel-9

Kessel-9 ergänzt drei reale Wege, eine östliche Geländerampe und die Folge
Leitstanddaten → unteren Funkverteiler acht Sekunden halten → Ausgang wählen.
Ein Schalter tauscht zwei Schotts; ein belegter Bewegungsraum pausiert beide.
Zerstörung des Schalters hält die tatsächliche Stellung, beide äußeren Umwege
bleiben offen. Neun physische Operationsdurchläufe decken alle Klassen und
normale, vorbereitete sowie zerstörte Schalterzustände ab. Tests isolieren den
Kampf; vollständige menschliche Kampfdurchläufe werden damit nicht behauptet.

Unabhängiges Core-/Mac-/Bildreview abgeschlossen. 219 Core- und 209 gemeldete
Mac-Tests bestanden, nach den letzten Briefing-/Diagnosekorrekturen fünf
gezielte Mac-Tests. Release-Build und Signaturprüfung bestanden. Native Auswahl,
Feldoperationsstart, Granatenverbrauch und Pause/Fortsetzen wurden bedient.
Das Bildreview führte zu einer versetzten Gerätemarkierung mit Ankerlinie,
damit der Funkpunkt lesbar bleibt, und zur Schalterlegende. Diagnoseeffekte
werden nun bei jedem tatsächlichen Simulationsschritt an den Renderer übergeben.

Core-Median: 12,80 µs pro Schritt, neun Startgegner mit echten Alarmfolgen und
Granaten. GPU-P95 bei 2560×1600: 12,07 ms Hoch / 10,09 ms Ausgewogen;
Allokationen 1170,64 / 321,94 MiB. Die Karten-Rundwechsel stabilisieren sich.
Diese Werte sind Teilzeiten, keine Gesamtbildrate. [Prüfdaten](native-environment/issue29.json).

### #33 – Nahziele hinter dünnen Wänden

Das unabhängige Review reproduzierte eine Wache, die trotz gültigem Umweg vor
dem Westpaneel stehenblieb. Der direkte Anlauf auf Ziele unter 2,6 m prüft jetzt
den vorhandenen Körper-Sweep; bei blockiertem Weg bleibt der berechnete Umweg.
Zwei Regressionen verwenden echte Bewegung am intakten und geöffneten Paneel.
Issue separat angelegt und Fix unabhängig geprüft; Commit `f6c2490`.

### #30 – Sirocco

Drei Wege durch das Gewächshaus und zwei Rückwege bleiben auch mit intakten
Scheiben erreichbar. Zwölf Scheiben besitzen echte Kollisions-/Sichtzustände;
Rahmen bleiben nach dem Bruch stehen. Der Funkpunkt liegt im Zentralgang. Ein
gezielter Durchbruch verkürzt den Rückzug messbar. Angehobene Fundamentränder
an den östlichen Scheiben wurden im Review behoben.

227 Core- und 210 Mac-Tests bestanden; vier abschließende Diagnosetests prüfen
zusätzlich reale Schüsse und Granaten. Alle Klassen erreichen beide Ausgänge
mit tatsächlicher Bewegung und Interaktion bei isoliertem Kampf. Unabhängiges
Code-/Bildreview, optimierter Release-Build und Signaturprüfung bestanden.
Native Kartenauswahl, Start, Granate und Pause/Fortsetzen wurden bedient; dies
ist kein vollständiger menschlicher Kampfdurchlauf. Auch die finalen Kessel-9
Briefingkorrekturen sind in diesem Release enthalten und bildlich geprüft.

Core-Median: 9.89 µs/Schritt mit neun Startgegnern und echten Kampfereignissen.
GPU-P95 bei 2560×1600: 10,29 ms Hoch / 9,53 ms Ausgewogen; offene Scheiben
9,69 ms Ausgewogen. Allokationen: 737,23 / 214,13 MiB. Zwei Kartenrundwechsel
halten die Allokationen konstant. Alle Werte unterschreiten die vorher
gesetzten Budgets; keine Gesamtbildraten-Aussage. [Prüfdaten](native-environment/issue30.json).

### #31 – Einsatzvarianten, Bericht und Abschluss

Alle fünf Karten erhalten in Definitionsversion 2 je drei feste Varianten mit
unterschiedlichen Datenankern und tatsächlichen Patrouillenzielen. Strom, Tore,
Schotts, Glasfelder und Gischtphase bilden geprüfte Kombinationen. Das Briefing
zeigt die tatsächlich gewählte Lage; der gesamte 64-Bit-Seed bleibt beim
Klassenwechsel und Retry erhalten. Ein neuer Einsatz wechselt die Variante.

Der Bericht unterscheidet Erfolg, Niederlage und Abbruch, nennt Alarmmeldungen,
Geräteaktionen, genutzten Ausgang und tatsächlichen Verbrauch. Nachschub und
vorbereitete Startzustände verfälschen die Zähler nicht. Die Momentaufnahme
erfolgt nach dem vollständigen Ereignisblock, auch bei einem tödlichen eigenen
Fassschuss. Der Bericht bleibt lokal für die laufende App-Sitzung.

248 Core- und 216 Mac-Tests bestanden. 30 vollständige Bewegungs-/Interaktionswege
decken alle 15 Varianten, beide Ausgänge und alle Klassen ab; zwölf echte
Alarmfälle prüfen den Stromzustand und endliche Verstärkungen. Replays über
alle Varianten vergleichen sämtliche Ereignispayloads, Figurenzustände
und Statistik. Die physikalischen Routen isolieren ausdrücklich den Kampf.
Unabhängige Core-/Mac-/Routen-/Bildreviews sind abgeschlossen.

In der nativen App wurden Sirocco-Start, Granate, Pause, Abbruchbericht, derselbe
Retry-Seed mit vollem Vorrat und ein neuer Seed mit anderer Variante geprüft.
Nebelwacht wurde mit allen drei Klassen gestartet; Rauch, Köder und eine zu weit
entfernte Pionierladung bestätigen Verbrauch und erlaubte Eingaben. Die zuletzt
gespeicherte Sirocco-/Sturm-Auswahl wurde wiederhergestellt. Dies sind native
Bedienprüfungen, keine Behauptung vollständiger menschlicher Kampfdurchläufe.

Der optimierte ARM64-Release, Signatur und 43 Assetprüfungen bestehen. Alle fünf
Briefings, Berichte, echtes Sirocco-Granatenbild sowie finale Wasser-/Glasbilder
wurden geprüft. Der Core benötigt in derselben Sirocco-Referenz 9,93 statt
9,89 µs/Schritt; GPU-P95 Ausgewogen dort 9,71 statt 9,53 ms. Kartenrundwechsel
halten die Allokation stabil.

Die neue Blacksite-Startmessung zeigte vermeidbaren Aufwand hinter dem Terrain.
Der undurchsichtige Hauptpass zeichnet deshalb den Boden vor dem Blattwerk;
Geometrie, Detailstufen, Schatten und transparente Passes bleiben gleich. Das
1280×800-Vergleichsbild ist pixelidentisch. Bei 2560×1600 sinkt der Median von
drei GPU-P95-Läufen von 18,19 auf 14,53 ms. Die drei finalen Werte sind 14,53,
17,88 und 9,28 ms: Eine Wiederholung überschreitet weiterhin das 16,7-ms-Ziel.
Ausgewogen erreicht 7,28 und 13,04 ms, Speicher bleibt 1214,91 / 343,53 MiB.
Diese schwankenden Teilsystemmessungen garantieren keine gesamte Bildrate.
Nach der Rendereränderung bestanden nochmals alle 216 Mac-Tests.
[Prüfdaten](native-environment/issue31.json).

Auf ausdrücklichen Nutzerwunsch endet die Arbeit nach diesem Issue. Der gesamte
geprüfte Branch wird gepusht und über einen Merge-Commit nach `main` integriert;
die einzelnen Issue-Commits bleiben erhalten. Vorhandene lokale Browser- und
Electron-Arbeiten sind nicht Teil dieser Veröffentlichung.
