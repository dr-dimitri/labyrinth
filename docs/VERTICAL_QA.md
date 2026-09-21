# Größere Welten, Klettern und Sci-Fi-Horror-Musik

Stand: 15. September 2026.

## Spiel und Oberfläche

- 9×9 bis 51×51 Felder pro Ebene, 1–3 Stockwerke. Neue Voreinstellung: 25×25 auf drei Ebenen.
- Zwei Leiterverbindungen zwischen jedem benachbarten Etagenpaar; sechs Meter Höhenabstand.
- E richtet die Spielfigur sanft aus und startet einen dreisekündigen Auf-/Abstieg. Währenddessen ist Schießen gesperrt; Pause hält auch das Klettern an.
- Drei Siegel bzw. Mechanismen liegen verteilt auf den Stockwerken. Der Forscher wird oben gefunden und klettert gemeinsam zurück. Der Ausgang liegt im Erdgeschoss.
- Etagenkarte, Auf-/Abstiegssymbole und Missionsliste mit Ebenenangaben. Fortschritt je Stockwerk bleibt erhalten.
- Neue eigenständige Erkundungsmusik: tiefe schwebende Drones, metallische Teiltonresonanzen, lange Hallräume und seltene Impulse. Keine Filmaufnahmen oder übernommenen Melodien. Die vorhandene Kampfmusik bleibt erhalten.

## Prüfungen

- `npm test`: **69 Tests bestanden**.
- Drei mehrstöckige Missionen werden in Tests über echte Laufwege, Kollisionen und Leiterinteraktionen abgeschlossen; der Forscher kehrt mit ins Erdgeschoss zurück.
- Tests für Geschoss-/Etagenisolation, absolute Schusshöhen, erhaltene Erkundung, sichere Wandänderungen und freie Leiteröffnungen.
- **Sechs Browserfälle bestanden:** fünf im Gesamtlauf; der Vertikaltest anschließend gezielt bei 960×720 statt 1280×800, um die langsame Softwaregrafik innerhalb des unveränderten 180-Sekunden-Limits zu prüfen. Alle Funktionsprüfungen blieben erhalten.
- Der Vertikaltest bedient ausschließlich öffentliche Schaltflächen und Tastatur: Klettern, Feuerblockade, Pause, Kartenwechsel, Rückweg und Speicherung.
- Zwei Audiofälle rendern den tatsächlichen Web-Audio-Graphen: unterschiedliche Erkundungs-/Kampfschichten, hörbare räumliche Klanggesten, kein Clipping und keine hängenbleibenden Einmalquellen.
- Native Grafikprüfung: alle drei Biome bei 51×51×3, 64 freie vertikale Kamerapfade und vollständige Schachtvolumen einschließlich einer zuvor überlappenden Bibliothek.
- Acht wiederholte Etagenwechsel zeigen konstante Grafikressourcen je Ebene. Aktive Etage plus nahe Anschlussräume werden gezeichnet; Grafikquellen werden nicht neu geladen.

Screenshots: `screenshots/vertical-ladder-ground.png`, `vertical-ladder-climbing.png`, `vertical-ladder-upper.png` sowie die abschließenden Paketbilder `vertical-menu.png`, `vertical-climbing.png`, `vertical-upper-floor.png`.

## Fertiges macOS-Paket

Das neu gebaute `release/mac-arm64/NACHTGANG.app` wurde separat gestartet und über die reguläre Oberfläche geprüft:

- 51×51 Felder auf drei Ebenen, hohe Grafikdetails, 1280×800 Fenster.
- Sichtbarer Aufstieg zu Ebene2 und Abstieg ins Erdgeschoss, jeweils richtige Etagenkarte.
- Kein Schuss während des Kletterns; oben funktioniert das MG bei korrektem Munitionsverbrauch (30/180 → 29/179).
- Expeditionsbuch listet die drei Siegel auf Ebene1,2 und3.
- **50,1 FPS** über150Frames im nativen Test auf diesem Entwicklungsrechner; keine Laufzeitfehler.
- Lokale Ad-hoc-Signatur mit `codesign --verify --deep --strict` erfolgreich geprüft.

Windows wurde in dieser Änderung nicht nativ getestet; die bestehende Plattform-/Paketkonfiguration bleibt erhalten.
