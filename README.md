# NACHTGANG — BLACKSITE

Ein spielbarer 3D-Actionshooter für macOS, Windows und den Desktop-Browser. Der neue Standardmodus **Operation Blacksite** führt dich in einen verlassenen Außenposten: Überstehe drei Angriffswellen und halte anschließend den grünen Evakuierungsring am Nordtor drei Sekunden.

## Native macOS-App

**Blacksite gibt es als native Swift-/AppKit-Anwendung mit Metal-Grafik.** Sie läuft offline und benötigt weder Node.js noch Electron. Voraussetzungen zum Bauen: macOS 13 oder neuer und Xcode Command Line Tools mit Swift 5.10 oder neuer.

Die native Landschaft nutzt fotografische 4K-Materialien für Boden, Felsen, Baumrinde, Beton und Asphalt sowie einen fotografischen 8K-Himmel. Detaillierte Astkronen mit Nadeltexturen ersetzen die ursprünglichen kleinen Baumgrafiken. „Hoch“ ist die Voreinstellung für neue Installationen; „Ausgewogen“ bleibt für geringere Grafiklast verfügbar.

Begehbare Hügel und Mulden verwenden dieselbe Oberfläche für Grafik, Bewegung und Beschuss und bieten zusätzliche Deckung. Gegner tragen sichtbare Gewehre; ihre Soldatenmodelle zeigen Laufen, Rennen, Ducken, Springen und Zielen.

```sh
./native/scripts/run.sh       # Optimierte App bauen und starten
./native/scripts/test.sh      # Vollständiges natives Paket und Spielregeln prüfen
```

Die fertige App liegt unter `release/Blacksite.app` und kann direkt im Finder geöffnet werden. Mit `./native/scripts/build-app.sh` lässt sie sich ohne anschließenden Start bauen. Sie enthält die benötigten Ressourcen und kann unabhängig vom Projektordner verwendet werden. Der Build erzeugt die Architektur des jeweiligen Macs und ist lokal Ad-hoc-signiert; er ist nicht notarisiert.

[Native Bauanleitung, Grafikprüfung und Steuerung](docs/NATIVE_MACOS.md). Die folgenden Browser-/Electron-Anleitungen bleiben für die anderen Ausgaben verfügbar.

## Operation Blacksite

- **Klassische Ego-Steuerung:** Mausblick, Laufen, Sprinten, Springen und Hinlegen mit passender Kamerahöhe. Ausdauer begrenzt Sprinten und Sprünge.
- **Gegner-KI:** Bewaffnete Gegner verfolgen sichtbare Ziele, umgehen Hindernisse, bewegen sich seitlich und suchen bei Verletzungen Deckung. Ein kurzer orangefarbener Hinweis kündigt gegnerisches Feuer an. Ohne Sichtkontakt suchen sie nur an deiner letzten bekannten Position; Schüsse verraten deinen Standort in Hörweite.
- **Verstecken und Klettern:** Container, Kisten und Betonbarrieren blockieren Sicht und Beschuss. Niedrige Deckung schützt beim Hinlegen. Schaue direkt auf eine Kante und drücke **E**, wenn „Hochklettern“ erscheint. Containerdächer sind tatsächlich begehbar; du kannst von dort schießen oder herunterspringen.
- **Zerstörbare Umgebung:** Kisten, Barrieren und Container halten unterschiedlich viel Schaden aus. Zerstörte Deckung verschwindet mit Trümmern und öffnet neue Lauf- und Schusswege. Brennstofffässer können Kettenexplosionen auslösen. Die massiven Gebäude und die Geländegrenze bleiben bestehen.
- **Zwei Waffen:** Das AR-4 bietet automatisches Feuer und ein Magazin mit 30 Schuss. Die M82 besitzt fünf Schuss, erhöhte Durchschlagswirkung gegen Deckungsobjekte und ein **echtes 6×-Zielfernrohr** mit Kamerazoom, Sichtblende und Absehen. Geschosse durchdringen keine intakte Deckung. Kopftreffer verursachen zusätzlichen Schaden.
- **Handgranaten:** Vier Granaten zu Beginn; **2,8 Sekunden Zündverzögerung**, Schwerkraft, Abprallen und acht Meter Explosionsradius. Intakte Deckung schützt vor der Druckwelle. Eigene Granaten und Fässer verursachen auch Eigenschaden. Eine Anzeige warnt vor Granaten in der Nähe.
- **Gesundheit:** Ein roter Balken zeigt die Hitpoints, rote Bildschirmränder signalisieren Schaden. Nach 5,5 Sekunden ohne Treffer regeneriert sich die Gesundheit. Zwischen den Wellen gibt es Munition, Granaten und etwas Heilung; besiegte Gegner hinterlassen gelegentlich Munition.
- **Grafik und Sound:** Lokale fotografische PBR-Materialien, dynamische Schatten, atmosphärischer Himmel, Nebel, Staub, Mündungsfeuer, Leuchtspuren, Explosionen und eigene animierte Soldaten- und Waffenmodelle. „Hoch“ ergänzt Kontaktschatten und höhere Auflösung. Die vorhandene adaptive Industrial-Musik und synthetische Waffenklänge laufen vollständig offline.

| Taste / Aktion | Funktion in Blacksite |
| --- | --- |
| `W A S D` | Bewegen |
| Maus | Umsehen |
| `Shift` | Sprinten |
| Leertaste | Springen; im Liegen zunächst aufstehen |
| `C` / `Strg` | Hinlegen / aufstehen |
| Linke Maustaste / `Q` | Schießen |
| Rechte Maustaste / `Z` halten | Zielen / Zielfernrohr |
| `1` / `2` / Mausrad | Waffen wechseln |
| `R` | Nachladen |
| `G` | Granate werfen |
| `E` | Auf eine nahe Kante klettern |
| `Esc` | Pause / fortsetzen |

Falls ein eingebetteter Browser den Mausfang ablehnt, funktionieren Ziehen mit gedrückter Maustaste sowie die Pfeiltasten und Bild ↑ / ↓ als Blicksteuerung. Für die klassische FPS-Steuerung empfiehlt sich das Desktop-Fenster oder ein Browser mit Mausfang.

Der Shooter startet standardmäßig unter `/` und im Desktop-Fenster. Die bisherige Labyrinth-Expedition bleibt im Browser unter `/expedition.html` erhalten; ihre Dokumentation folgt unten. Beide Modi teilen Grafikressourcen und Audio, verwenden aber getrennte Spieleinstellungen und Simulationen.

## Starten

Voraussetzungen: **Node.js 22.12 oder neuer**, npm, eine Grafikkarte mit **WebGL 2**, aktivierte Hardwarebeschleunigung sowie Tastatur und Maus oder Trackpad. Die Installation benötigt Internetzugang. Das fertige Desktop-Spiel läuft offline.

```sh
npm ci
npm run dev
```

Öffne die im Terminal angezeigte lokale Adresse. Für ein eigenes Desktop-Fenster:

```sh
npm run desktop
```

| Befehl | Zweck |
| --- | --- |
| `npm ci` | Abhängigkeiten aus der Lockdatei installieren |
| `npm run dev` | Browser-Entwicklung mit automatischer Aktualisierung |
| `npm run desktop` | Spiel erstellen und mit Electron öffnen |
| `npm test` | Labyrinthgenerator, Spielregeln und Grafikressourcen prüfen |
| `npm run test:e2e` | Bedienung im Chromium-Browser prüfen |
| `npm run build` | Browser-Dateien unter `dist/` erstellen |
| `npm run dist` | Desktop-Pakete für das aktuelle System unter `release/` erstellen |

Details zu Installern, Zielarchitekturen, Vollbild und Signierung stehen in [Desktop-Builds](docs/DESKTOP.md). macOS-Pakete werden auf macOS gebaut, Windows-Pakete auf Windows.

Für die Browser-Tests einmalig `npx playwright install chromium` ausführen. `npm run test:e2e` startet einen eigenen Produktionsserver und prüft Einstellungen, Waffenfeuer, Nachladen, Karte, Licht, Missionen, Freischaltungen, Pause und Wiederaufnahme.

## Bisheriger Modus: Deine Expedition

Die Planung hat drei Reiter: **Welt**, **Auftrag** und **Ausrüstung**.

- **Vier Welten:** Katakomben mit Bodenfallen, offene überwucherte Ruinen, eine verlassene Mine und der neue **Dunkelwald**. Katakomben und Dunkelwald sind sofort offen; eine erfolgreiche Expedition erschließt die Ruinen. Die Mine öffnet nach 3 Erfolgen oder 8 geborgenen Fundstücken.
- **Größe:** 9 × 9 bis 51 × 51 Rasterfelder pro Stockwerk. Voreingestellt sind 25 × 25 Felder auf drei Ebenen. Die Stockwerkzahl ist von 1 bis 3 wählbar. Vier besondere Räume pro Ebene öffnen auch bei maximaler Komplexität Rundwege.
- **Klettern:** Leitern verbinden benachbarte Stockwerke in sechs Metern Abstand. Mit E beginnt ein sichtbarer Auf- oder Abstieg. Währenddessen pausiert das Waffenfeuer. Auf jeder Ebene bleiben erkundete Wege, gesammelte Gegenstände und besiegte Gegner erhalten. Der Ausgang liegt immer im Erdgeschoss; Ziele sind über die Ebenen verteilt.
- **Komplexität:** Niedrige Werte bevorzugen gerade Gänge und zusätzliche Verbindungen. Hohe Werte erzeugen mehr Abzweigungen und Sackgassen.
- **Welt-Code:** Gleicher Code, gleiches Biom, gleiche Größe, Stockwerkzahl und Komplexität ergeben dieselbe Welt. Der Zufallsknopf erzeugt einen neuen Code.
- **Bedrohung:** „Erkundung“ deaktiviert Monster und Gefahrenschaden. „Unheimlich“ bietet regelmäßige Verfolger; „Albtraum“ frühere, häufigere und schnellere Begegnungen.

### Der Dunkelwald

Wähle **Neuer Schauplatz → Der Dunkelwald** oder das Biom im Welt-Reiter. Größe, Komplexität, Welt-Code, Bedrohung und alle drei Aufträge gelten auch hier.

- **Wald und Schlucht:** Hohe, verzweigte Bäume, Fackeln an den Stämmen, Farne und Felswände säumen die Wege. Das Gelände fällt über begehbare Hänge bei großen Karten ungefähr 16 Meter in eine geschwungene Schlucht ab. Kleine Karten haben entsprechend weniger Tiefe.
- **Zwei Höhlen:** Die Tropfsteingrotte und die erdige Wurzelhöhle haben jeweils zwei miteinander verbundene Ein- und Ausgänge. Du gehst ohne Ladebildschirm durch sie hindurch. Missionsziele führen in beide Höhlen.
- **Wölfe und Orks:** Schnelle Wölfe mit roten Augen und langen Fangzähnen verfolgen dich; größere, gepanzerte Orks halten mehr Treffer aus und schlagen härter zu.
- **Freundliche Elfen:** Zwei geschützte Lager bieten eine Atempause. Gehe zur Elfe und drücke **E**, um die Munition beider mitgebrachten Waffen einschließlich des MG-Magazins vollständig aufzufüllen. Nach einem Nachschub braucht sie 45 Sekunden; Pause hält diese Zeit an. Elfen sind keine angreifbaren Gegner.
- **Orientierung:** Das HUD zeigt Region und Tiefe. **M** markiert erkundete Höhlenzugänge und Elfenlager; **J** nennt die Regionen deiner Missionsziele.

Der Wald verwendet ein zusammenhängendes Gelände statt gestapelter Stockwerke. Beim Wechsel zurück zu einem anderen Biom wird die zuvor gewählte Stockwerkzahl wiederhergestellt.

### Mehr räumliche Tiefe

Alle Schauplätze verwenden stärkere räumliche Lichtkontraste, Kontaktschatten und Nebel, dessen Dichte von Entfernung und Höhe abhängt. Im Freien werfen Bäume und Felsen gerichtete Mondschatten. Nahe Fackeln beleuchten auf hoher Grafikstufe ihre Umgebung mit eigenen Schatten. Das Blickfeld beträgt 74 Grad, beim Sprinten weich übergehend 81 Grad; Mausziel und tatsächliche Waffenmündung nutzen weiterhin dieselbe Kameraprojektion.

Katakomben und Ruinen besitzen versetzte Steinlagen mit tiefen Fugen, Gewölberippen und flache plastische Bodenplatten. In der Mine gliedern Felsflächen, Holzrahmen und Diagonalstützen die Gänge. Der Dunkelwald hat Hügel, Bodenwellen, runde Böschungen und gewölbte Höhlen mit massiven Dächern. Die Höhen werden von Darstellung, Bewegung und Waffen gemeinsam verwendet.

Die Grafikstufe **Ausgewogen** behält diese räumlichen Effekte mit geringer aufgelösten Kontaktschatten und Mondschatten. **Hoch** ergänzt den Schatten der nächsten Fackel. Große Waldobjektgruppen werden räumlich aufgeteilt, damit unsichtbare Bereiche nicht vollständig gezeichnet werden müssen. [Prüfung der räumlichen Darstellung](docs/DEPTH_QA.md).

### Drei Aufträge

| Auftrag | Ziel |
| --- | --- |
| Die drei Siegel | Drei Siegel mit E bergen und das Portal erreichen |
| Das Torwerk | Drei Mechanismen jeweils vier Sekunden reparieren; Bewegung oder Schaden unterbricht |
| Die letzte Spur | Den Forscher auf der obersten Ebene beziehungsweise in der Wurzelhöhle finden und zum Ausgang begleiten; bei zu großem Abstand wartet er |

### Waffen und Werkzeuge

Zwei unterschiedliche Gegenstände passen ins Gepäck. Maschinengewehr und Raketenwerfer sind voreingestellt; alle drei Waffen sind sofort verfügbar.

| Ausrüstung | Verhalten |
| --- | --- |
| Maschinengewehr | Dauerfeuer, 30 Schuss pro Magazin, insgesamt 180 Schuss; T lädt in 1,7 Sekunden nach |
| Lasergewehr | 80 Energieschüsse; präzise, mit Überhitzung und automatischer Abkühlung |
| Raketenwerfer | Drei fliegende Raketen mit Flächenschaden und Eigenschaden; massive Wände blockieren Explosionsschaden |
| Locksteine | Geräusche lenken blinde Wächter ab |
| Wegkreide | Dauerhafte Pfeile im Labyrinth und auf der Karte |
| Leuchtfackeln | Vertreiben Schatten für 25 Sekunden; nach der ersten erfolgreichen Expedition verfügbar |
| Spurenkompass | Enthüllt einen Weg zum nächsten Ziel; ab 6 geborgenen Fundstücken verfügbar |

Die Waffen treffen keine Ziele durch Wände. Munition und Werkzeuge werden zu Beginn jeder Expedition erneuert. Normales Laufen erreicht 4,5 m/s, Sprinten 7,2 m/s und Schleichen 2,2 m/s. Gegner verfolgen je nach Art und Schwierigkeit mit etwa 4 bis 5,9 m/s.

### Erkundung und wechselnde Gefahren

- **Zuflucht:** Schutz vor Monstern, Heilung und eine sichere Atempause.
- **Bibliothek:** Ein lösbares Runenrätsel gibt zusätzliche Fundstücke und einen Kartenhinweis.
- **Überflutete Halle:** Wasser bremst; eine Schleuse lässt es dauerhaft ab.
- **Schatzkammer:** Freiwillige Schätze, teilweise mit angekündigter Falle. Nach dem Öffnen zurückweichen.
- **Dynamische Ereignisse:** Acht Sekunden Vorwarnung vor verschobenen Wänden, steigenden Fluten, erlöschenden Wandfackeln oder Grubengas. Verschiebungen erhalten erreichbare Wege und schützen belegte Felder. Die Taschenlampe bleibt bei einem Fackelausfall verfügbar.
- **Gegner:** Der blinde Wächter folgt Geräuschen, der Schatten scheut gerichtetes Licht und Leuchtfackeln, die Wanderstatue erstarrt bei freier Sicht im Blickfeld.

**Mehr Gegner:** In „Unheimlich“ erscheinen nach 8 Sekunden bis zu zwei Gegner pro Welle, danach alle 9 Sekunden; maximal 8 pro Ebene. „Albtraum“ beginnt nach 5 Sekunden, mit Wellen alle 6 Sekunden und maximal 12 Gegnern pro Ebene. Wellen entstehen bevorzugt in erreichbarer Nähe (7–18 Gangfelder in „Unheimlich“, 5–16 in „Albtraum“); erst bei belegten Bereichen weichen sie auf weiter entfernte Gänge aus. Neue Gegner halten Abstand zur Spielfigur, zu Leitern, zu Schutzräumen und zueinander.

**Freies Zielen:** Das Fadenkreuz bleibt unabhängig von der Blickrichtung auf dem Bildschirm beweglich. Beide Waffen richten ihre Mündungen auf das anvisierte Ziel aus. Laser, MG-Leuchtspuren und Raketen starten an ihrer jeweiligen Mündung; nahe Wände blockieren den Schuss auch dann, wenn die Waffenansicht optisch in die Wand ragt.

Ein erfolgreicher Lauf sichert **2 Fundstücke plus die getragenen Schätze**. Bei einer Niederlage gehen getragene Schätze verloren; Feldnotizen bleiben erhalten. Fortschritt und Einstellungen werden lokal gespeichert. Eine laufende Expedition wird beim Beenden nicht gespeichert.

## Steuerung

| Taste / Aktion | Funktion |
| --- | --- |
| `W A S D` | Bewegen |
| Maus / Trackpad | Fadenkreuz frei bewegen; Waffen folgen dem Ziel, die Kamera bleibt fest |
| `Bild ↑ / Bild ↓` (Mac: `Fn + ↑ / ↓`) | Nach oben / unten schauen |
| Leertaste | Fadenkreuz zentrieren |
| `Shift` halten | Sprinten |
| `C` halten | Leise schleichen |
| `Q` / linke Maustaste | Linke Ausrüstung einsetzen; MG und Laser bei Halten wiederholt feuern |
| `R` / rechte Maustaste | Rechte Ausrüstung einsetzen |
| `T` | Maschinengewehr nachladen; bei leerem Magazin auch automatisch |
| `E` | Interagieren, bergen, reparieren, ansprechen oder auf einer Leiter hoch-/hinunterklettern |
| `F` | Taschenlampe ein-/ausschalten |
| `M` | Karte der aktuellen Ebene mit Auf- und Abstiegen öffnen/schließen |
| `J` | Auftrag, Feldnotizen und Freischaltungen lesen |
| `Esc` | Pausieren/fortsetzen und Maus freigeben |
| `↑ ↓` / `← →` | Vor-/zurückgehen bzw. drehen |

Ohne Mausfang folgt das Fadenkreuz dem Mauszeiger im Spielfenster, auch ohne gedrückte Taste. Q/R und beide Maustasten feuern weiterhin. Mit Mausfang regelt die Zielempfindlichkeit die Bewegung des Fadenkreuzes. Im Pausenmenü kannst du Lautstärke, Grafikdetails und Zielempfindlichkeit ändern. Fensterwechsel, Runenrätsel und Expeditionsbuch pausieren das Spiel vollständig.

## Atmosphäre und Entwicklungsstand

Die Szene verwendet fotografische 2K-Materialien für Mauerwerk und Steinboden. Normalen-, Rauheits-, Verdeckungs- und Höhenkarten geben den Oberflächen Details und unterschiedliche Lichtreaktionen. Dazu kommen ein HDR-Umgebungslicht, gotische Statuen, gescannte Felsstücke, gegliederte Architektur und ein detaillierter Steinwächter mit Skelettanimation. Taschenlampenlicht, Schatten, Nebel und Fackeln bestimmen die Sicht in den Gängen.

Die Grafikressourcen liegen vollständig lokal bei; beim ersten Start werden rund 105 MB geladen und dekodiert. Der Dunkelwald ergänzt fotografische 2K-Materialien für Rinde, Laubboden, Fels und Erde sowie gescannte Farne. Herkunft, Autoren und CC0-Lizenzen stehen in [Grafikressourcen](docs/ASSETS.md). Der eigene, synthetisch erzeugte Soundtrack wechselt weich zwischen einer beklemmenden Sci-Fi-Horror-Atmosphäre beim Erkunden und einem treibenden Industrial-Rhythmus bei nahen Gegnern: verzerrte tiefe Riffs, Kick, Snare und Hi-Hats mit 144 BPM. Die Erkundungsmusik nutzt tiefe schwebende Drones, sparsame metallische Resonanzen, lange Hallräume und unregelmäßige Impulse mit viel Stille dazwischen. Sie ist eine eigenständige Komposition mit einer Atmosphäre, die sich an Alien orientiert. Gefahr steuert die Überblendung; in der Zuflucht beruhigt sich die Musik. Beide Musikwege sind um etwa 3,5 dB angehoben; der vorhandene Limiter begrenzt Spitzen. Waffen- und Schrittlautstärke bleiben unverändert. Schritte werden beim Schleichen leiser. Musik und Waffenklänge werden lokal über Web Audio erzeugt und benötigen keine Audiodateien. Es werden keine Film- oder Spielaufnahmen und keine übernommenen Melodien verwendet.

Das Spiel bleibt ein Prototyp. Die Feinabstimmung der Schwierigkeit und umfangreiche Spieltests stehen noch aus. Orks, Elfen, Missionsobjekte und Waffen verwenden eigens konstruierte 3D-Modelle; die Wölfe besitzen ein texturiertes Modell mit Skelett und eigener Laufanimation; Wände, Böden und gescannte Dekorationen behalten die fotografischen Materialien. Pro Stockwerk wird nur die aktive Etage mit benachbarten Leiterpodesten gerendert; dadurch müssen große Welten nicht gleichzeitig alle drei Etagen zeichnen. Die tatsächliche Bildrate hängt von Grafikkarte, Auflösung und Labyrinthgröße ab.

Die Desktop-Hülle und Paketkonfiguration unterstützen macOS und Windows. Native Windows-Ausführung wurde auf diesem Entwicklungsrechner noch nicht geprüft. Der vorbereitete [GitHub-Actions-Workflow](.github/workflows/build.yml) führt Tests und Paketbuilds separat für macOS auf Apple Silicon und Intel sowie Windows x64 aus; ein lokaler Test ersetzt keinen erfolgreichen Lauf auf diesen Zielsystemen.

## Aufbau

| Datei | Verantwortung |
| --- | --- |
| [src/maze.js](src/maze.js) | Reproduzierbare Labyrinthe, Wegsuche und Platzierung |
| [src/forest-world.js](src/forest-world.js) | Reproduzierbares Waldgelände, Schlucht, Höhlen und Lager |
| [src/forest-renderer.js](src/forest-renderer.js) | Wald, Felsen, Höhlendecken und Vegetation |
| [src/forest-creatures.js](src/forest-creatures.js) | Animierte Orks, freundliche Elfen und gemeinsame Modellbausteine |
| [src/forest-wolf.js](src/forest-wolf.js) | Texturiertes Wolfsmodell, Skelettgang und Fangzähne |
| [src/expedition.js](src/expedition.js) | Biome, Missionen, Räume, Schätze und Ausrüstung |
| [src/progression.js](src/progression.js) | Validierter lokaler Fortschritt und Freischaltungen |
| [src/simulation.js](src/simulation.js) | Bewegung, Waffen, Gegner, Interaktionen und Weltveränderungen |
| [src/aim-input.js](src/aim-input.js) | Unabhängiges Fadenkreuz mit Mausfang und direkter Zeigersteuerung |
| [src/weapon-aim.js](src/weapon-aim.js) | Kameraprojektion, Waffenpose und tatsächliche Mündungsposition |
| [src/expedition-visuals.js](src/expedition-visuals.js) | Biome, Räume, Waffenmodelle und Effekte |
| [src/vertical-architecture.js](src/vertical-architecture.js) | Leitern, echte Decken-/Bodenöffnungen und sichtbare Nachbarpodeste |
| [src/world-relief.js](src/world-relief.js) | Physisches Mauerrelief, Bodenplatten, Gewölberippen und Holzrahmen |
| [src/depth-atmosphere.js](src/depth-atmosphere.js) | Höhenabhängiger Nebel und Lichtstreuung anhand der tatsächlichen Szenentiefe |
| [src/renderer.js](src/renderer.js) | Three.js-Szene, Materialien, Beleuchtung und Animation |
| [src/assets.js](src/assets.js) | Gemeinsames Laden der lokalen PBR-Materialien, Modelle und HDR-Beleuchtung |
| [src/architecture.js](src/architecture.js) | Mauerwerk und Architekturdetails des Labyrinths |
| [src/guardian.js](src/guardian.js) | Steinwächter, Materialzuordnung und prozeduraler Skelettgang |
| [src/audio.js](src/audio.js) | Musik und Geräusche über die Web Audio API |
| [src/shooter-simulation.js](src/shooter-simulation.js) | Blacksite: Bewegung, Klettern, KI, Waffen, Granaten, zerstörbare Deckung, Wellen und Evakuierung |
| [src/shooter-renderer.js](src/shooter-renderer.js) | Blacksite: Einsatzgebiet, PBR-Oberflächen, Soldaten, Waffen, Effekte und Grafikstufen |
| [src/shooter-main.js](src/shooter-main.js) | Blacksite: Eingabe, Mausfang, Audioanbindung, Menüs und HUD |
| [src/shooter.css](src/shooter.css), [index.html](index.html) | Blacksite-Oberfläche, roter Gesundheitsbalken und Zielfernrohr |
| [src/main.js](src/main.js) | Expedition: Eingaben, Menüs, Spielzustände und HUD |
| [src/style.css](src/style.css), [expedition.html](expedition.html) | Expedition-Oberfläche und Gestaltung |
| [electron/main.cjs](electron/main.cjs) | Desktop-Fenster und lokale Laufzeit |
| [tests/](tests/) | Tests für Erreichbarkeit, Reproduzierbarkeit, Kollisionen, Monster, Siegbedingungen und Grafikressourcen |

Quellcode: [MIT](LICENSE). Mitgelieferte Grafikressourcen: [CC0, Quellen und Autoren](docs/ASSETS.md).
