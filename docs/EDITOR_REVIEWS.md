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
