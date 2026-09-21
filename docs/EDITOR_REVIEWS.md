# Reviews der Editor-Issues

Jedes Arbeitspaket wird vor dem nächsten geprüft. Abschließende Integration und
Messungen stehen zusätzlich unter #44.

## #38 — Arbeitsoberfläche

Implementiert: separater Editorzugang, 3D/Draufsicht, getrennte Kameraeingabe,
Objektliste und Eigenschaften, transaktionales Undo/Redo, atomarer Basis-Dateidialog
und Schutz ungesicherter Änderungen bei Wechsel, Schließen und App-Ende.

Review: Auswahl nach Löschen/Undo, Rollback ungültiger Änderungen, Gesten als ein
Undo-Schritt, Dirty-Status nach Speichern/Undo/Redo, Text- gegenüber Szeneneingabe,
Fensterlebensdauer und Tastaturzugang geprüft. Visueller Befund behoben: kurze
Seitenleisten waren unten ausgerichtet; umgedrehte Dokumentansichten richten sie
oben aus. Rasterkontrast ebenfalls verbessert.

Prüfung: drei Sessiontests und vier bestehende Importtests bestanden; Debug-App
gebaut/signiert. In der App Editor öffnen, Draufsicht, Platzieren, Undo, Redo,
Schließen/Verwerfen und Rückkehr zum Hauptmenü geprüft. Korrigiertes Layout
anschließend erneut visuell geprüft. Kein offener Befund für #38.

## #39 — Landschaft

Implementiert: getrennte Maße und Größenpresets, fünf Seed-Vorlagen, vier
Höhenpinsel, rechteckige Materialspuren, Flachwasserbecken, Licht/Nebelfarbe und
Vegetationsdichte. Terrain und Spielwelt verwenden dieselben 1-m-Dreiecke.
Größenänderungen zeigen betroffene Inhalte an und behalten sie ausdrücklich.

Review: Grenzgrößen, weltfeste Verankerung, Wasserflächen nach Terrainänderungen,
alte Format-1-Dateien, atomare Transaktionen sowie Bodenkontakt geprüft. Bei
Wasserparametern wurde der Überlauf vor der Addition abgesichert. Bodenflächen
dürfen nach Verkleinerung im Entwurf außerhalb liegen; Spielvalidierung erklärt
diesen Zustand. Absolute Objekte erhalten Hinweise bei versenkter/schwebender
Position. Vier Terrain-/Wassertests und neun Dokumenttests bestanden. Die native
Oberfläche kompiliert; die vollständige Werkzeug-Bedienprüfung folgt zusätzlich
in #44. Kein offener Code-Review-Befund für #39.

## #40 — Katalog

44 Vorlagen: 10 Gebäude, 10 Naturmodelle, 13 Infrastruktur- und 11
Ausstattungsobjekte. Suche, Kategorien, Favoriten, Geometrievorschau, Maße sowie
Kollisions-/Zerstörungsangaben sind integriert. Vorschau und Spielwelt leiten
Geometrie aus denselben Bauteilen ab. Gebäude besitzen echte offene Durchgänge;
rein dekorative Elemente sind als solche bezeichnet.

Review: Jede Vorlage und jede Kategorie auf eindeutige Geometrie, IDs, Dimensionen,
Roundtrip und Kollisionsübereinstimmung geprüft. Alle zehn Gebäudeeingänge bleiben
nach Vierteldrehung erreichbar; Mindestskalierung verhindert unbrauchbar kleine
Durchgänge. Ein Namensraumfehler bei Bauteil-IDs wurde behoben: Instanznamen können
nicht mehr dieselbe Eingabe wie abgeleitete Bauteil-IDs erzeugen. Der Hashbereich
wurde für große Szenen erweitert. Vier Katalogtests und die vorhandenen Dokument-/
Terraintests bestanden. Kein offener Review-Befund für #40.

## #41 — Platzieren und Transformieren

Platzierungsgeist, 90°/180°-Winkelschritte, Raster/Bodenbezug, Ziehen und farbige
Transformationsgriffe sowie numerische Transformationen implementiert. Gruppen,
Duplikate, Sperren/Ausblenden und Warnungen für feste Überlappungen sind integriert.

Review: Gruppenkopien erhalten neue Instanz- und Gruppen-IDs; lange Gruppennamen
werden für Kopien innerhalb der Formatgrenze gehalten. Gesperrte Objekte bleiben
bei Transformation, Ausblenden und Löschen unverändert. Gesten rechnen immer vom
Startzustand, dadurch entsteht kein kumulierender Versatz. Griffnamen benutzen
einen getrennten Namensraum, damit zulässige Objekt-IDs nicht als Griff gelten.
Elf Objekt-/Katalog-/Sessiontests bestanden, nach den Review-Korrekturen zusätzlich
alle vier Objekttests. Kein offener Review-Befund für #41.

## #42 — Gameplay und Spieltest

Missionen, Pflichtanker-Vorlage, einzelne Marker mit Blickrichtung/Radius,
anspringbare Erreichbarkeitsdiagnosen sowie Generator/Hubtor-Verbindungen sind
implementiert. Der Spieltest verwendet eine unveränderliche Dokumentkopie in der
echten Simulation; Rückkehr behält Editor und Kamera. Prüfung ist abbrechbar.

Review: Kopieren und Löschen der Gerätebeziehungen, gesperrte abhängige Tore,
blockierte Startpunkte, Mission bis zum Erfolg, frischer Wiederholungszustand und
veraltete asynchrone Ergebnisse geprüft. Fokus berücksichtigt Geländehöhe.
Bedienprüfung: Marker-Vorlage gesetzt, Spiel gestartet, pausiert und über „Zurück
zum Editor“ zum unveränderten Entwurf zurückgekehrt. Menüeinträge erhalten nun
explizite Aktionen einschließlich eines Regressionstests für gleiche Titel.
Elf Coretests bestanden; nach den Sperrkorrekturen nochmals drei Gameplaytests.
Debug-App gebaut/signiert und Menü-/Spieltestablauf geprüft. Kein offener Befund.
