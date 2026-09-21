# Freies Zielen, mehr Gegner und kräftigere Musik

Stand: 16. September 2026.

## Verhalten

- Maus und Trackpad bewegen das Fadenkreuz unabhängig von Kamera und Laufrichtung. Beide Waffen folgen dem anvisierten Punkt.
- WASD bewegt die Figur, ←/→ drehen die Kamera. Bild ↑/↓ (Mac: Fn + ↑/↓) ändern die Blickhöhe. Leertaste zentriert das Fadenkreuz.
- Mit Mausfang werden relative Bewegungen verarbeitet; ohne Mausfang folgt das Fadenkreuz dem Zeiger direkt. Am Bildschirmrand bleibt es stehen, ohne die Kamera zu drehen.
- Die aktuelle Kameraprojektion berücksichtigt Fensterformat, Sprint-Sichtfeld, Bewegung und Stockwerk. Kamera und Waffen werden nach der Bewegung einmal vorbereitet; Schüsse und Darstellung verwenden dieselbe Pose.
- MG, Laser und Rakete starten am geometrischen Ende ihres jeweiligen Waffenlaufs. Der Lauf richtet sich auf das Ziel unter dem Fadenkreuz aus. Kamera- und Mündungsstrahlen verwenden dieselbe Wand-/Gegnergeometrie; nahe Deckung zwischen Spielfigur und Mündung blockiert das Feuer.
- „Unheimlich“: erste Welle nach 8 Sekunden, danach alle 9 Sekunden, bis zu zwei neue Gegner, maximal 8 pro Ebene. „Albtraum“: 5 Sekunden Startfrist, 6 Sekunden Wellenabstand, maximal 12 pro Ebene.
- Wellen bevorzugen erreichbare Gänge in 7–18 bzw. 5–16 Gangfeldern Entfernung. Sind diese belegt, wird die nächste freie Entfernungszone gewählt. Schutzräume, Leitern und bestehende Gegner bleiben von neuen Spawns frei.
- Beide Musikwege werden vor dem vorhandenen Limiter um Faktor 1,5 verstärkt. Lautstärkeeinstellung, Effekte, Stummschaltung, Pause und Überblendung bleiben erhalten.

## Regel-, Geometrie- und Audio-Prüfungen

- `npm test`: **88 Tests bestanden**. Enthält die bisherigen Missions-, Stockwerks-, Asset- und Kampftests sowie neue Maus-, Mündungs-, Deckungs- und Gegnerwellentests.
- Für alle drei Waffen und beide Ausrüstungsplätze stimmen Mündungsmarker und tatsächliches Mesh-Ende überein. Ausrichtung bei naher Deckung, versetztem Ziel, breitem Fenster und oberer Etage geprüft.
- Zwölf 51×51-Szenarien prüfen nahe Wellen bei Komplexität 0 und 100, beiden Schwierigkeitsstufen und drei Welt-Codes. Zusätzlich wird eine belegte Nahzone mit Ausweichen in den nächstgelegenen freien Bereich geprüft.
- Native Electron-Grafikprüfung: **24 Fälle bestanden**, inklusive Mündungsposition vor/nach Rendern, Schussrichtung, Mündungsblitzen pro Ausrüstungsplatz und tatsächlichem Treffer eines seitlich anvisierten Wächters. Keine Laufzeitfehler.
- Die zwei bestehenden Web-Audio-Browserprüfungen sind erfolgreich. Separater Vergleich mit dem bisherigen Graphen: Atmosphäre +3,52 dB RMS, Kampf +2,71 dB nach Limiter; MG-Effekt unverändert. Stumm/Pause: Peak 0; Kampf bei voller Lautstärke: Peak 0,460, kein Clipping.

Grafikbeleg: [Mündung und versetzter Treffer](screenshots/shooter-free-aim.png).

## Browser-Eingaben

Vier Spiel-Browserfälle bestanden: freies Zielen mit echtem Mausfang, Trackpad-Fallback ohne Mausfang, bisheriger MG-/Nachlade-/Pausenablauf sowie Laser-/Journal-/Freischaltungsablauf. Zusätzlich sind die beiden Audiofälle erfolgreich.

Die neuen Eingabetests verwenden den vollständigen Chromium-Kanal. Die lokale macOS-Version von Chromium Headless Shell lehnt Mausfang selbst in einem minimalen Dokument ab; vollständiges Chromium erlaubt ihn. Der Fallback wird getrennt durch eine nicht verfügbare `requestPointerLock`-API geprüft. Mausbewegungen, Tasten und Schaltflächen werden über echte Browsereingaben bedient. Die sichtbare Karte belegt, dass Mausbewegungen die Blickrichtung nicht verändern und Pfeiltasten bei festem Fadenkreuz die Kamera drehen.

## Aktualisierte macOS-App

Das Paket `release/mac-arm64/NACHTGANG.app` wurde mit dem aktuellen Vite-Build und der bereits lokal installierten Electron-Laufzeit neu erzeugt. `codesign --verify --deep --strict` ist erfolgreich.

Das fertige Paket wurde bei 1280×800 mit hohen Grafikdetails über reguläre Maus-/Tastatureingaben geprüft:

- Freies Fadenkreuz ohne Kameradrehung, Tastaturdrehung ohne Retikelverschiebung.
- W führt trotz seitlichem Ziel weiterhin zur ersten Leiter; Aufstieg auf Ebene 2 funktioniert. Während des Kletterns wird kein Schuss abgegeben.
- MG und Rakete funktionieren auf der oberen Etage, Laser nach regulärem Ausrüstungswechsel in einer neuen Expedition.
- Nachladen hält während Pause an und wird anschließend beendet.
- Keine Laufzeitfehler.

Paketbilder: [Maschinengewehr auf Ebene 2](screenshots/free-aim-machinegun.png), [Laser mit freiem Ziel](screenshots/free-aim-laser.png).

Native Windows-Ausführung wurde auf diesem macOS-Entwicklungsrechner nicht geprüft.
