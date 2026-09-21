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

## #43 — Dateien, Bibliothek und Wiederherstellung

Atomare, synchronisierte Dateiersetzung; getrenntes Speichern unter und Export;
Bibliothek mit Namen, Grundriss und Datum; unabhängiger Import; Zugriff aus dem
Spielmenü (⌘L); Wiederherstellungskopie alle 20 Sekunden mit Angebot beim nächsten
Editorstart. Entwürfe benötigen weiterhin keine gültigen Gameplay-Marker.

Review: Simulierter Fehler unmittelbar vor dem Ersetzen erhält die Originaldatei
und den Dirty-Status. Save As erhält die Ursprungsdatei. Beschädigte, übergroße,
zukünftige und ressourcenfremde Dateien werden abgewiesen. Neuere Wiederherstellung,
inzwischen gespeicherter Inhalt und veraltete Kopien geprüft. Dokumentwechsel
beendet laufende Werkzeuge/Gesten und verwirft veraltete Prüfaufträge. Exportdateien
enthalten keine Rechnerpfade; nur lokale Wiederherstellungsmetadaten merken sich
die Quelldatei. Drei Persistenztests sowie fünf native Import-/Menütests bestanden.
Zusätzlicher nativer Test deckt Wiederherstellung, Speichern und Werkzeugreset ab.
In der App: Bibliothek aus dem Spielmenü geöffnet, Entwurf benannt/gespeichert,
Eintrag mit Datum angezeigt und erneut zum Bearbeiten geöffnet. Kein offener Befund.

## #44 — Integration und große Szenen

Drei reproduzierbare Editorrezepte, exportierte Beispiele, integrierte Kurzanleitung
und ausführlicher Einsteigertext implementiert. Der native Editorcheck erfasst
Laden/Speichern, Szenenaufbau, Auswahl/Transformation mit Inspector, SceneKit-/
Metal-Bildzeiten und zehn Ressourcenzyklen. Ergebnisse und Rohdaten stehen in
`EDITOR_PERFORMANCE.md` beziehungsweise `editor-metrics`.

Review-Befunde behoben: 2-m-Türen konnten je nach Position zwischen den 2-m-
Navigationslinien Gegner ausschließen; 3-m-Durchgänge und ein versetzter
Gebäudeeingangstest sichern den freien Zugang ab. Auswahl aktualisiert jetzt nur
Markierung/Griffe; der Referenzaufwand sank von 28,35 auf 0,24 ms (inklusive Inspector
5,05 ms). Bibliothekslesen läuft ebenfalls abbrechbar im Hintergrund. Ein frisch
geöffneter leerer Editor löst keine grundlose Speicherabfrage mehr aus. Die
Kurzanleitung ist scrollbar; der bestehende HUD-Test berücksichtigt den neuen
Editorzugang und prüft weiterhin Grenzen, Überlappungen und Trefferflächen.

Prüfung: Alle drei Beispiele in der Oberfläche erzeugt und gespeichert; App
vollständig beendet, anschließend alle drei aus der Bibliothek geladen/gespielt,
pausiert und unverändert zum Editor zurückgekehrt. Kartengröße geändert und durch
Undo vollständig zurückgesetzt. SceneKit- und Metal-Bilder geprüft. Alle 46
Katalogobjekte und die drei Rezepte bestehen die Roundtrip-/Geometrieprüfungen.
279 Coretests bestanden. Im vollständigen nativen Lauf bestanden alle Prüfungen
außer dem veralteten HUD-Titelvergleich; nach dessen Korrektur bestanden alle
sieben HUD-Tests. Nach der letzten Bedienkorrektur bestanden die zwölf Editor-/
HUD-Tests (ein optionaler Hardwaretest dabei deaktiviert). Der echte Spieltest-
Freigabetest wurde zuvor separat aktiviert und bestand drei Zyklen; vier andere
optionale Audio-/Metaltests blieben deaktiviert. Release-App gebaut/signiert,
500-Objekt-Messung und zehn Ressourcenzyklen erfolgreich. Kein offener Befund.
