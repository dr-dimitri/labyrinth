# Native Leveldateien

Issue #37 liefert das versionierte Dokument und den gemeinsamen Adapter zur
Spielwelt. Die Editoroberfläche (#38), Landschaftswerkzeuge (#39), der große
Objektkatalog (#40) und die Dateiverwaltung (#43) folgen in eigenen Issues.

## Beispiel laden

Nach `make build` startet dieses externe Dokument direkt in der nativen App:

```sh
release/Blacksite.app/Contents/MacOS/BlacksiteMac \
  --level-file native/Examples/training-ground.blacksite-level.json
```

Im Einsatzbriefing ist das Trainingsgelände neben den fünf eingebauten Karten
wählbar. „Einsatz starten“ beginnt ein normales Spiel. „Erneut spielen“ verwendet
die beim Start festgehaltene Dokumentkopie, auch wenn sich die Datei inzwischen
ändert. Ohne `--level-file` bleiben die bisherigen Karten und Einstellungen aktiv.

Eine Darstellung mit dem tatsächlichen Metal-Renderer lässt sich so prüfen:

```sh
release/Blacksite.app/Contents/MacOS/BlacksiteMac \
  --level-file native/Examples/training-ground.blacksite-level.json \
  --smoke-test --output /tmp/blacksite-level.png
```

`--graphics-benchmark`, `--balanced`, `--width`, `--height` und `--seed` sind für
die Leveldiagnose ebenfalls verfügbar. Eingebaute Karten- und Szenenauswahl lässt
sich nicht mit `--level-file` kombinieren. Dateidialoge und Doppelklick-Zuordnung
sind noch nicht Bestandteil dieser Grundlage.

## Formatversion 1

Die UTF-8-JSON-Datei enthält `formatVersion`, eine stabile `id`, eine positive
`revision`, `name`, `description`, `bounds`, `terrain`, `environment`,
`resourceSet`, `objects`, `groups` und `markers`. Das Beispiel zeigt alle Felder.
`LevelDocument.encoded()` und `LevelDocument.decode(_:)` validieren das Dokument.
Unbekannte Versionen werden vor dem eigentlichen Inhalt geprüft und abgewiesen.
Eine spätere Migration muss ausdrücklich implementiert werden.

- Rechtshändiges Koordinatensystem in Metern: X/Z bilden die Grundfläche, +Y zeigt
  nach oben. Winkel sind im Bogenmaß angegeben.
- `bounds` legt den ganzzahligen Ursprung X/Z sowie Breite und Tiefe von jeweils
  12 bis 128 Metern fest. Das 1-Meter-Höhenraster enthält
  `(width + 1) * (depth + 1)` absolute Höhen, zeilenweise über Z, innerhalb jeder
  Zeile über X. Die gespeicherten Höhen sind maßgeblich; `terrain.seed` hält den
  Erzeugungsseed fest und wird von der CLI-Diagnose als Vorgabe genutzt.
- Objekte verwenden die untere Mitte als Positionsanker. `heightMode: ground`
  interpretiert Y als Geländeabstand, `absolute` als Weltkoordinate. Skalierung
  ist pro Achse von 0,25 bis 4 erlaubt. `quarterTurns: 0…3` dreht um die Y-Achse
  in 90°-Schritten; freie Drehung und Neigung benötigen spätere Kollisionsarbeit.
- Stabile `catalogID`s referenzieren zunächst `core.crate`, `core.barrier`,
  `core.container` und `core.block`. Instanz-IDs bleiben beim Umordnen erhalten.
  `groupID` verweist auf eine benannte Gruppe. Gruppen besitzen keine zusätzlichen
  Transformationen. `locked` und `hidden` sind Editorzustand; ausgeblendete
  Objekte bleiben Bestandteil des spielbaren Levels.
- `environment` enthält Sonnenrichtung, Lichtstärke, Nebelfarbe und bis zu acht
  rechteckige Bodenflächen. Erde, Gras, Fels und Asphalt steuern Bodenfärbung und
  Gameplay-Metadaten. Das vollständige Materialwerkzeug folgt in #39.
- Marker haben stabile IDs, Typ, Position, Blickrichtung und Radius. Ihre
  Y-Koordinate ist geländerelativ. Der Spielerstart nutzt die Blickrichtung,
  die Evakuierung den Radius. Weitere typspezifische Werkzeuge folgen in #42.

Dateien sind auf 8 MiB, 1000 Objekte, 256 Gruppen und 256 Marker begrenzt. Diese
Speichergrenzen sind keine Zusage zur Bildrate. Namen, Zahlen, IDs und Referenzen
werden vor dem Erzeugen der Spielwelt geprüft. Ressourcen stammen ausschließlich
aus dem eingebauten Katalog `blacksite`; externe Assetpfade werden nicht geladen.

## Entwurf und Spielwelt

Ein Entwurf darf fehlende oder mehrfach vorhandene Gameplay-Rollen und noch
außerhalb platzierte Objekte enthalten. Er bleibt speicherbar. Die Vorschau kann
vorläufige Anker verwenden, ohne sie in das Dokument zu schreiben.

`makeMap()` verlangt genau einen Spielerstart, Evakuierungs-, Daten-, Funk- und
Serviceanker sowie mindestens einen Verstärkungs- und Wellen-Sammelpunkt. Anker
müssen am Boden erreichbar sein, Objekte innerhalb der Kartengrenzen liegen.
Es sind höchstens sechs Patrouillenanker erlaubt. Fehler verhindern den Spielstart
mit einer konkreten Meldung; die Datei wird dabei niemals verändert.

`makeMap(purpose: .preview)` und `makeMap()` verwenden denselben Adapter zu
`MapDefinition`. Damit nutzen Darstellung, Kollision, Beschuss und Navigation
dieselben Höhen und Objektmaße. Die Simulation erhält eigene Werte; Zerstörung,
Spielerbewegung und Munition fließen nicht zurück in das Dokument.

## Review zu Issue #37

Nach der Implementierung geprüft: Formatgrenzen und fehlerhafte Dateien,
ID-/Gruppenreferenzen, Entwurf gegenüber Spielvalidierung, geländerelative und
absolute Höhen, Drehungen, unveränderte eingebaute Karten sowie Einsatzkopien.
Ein Regressionstest deckte zusammengefasste Briefing-Einträge bei identischen
Kartennamen auf; die Auswahl erhält jetzt alle Karten anhand ihrer Identität.
Die Bildprüfung korrigierte außerdem die Blickrichtung des Beispielstarts.

Die vollständige Swift-Suite bestand mit 257 Core- und 219 Mac-Tests; vier optionale
Hardwaretests wurden übersprungen. Nach dem Review bestanden zusätzlich alle acht
Levelimport-/Briefing-Tests einschließlich des neuen Namens-Regressionsfalls.
Der signierte Release-Build und die Metal-Darstellung des externen Beispiels waren
erfolgreich. In der laufenden App wurden Hauptmenü, Briefing, Einsatzstart,
Pause, Abbruchbericht und „Erneut antreten“ mit dem importierten Level geprüft.
Keine offenen Review-Befunde in diesem Arbeitspaket.
