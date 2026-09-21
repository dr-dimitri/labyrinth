# Expeditions- und Shooter-Ausbau: Prüfung

Stand: 15. September 2026.

## Automatisierte Prüfungen

- `npm test`: **57 bestanden**. Generator/Erreichbarkeit, alle Missionen, Reparaturabbruch, Runenrätsel, Rauminteraktionen, Fallenwarnungen, Gegnerverhalten und Sichtlinien, Schleichen, Waffenmunition/Hitze/Nachladen, Explosionsdeckung, sichere Wandänderungen, Fortschritt und Fotoassets.
- `npm run test:e2e`: drei erweiterte Spielabläufe erfolgreich; der zusätzliche Audiotest wurde anschließend einzeln erfolgreich ausgeführt. Zusammen **vier Browserprüfungen**.
- Browserabläufe: MG-Dauerfeuer und Nachladen, Raketenverbrauch, Laserhitze, Rettungsauftrag, Karte/Licht, Pause und Wiederaufnahme, Buchpause, gespeicherte Einstellungen/Freischaltungen/Feldnotizen, wiederherstellbarer Startfehler bei fehlenden Grafikressourcen.
- Audioprüfung: tatsächlicher Web-Audio-Graph mit OfflineAudioContext. Erkundungs- und Kampfschicht ergeben endliche, unterschiedliche Signale ohne Clipping; kurzlebige Audioquellen werden freigegeben.

## Native macOS-Prüfung

`npm run dist -- --dir --publish never` erstellt `release/mac-arm64/NACHTGANG.app`.

- Paket unter macOS auf Apple Silicon erfolgreich gestartet, alle Ressourcen lokal geladen.
- 35×35-Labyrinth, hohe Grafikdetails, 1280×800 Fenster: **52,1 FPS** über 150 Frames auf diesem Entwicklungsrechner. Das ist eine Stichprobe, kein allgemeines Leistungsversprechen.
- MG-Magazin 30 → 23, Gesamtmunition 180 → 173, nach T wieder 30 im Magazin bei unveränderter Gesamtmunition173.
- Expeditionsbuch hält die Spielzeit an; Rückkehr und Hauptmenü funktionieren.
- Keine JavaScript- oder Browser-Konsolenfehler im nativen Ablauf.
- `codesign --verify --deep --strict` erfolgreich. Lokale Ad-hoc-Signatur; kein notarisiertes Distributionspaket.
- Native Sichtprüfung der drei Biome, vier Räume, Gegner, Begleitfigur, Waffen und Effekte ohne Laufzeitfehler.
- Menükarte bei 1280×800 vollständig sichtbar; Unterkante ca.732px.

Screenshots: `screenshots/expedition-menu.png`, `expedition-loadout.png`, `expedition-game.png`.

Windows-Paketkonfiguration und CI bleiben vorhanden. Ein nativer Windows-Test wurde auf diesem Mac nicht durchgeführt. Schwierigkeit und Langzeitbalance benötigen weitere Spieltests.
