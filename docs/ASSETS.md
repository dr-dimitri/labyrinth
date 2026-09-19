# Grafikressourcen und Lizenzen

Der NACHTGANG-Quellcode steht unter [MIT](../LICENSE). Die unten aufgeführten Bild- und Modelldateien unter `public/assets/` stammen von Dritten und werden unter **[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)** mitgeliefert. Ihre Lizenz wird durch die MIT-Lizenz des Spiels nicht ersetzt. Die Namensnennung dokumentiert die Herkunft.

## Quellen

| Verwendung | Original und Quelle | Urheber | Enthaltene Daten |
| --- | --- | --- | --- |
| Wände und Mauerwerk | [Medieval Wall 02](https://polyhaven.com/a/medieval_wall_02) · Poly Haven | Rob Tuytel | Fünf 2K-Texturen; fotografierter Bereich 3,5 × 3,5 m |
| Steinboden | [Monastery Stone Floor](https://polyhaven.com/a/monastery_stone_floor) · Poly Haven | Amal Kumar | Fünf 2K-Texturen; fotografierter Bereich 1,8 × 1,8 m |
| Umgebungslicht und Reflexionen | [Moonlit Golf](https://polyhaven.com/a/moonlit_golf) · Poly Haven | Greg Zaal | Radiance HDR, 1024 × 512 Pixel |
| Gotische Statue | [Gothic Statue](https://polyhaven.com/a/gothic_statue) · Poly Haven | Benny Weimer | 27.739 Dreiecke, drei 2K-Texturen |
| Felsstücke | [Rock 07](https://polyhaven.com/a/rock_07) · Poly Haven | Jenelle van Heerden | 14.844 Dreiecke, drei 2K-Texturen |
| Waldboden | [Forest Ground 03](https://polyhaven.com/a/forrest_ground_03) · Poly Haven | Rob Tuytel | Fünf 2K-Texturen; 2 × 2 m |
| Baumrinde | [Bark Brown 01](https://polyhaven.com/a/bark_brown_01) · Poly Haven | Rob Tuytel | Fünf 2K-Texturen; 1 × 1 m |
| Natürliche Felswände | [Rock Face](https://polyhaven.com/a/rock_face) · Poly Haven | Greg Zaal (Fotografie), Dario Barresi (Aufbereitung) | Fünf 2K-Texturen; 2,38 × 2,38 m |
| Höhlenerde | [Brown Mud 03](https://polyhaven.com/a/brown_mud_03) · Poly Haven | Rob Tuytel | Fünf 2K-Texturen; 1,3 × 1,3 m |
| Farne und Blattwerk | [Fern 02](https://polyhaven.com/a/fern_02) · Poly Haven | Rob Tuytel (Scan), Rico Cilliers (Modellierung) | Vier Varianten mit 2.384 / 2.248 / 784 / 816 Dreiecken; drei 1K-Texturen und separate Alphamaske |
| Rotaugenwolf | [3d wolf](https://opengameart.org/content/3d-wolf) · OpenGameArt | NewDLC | Original-FBX mit Skelett; Farb-, Normalen-, Rauheits- und Glanztextur |
| Steinwächter | [Pok](https://opengameart.org/content/pok) · OpenGameArt | Teh_Bucket; Steintexturen: João Paulo / [3dtextures.me](https://3dtextures.me/) | 31.998 Dreiecke, 29 Skelettknochen, zehn 1K-Texturen |

Lizenznachweise: [Poly Haven](https://polyhaven.com/license), [Pok](https://opengameart.org/content/pok), [3dtextures.me](https://3dtextures.me/about/). Das Pok-Original nennt ausdrücklich die mitgelieferten CC0-Texturen von João Paulo.

## Aufbereitung

Wand und Boden verwenden jeweils Farbe, OpenGL-Normalen, Rauheit, Umgebungsverdeckung und Höhe mit 2048 × 2048 Pixeln. Farbe wird als sRGB gelesen, die übrigen Karten als lineare Daten. Die heruntergeladenen Bilder und die HDR-Datei wurden unverändert übernommen. Physische Texturgrößen bestimmen die Wiederholung im Spiel; das Bodenmaterial nutzt die Höhenkarte für geringfügige Unebenheiten.

Statue und Fels wurden aus glTF in eigenständige GLB-Dateien mit eingebetteten Originalbildern verpackt. Die Geometrie blieb erhalten; der Ursprung liegt jetzt mittig am Boden, mit Y als Hochachse und Metern als Einheit. Die vorhandene Verdeckungskarte wurde zusätzlich mit dem Material verbunden. Die Statue misst 1,477 × 1,740 × 1,564 m, der Fels 0,169 × 0,144 × 0,320 m vor Platzierungsskalierung. Beim Fels weist der RealityCapture-Meshname auf Photogrammetrie hin. Für die Statue ist kein Scanverfahren ausdrücklich dokumentiert.

Pok wurde von FBX nach GLB konvertiert. Unbenutzte Mundform-Morphs wurden entfernt; die vollständige Geometrie und das Original-Skelett bleiben erhalten. Die Bilddateien wurden unverändert kopiert und umbenannt. Materialien, Grundhaltung, Skalierung und der bewegungsabhängige Gang werden im Spiel eingerichtet. Die Gehbewegung ist eine eigene prozedurale Skelettanimation; das Paket enthält keine heruntergeladenen Bewegungsclips.

Die vier Waldmaterialien verwenden ebenfalls Farbe, OpenGL-Normalen, Rauheit, Verdeckung und Höhe in 2K. Die Originalbilder sind unverändert. Fern 02 wurde einschließlich seiner vier Original-Meshes und drei 1K-Bilder in eine lokale GLB-Datei verpackt. Die separate Original-Alphamaske schneidet die Blattsilhouetten aus. Im Wald werden die beiden kleineren Mesh-Varianten mehrfach gezeichnet; ihr gemeinsames Material spart Speicher.

Das Wolfsmodell von NewDLC wird mit seinem Original-Skelett und seinen unveränderten Texturdateien geladen. Ein eigener Shader entsättigt das Fell. Rote Augen und verlängerte Fangzähne folgen als zusätzliche Geometrie dem Kopf beziehungsweise Kiefer. Die Laufbewegung wird aus der tatsächlich zurückgelegten Strecke berechnet; sie verwendet keinen heruntergeladenen Animationsclip. Der Ursprung wird auf die Pfoten gesetzt, die Zentimeter werden in Meter umgerechnet.

Orks und Elfen sind im Projekt modelliert und animiert. Ihre Haut- und Stoffoberflächen werden prozedural erzeugt. Diese eigenen Modelle stehen wie der übrige Projektcode unter MIT. Keines der Charaktermodelle wird als photogrammetrischer Scan ausgewiesen.

Die Ressourcen der Browser-/Electron-Ausgabe unter `public/assets` liegen lokal bei, insgesamt rund **105 MB**. Beim ersten Start werden sie geladen und dekodiert. Dafür ist keine Verbindung zu den Quellen nötig; weitere Labyrinthe verwenden die bereits geladenen Daten.

## Hochauflösende native Landschaft

Die native Blacksite-App besitzt eine eigene Ressourcenbibliothek unter `native/Assets`. Sie verwendet unveränderte Originalbilder von Poly Haven, keine hochskalierten Kopien der früheren Bilder. Sechs Materialgruppen enthalten 4096²-Farbkarten, 2048²-OpenGL-Normalenkarten und 1024²-Rauheitskarten: Brown Mud 03, Concrete Floor Worn 02, Rock Face, Bark Brown 01, Forest Ground 03 und Asphalt 01. Die Kacheln verwenden die dokumentierten realen Größen der fotografierten Oberflächen.

Die Kiefern verwenden die originalen fotografischen Twig-Karten aus [Pine Tree 01](https://polyhaven.com/a/pine_tree_01), von Rico Cilliers und Rob Tuytel: Farbe und Alphamaske in 4096² sowie Normalen und Rauheit in 2048². Stämme, Äste und Kronenanordnung sind eigene Geometrie des Spiels; das vollständige Poly-Haven-Baummodell wird nicht mitgeliefert. Der Atlas wird über einen passenden Polygonbereich angesprochen, damit benachbarte Atlasflächen nicht als undurchsichtige Rechtecke erscheinen.

Der fotografische Hintergrund stammt aus [Kloppenheim 06 (Pure Sky)](https://polyhaven.com/a/kloppenheim_06_puresky) von Greg Zaal und Jarod Guest. Mitgeliefert wird das unveränderte tonemapped JPEG mit 8192 × 4096 Pixeln. Dies ist ein Hintergrundbild; es wird nicht als vollständige HDR-Umgebungsbeleuchtung ausgewiesen.

Alle 23 nativen Landschaftsbilder stehen unter [CC0](https://polyhaven.com/license) und belegen zusammen rund 125 MB. Die Original-URLs, Autoren, Maße und SHA256-Prüfsummen stehen in den [Materialquellen](../native/Assets/texture-sources.json), [Kiefernquellen](native-foliage-sources.json) und [Himmelsquellen](native-sky-sources.json). `native/scripts/fetch-assets.py --verify` prüft diese Dateien offline; ohne `--verify` stellt es fehlende Dateien anhand der festgehaltenen Prüfsummen wieder her. Die verwendeten API-Metadaten stammen von Poly Haven — Powered by Poly Haven.

## Native Waffen- und Stoffmaterialien

Die Waffen und die Stoffteile der Egoansicht verwenden [Blue Metal Plate](https://polyhaven.com/a/blue_metal_plate) und [Denim Fabric](https://polyhaven.com/a/denim_fabric) von Rob Tuytel / Poly Haven unter [CC0](https://polyhaven.com/license). Unter `native/Assets/textures/weapon-metal` und `weapon-fabric` liegen jeweils eine originale 2048²-Farbkarte sowie originale 1024²-OpenGL-Normalen- und Rauheitskarten. Die sechs JPEGs werden unverändert übernommen und belegen zusammen rund 7,08 MB. Farbe wird als sRGB gelesen, Normalen und Rauheit als lineare Daten; die Normalenkarten verwenden die OpenGL-Konvention (+Y).

Das separate [Quellenmanifest](native-weapon-material-sources.json) dokumentiert die offiziellen Downloadadressen, Autoren, Maße, Quell-MD5 und SHA-256 jeder Datei. `native/scripts/fetch-assets.py --verify` prüft alle 29 fotografischen Landschafts-, Himmels-, Laub- und Waffenbilder offline auf Dateigröße, Pixelmaße und Prüfsummen. Ohne Option stellt das Skript die festgehaltenen Originale wieder her; `--refresh` aktualisiert nur die sechs Landschaftsmaterialgruppen, die übrigen Quellen bleiben festgeschrieben. Der App-Build führt die Offline-Prüfung vor dem Kompilieren aus und benötigt dafür Python 3. Er übernimmt das Quellenmanifest und die Material-Credits ins App-Paket.

Die beiden neuen CC0-Materialien ändern weder die SWAT-Texturen noch die gesonderten Lizenzbedingungen des folgenden Charaktermodells.

## Nativer Soldat: SWAT / Mixamo

Die native App verwendet einen texturierten SWAT-Charakter mit menschlichem Gesicht und moderner taktischer Uniform. Die unveränderte [GLB-Datei](https://www.shanebrumback.com/models/glb/swat/swat-character.glb) stammt aus Shane Brumbacks [Tutorial](https://www.shanebrumback.com/tutorials/3d-model-animation-xbox-controller-viewer.html) und [veröffentlichtem Beispielcode](https://gist.github.com/ShaneBrumback/9b0e864813d0ec3f13aa664b397a5dd5). Sie liegt als `native/Assets/characters/soldier/soldier.glb` vor und enthält sieben Clips: Idle, Jump, Walking-Shooting, Walking, Bored, Punching und Running. Nach Wiederherstellung der beim Export verlorenen Kopf-Materialgruppen werden drei Primitive mit zusammen 19.450 Dreiecken und zwei Skeletten mit 7 beziehungsweise 51 Gelenken verwendet. Das Modell ist eine erstellte Spielfigur, kein als fotografischer Scan ausgewiesenes Modell.

Der GLB-Exporter wiederholt den gesamten Kopf-Geometriestrom für zwei Materialien, statt deren ursprüngliche Polygonbereiche zu erhalten. [head-materials.json](../native/Assets/characters/soldier/head-materials.json) stellt diese Bereiche aus dem originalen FBX wieder her: 1.820 Dreiecke verwenden das Ausrüstungsmaterial für Helm und Zubehör, 6.436 das Gesichtsmaterial. Die Zuordnung folgt den originalen `ByPolygon`-Materialindizes. Jede GLB-Dreiecksfläche wird über ihre drei Positions-/UV-Ecken einem eindeutigen FBX-Polygon zugeordnet; sämtliche 4.338 Quellpolygone sind mit genau `n−2` Dreiecken abgedeckt. Es werden keine Farb- oder Formheuristiken verwendet. Kleine Exporterrundungen werden mit dokumentierter numerischer Genauigkeit berücksichtigt.

Das [Wiederherstellungsskript](../native/scripts/restore-soldier-materials.py) arbeitet ohne Netzwerkzugriff und verlangt die Original-FBX-Datei ausdrücklich: `native/scripts/restore-soldier-materials.py --fbx /pfad/swat@T-Pose.fbx`. `--check` prüft die vorhandene Zuordnung ohne Änderung. Das Skript prüft beide Quelldateien anhand ihrer SHA-256-Prüfsummen; die FBX-Downloadadresse steht in `SOURCE.json`. Die FBX-Datei wird nicht mit der App ausgeliefert.

Die Zuordnung zu Mixamo ist eine belegte Schlussfolgerung: Die GLB-Datei und ihre Downloadseite enthalten selbst keine ausdrückliche Modelllizenz. Das [Projekt von Bapon Kar](https://github.com/baponkar/Third-Person-Shooter-With-Shooter-AI#readme) nennt Mixamo ausdrücklich als Quelle seines SWAT-Charakters. Dessen originale Gesichts- und Uniformtexturen stimmen im visuellen Vergleich mit den UV-Inseln und Motiven der verkleinerten, vertikal gespiegelten GLB-Texturen überein. Die Mixamo-Gelenknamen stützen diesen Abgleich; sie werden allein nicht als Herkunftsnachweis behandelt.

**Dieses Fremdmodell einschließlich seiner eingebetteten Bilder und Animationen steht weder unter MIT noch unter CC0.** Nach [Adobes Mixamo-FAQ](https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html) ist seine Verwendung in persönlichen, kommerziellen und gemeinnützigen Videospielen royalty-free. Es wird hier als integrierter Charakter des spielbaren Blacksite-Spiels verwendet. Die [Mixamo-Regeln zur Weitergabe](https://community.adobe.com/questions-696/mixamo-faq-licensing-royalties-ownership-eula-and-tos-589400) erlauben keine Verteilung der Rohcharaktere oder Animationen als eigenständige Assets, Assetpakete, Vorlagen oder Stock-Inhalte. Die MIT-Lizenz des Spielcodes ersetzt diese Bedingungen nicht.

[SOURCE.json](../native/Assets/characters/soldier/SOURCE.json) dokumentiert Downloadquellen, Dateigrößen, SHA-256, Herkunftsbelege, Materialdaten und Lizenzlinks; [CREDITS.txt](../native/Assets/characters/soldier/CREDITS.txt) enthält den mitgelieferten Lizenzhinweis. Der Build prüft die Prüfsummen des Originalmodells, aller vier Texturen und der wiederhergestellten Materialzuordnung und übernimmt diese Ressourcen gemeinsam ins App-Paket; der Hinweis erscheint zusätzlich in `ASSET-CREDITS.txt`.

Die Laufzeit verwendet vier unveränderte originale PNG-Dateien mit jeweils **2048×2048** Pixeln aus dem genannten SWAT-Projekt: [Körperfarbe](../native/Assets/characters/soldier/body-color.png), [Körpernormalen](../native/Assets/characters/soldier/body-normal.png), [Kopffarbe](../native/Assets/characters/soldier/head-color.png) und [Kopfnormalen](../native/Assets/characters/soldier/head-normal.png). Die Originale werden passend zu den GLB-UVs mit `MTKTextureLoader.Origin.bottomLeft` geladen. Die eingebetteten reduzierten Bilder besitzen die entgegengesetzte vertikale Orientierung. Die externen Bilder verändern die Original-GLB-Datei nicht; es findet keine Hochskalierung oder generative Bearbeitung statt.

## Nachprüfbarkeit

Die folgenden Dateien enthalten genaue Download-URLs, Dateigrößen, SHA-256-Prüfsummen und Bearbeitungsschritte:

- [Texturen und HDR](texture-sources.json)
- [Statue und Fels](model-environment-sources.json)
- [Steinwächter und seine Texturen](model-creature-sources.json)
- [Waldmaterialien und gescannte Farne](forest-asset-sources.json)
- [Wolfsmodell und Originaltexturen](model-forest-creature-sources.json)
- [Native Waffen- und Stoffmaterialien](native-weapon-material-sources.json)
- [Nativer SWAT-Soldat, Originaltexturen und Animationen](../native/Assets/characters/soldier/SOURCE.json)

`npm test` prüft unter anderem diese Prüfsummen, Bildabmessungen, GLB-Datenbereiche, Materialkarten und die Skelettgewichte des Steinwächters.
