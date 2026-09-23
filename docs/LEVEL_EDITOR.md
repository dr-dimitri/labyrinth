# Mein erstes Level

Blacksite enthält einen nativen Editor für Macs mit Apple Silicon. Öffne ihn im
Hauptmenü über **LEVELEDITOR** oder mit **⌘E**. **⌘L** öffnet die eigenen Levels.

1. Gib rechts einen **Levelnamen** ein. Unter **Landschaft** wählst du Breite und
   Tiefe (12–128 m), eine Landschaftsvorlage und einen Seed. **Landschaft erzeugen**
   ersetzt das Gelände nach Rückfrage. Größenänderungen behalten vorhandene Objekte;
   eine Vorschau zählt Inhalte, die danach außerhalb liegen würden.
2. Wähle einen Höhenpinsel, Radius und Stärke. Ziehe mit der linken Maustaste über
   das Gelände. Heben, Senken, Glätten und Einebnen verändern die gespeicherten Höhen.
   Erde, Gras, Fels und Asphalt malen rechteckige Materialflächen. Flachwasser legt
   ein 30 cm tiefes Becken an. Licht, Nebelfarbe und Vegetation stehen darunter.
3. Suche links ein Gebäude oder Objekt, kontrolliere Vorschau und Maße und drücke
   **Objekt platzieren**. Der transparente Geist folgt der Maus; Linksklick setzt
   ihn, Escape bricht ab. Gebäude haben offene Eingänge. Hinweise erläutern, welche
   Teile kollidieren, zerstörbar oder dekorativ sind.
4. Wähle Objekte in der Ansicht oder Liste. Ziehen verschiebt, R dreht, farbige
   Griffe ändern Achse, Drehung oder Größe. Unter **Objekte** lassen sich Position,
   Skalierung, Raster und Bodenbezug genau einstellen. Shift erweitert die Auswahl;
   Gruppieren, Duplizieren (⌘D), Sperren und Ausblenden stehen links. Ausgeblendete
   Objekte bleiben im Spiel vorhanden. ⌘Z/⇧⌘Z nimmt jeweils eine ganze Geste zurück.
5. Unter **Spiel & Prüfung** wählst du den Auftrag. **Pflichtmarker als Vorlage
   setzen** legt die benötigten Start-, Ziel- und Gegneranker an. Danach kannst du
   einzelne Marker über **Marker platzieren** versetzen/ergänzen. Der Spielerstart
   hat eine Blickrichtung, die Evakuierung einen Radius. Ein schaltbarer Generator
   und ein Hubtor lassen sich unter **Objekte → Torversorgung** verbinden.
6. **Level prüfen** kontrolliert die Spielbarkeit. Wähle einen Hinweis und
   **Zum Hinweis springen**, um blockierte/fehlende Anker oder Zugänge zu korrigieren.
   Freie Wege brauchen Platz; dichte Deckung direkt vor Türen kann Gegner aussperren.
7. **In Bibliothek speichern** legt eine eigene lokale Datei an. ⌘S sichert weitere
   Änderungen. **Speichern unter** wechselt zu einer neuen Arbeitsdatei;
   **Exportieren** schreibt eine portable Kopie. Unter **Eigene Levels** stehen Name,
   Grundriss, Änderungsdatum, **Bearbeiten**, **Spielen** und **Importieren** bereit.
8. **Testen** startet die tatsächliche Spielwelt. Escape pausiert; **Zurück zum
   Editor** beendet den Test. Terrain, Objekte, Auswahl und Kamera des Entwurfs
   bleiben erhalten. Ein neuer Test startet mit frischem Spielzustand.

Die Kamera dreht mit rechter Maustaste, verschiebt sich mit mittlerer Maustaste
und zoomt per Mausrad. **3D / Draufsicht** wechselt die Ansicht; F fokussiert die
Auswahl. Eingaben in Textfeldern steuern nicht gleichzeitig die Spielkamera.

## Beispiele und Grenzen

Links oben bietet **Beispiel erstellen** ein Übungsgelände, einen bebauten
Außenposten und ein Waldgebiet mit 128 × 128 m und 500 gemischten Objekten an.
Die Vorlagen werden mit denselben Bearbeitungsoperationen erzeugt wie eigene Levels
und können sofort geändert, gespeichert und getestet werden. Die exportierten
Dateien liegen zusätzlich unter `native/Examples/editor-*.blacksite-level.json`.

46 Vorlagen stehen offline bereit: zehn Gebäude, zehn Naturmodelle,
14 Infrastruktur- und zwölf Ausstattungsobjekte einschließlich der beiden Geräte.
Die Spielkollision unterstützt Vierteldrehungen. Gebäude/Durchgänge sind mindestens
im Maßstab 1 zu verwenden; Hubtore unterstützen 0°/180° und Maßstab 1–1,5.
Im Spiel sind zusammen höchstens vier schaltbare Generatoren und Hubtore erlaubt.
Entwürfe mit mehr Geräten bleiben sichtbar, bearbeitbar und speicherbar;
**Level prüfen** erklärt das Limit vor dem Spielstart.

Das Gelände nutzt ein 1-m-Höhenraster. Pro Level sind bis zu 1000 Objektinstanzen,
256 Gruppen, 256 Marker, acht Bodenflächen und vier Flachwasserflächen (je höchstens
500 m², Tiefe 15–35 cm) speicherbar. Der gemessene Arbeitsumfang beträgt 500 gemischte
Objekte bei 128 × 128 m. Die [Leistungsmessung](EDITOR_PERFORMANCE.md) beschreibt
Hardware, Grafikstufe, Reaktionszeiten und Grenzen. Prüfen und Beispielaufbau laufen
im Hintergrund und können über **Vorgang abbrechen** beendet werden.

## Speichern und Wiederherstellen

Eigene Levels liegen unter `~/Library/Application Support/Blacksite/Editor/Levels`.
Externe Dateien können über **Öffnen** direkt bearbeitet werden. Import erstellt
eine unabhängige Kopie in der Bibliothek. Exportdateien benötigen ausschließlich den
mitgelieferten Katalog; Benutzerverzeichnisse oder externe Assets sind nicht nötig.

Alle 20 Sekunden wird ein geänderter Entwurf unter `Recovery` gesichert. Nach einem
unerwarteten Beenden bietet der nächste Editorstart eine neuere Kopie an. Du kannst
sie wiederherstellen, später entscheiden oder ausdrücklich verwerfen. Die erste
Kopie entsteht nach spätestens 20 Sekunden; ⌘S bleibt für wichtige Schritte sinnvoll.
Normales Schließen fragt nach Speichern/Verwerfen/Abbrechen. Erfolgreiches Speichern
oder ausdrückliches Verwerfen entfernt die Wiederherstellung dieses Fensters.

Ein Speicherfehler erhält den Änderungsstatus und die letzte gültige Datei. Ein
Ladefehler ersetzt den offenen Entwurf nicht. Auch ein noch nicht spielbares Level
kann gespeichert werden. Unbekannte Formatversionen, fehlende Katalogobjekte und
Dateien über 8 MiB werden mit einer Fehlermeldung abgewiesen. Spielfehler erscheinen
separat unter **Spiel & Prüfung** und verändern keine Datei.

## Diagnose für Entwicklung

```sh
make build
release/Blacksite.app/Contents/MacOS/BlacksiteMac \
  --level-file native/Examples/editor-training.blacksite-level.json
release/Blacksite.app/Contents/MacOS/BlacksiteMac \
  --editor-check --output-directory /tmp/blacksite-editor-check
```

Der Editorcheck erzeugt die drei Beispiele ohne manuelle Dateibearbeitung, lädt sie
erneut, prüft Simulation und Grafik und schreibt Messdaten sowie Vorschaubilder.
`--level-file` unterstützt außerdem `--smoke-test --output /tmp/level.png` und
`--graphics-benchmark --balanced --width 1280 --height 800`. Der ursprüngliche
Format-1-Beispielfall `training-ground.blacksite-level.json` bleibt erhalten.

## Formatversion 1

Die UTF-8-JSON-Datei enthält `formatVersion`, eine stabile `id`, eine positive
`revision`, `name`, `description`, `bounds`, `terrain`, `environment`,
`resourceSet`, `objects`, `groups` und `markers`. `mission` und Geräteverbindungen ergänzen diese Felder optional.
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
- Stabile `catalogID`s referenzieren die 46 eingebauten Vorlagen. Die ursprünglichen
  vier `core.*`-IDs bleiben kompatibel. Instanz-IDs bleiben beim Umordnen erhalten.
  `groupID` verweist auf eine benannte Gruppe. Gruppen besitzen keine zusätzlichen
  Transformationen. `locked` und `hidden` sind Editorzustand; ausgeblendete
  Objekte bleiben Bestandteil des spielbaren Levels.
- `environment` enthält Sonnenrichtung, Lichtstärke, Nebelfarbe und bis zu acht
  rechteckige Bodenflächen. Erde, Gras, Fels und Asphalt steuern Bodenfärbung und
  Gameplay-Metadaten. Wasser und Vegetationsdichte sind ebenfalls Bestandteil des Dokuments.
- Marker haben stabile IDs, Typ, Position, Blickrichtung und Radius. Ihre
  Y-Koordinate ist geländerelativ. Der Spielerstart nutzt die Blickrichtung,
  die Evakuierung den Radius. `mission` wählt Wellen, Datenbergung oder Funksicherung.

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
Mindestens ein Gegnerstart oder Verstärkungspunkt muss innerhalb der Kartengrenzen
14 m Abstand zu einer möglichen Spielerposition erlauben. Ist das auf einer kleinen
Karte unmöglich, muss sie vergrößert oder ein solcher Marker weiter an den Rand
verschoben werden. Die Sicht- und Abstandsregeln für tatsächliche Verstärkungen
gelten weiterhin.

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
