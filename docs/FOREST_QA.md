# Dunkelwald – Prüfprotokoll

Stand: 16. September 2026.

## Umfang

- Sofort wählbares viertes Biom, einschließlich Welt-Code, Größe 9–51, Komplexität und allen drei Missionen.
- Zusammenhängendes Gelände mit sanftem Abstieg in eine bis zu 8,5 Meter tiefe Schlucht.
- Zwei unterschiedlich gestaltete Höhlen mit jeweils zwei offenen Zugängen: Gestein mit Tropfsteinen und Erde mit Wurzeln.
- Schnelle Wölfe, robuste Orks und zwei geschützte Elfenlager mit Nachschub für beide mitgebrachten Schusswaffen.
- E füllt Munition und MG-Magazin auf; 45 Sekunden Nachschubzeit nach einer tatsächlichen Auffüllung. Pausieren hält den Timer an.
- Eigene Waldkarte, Regions- und Tiefenanzeige, Missionsziele mit Höhlennamen.
- Fotografische 2K-Materialien und gescannte Farne vollständig lokal. [Quellen und Prüfsummen](forest-asset-sources.json).

## Automatisierte Prüfungen

Die neuen Simulationstests bewegen die Spielfigur mit den regulären Bewegungsregeln. Sie prüfen Hin- und Rückwege, beide Zugänge jeder Höhle, Auf- und Abstieg sowie den Abschluss aller drei Missionen. Erreichbarkeit und Reproduzierbarkeit werden für 9, 25 und 51 Felder, mehrere Welt-Codes und beide Komplexitätsgrenzen geprüft.

Weitere Fälle prüfen Nachschub für unterschiedliche Waffenkombinationen, leere MG-Magazine, abgebrochene Nachladevorgänge, pausierte Abklingzeit, freundliche Elfen, Gegnerwellen, Wolfsgeschwindigkeit und Ork-Trefferpunkte. Schüsse und Raketen können über endliche Baumstämme, Felsen und Höhlendächer hinweg in den Himmel fliegen. Die sichtbaren Baum- und Felstransformationen sind zugleich Grundlage ihrer Kollisionskörper; Blattwerk bleibt durchlässig. Aufwärts- und Abwärtsschüsse treffen Höhlendecke beziehungsweise Boden; das Gelände blockiert Sicht und Geschosse entsprechend seiner Höhe.

Geometrietests gleichen den gezeichneten Boden mit den Spielfigur-Höhen an jedem begehbaren Rastermittelpunkt ab. Sie prüfen Fels-Texturkoordinaten und freie Stehhöhe unter beiden Höhlendecken. Figurenprüfungen erfassen erkennbare Anatomie, Gangbewegungen, rote Augen und Fangzähne, Elfen-Nachschubanimation, korrekte Bodenhöhe und die Lebensdauer gemeinsam verwendeter Texturen.

Zwei neue Browserfälle laufen im vollständigen Chromium gegen den Produktionsbuild. Sie prüfen gespeicherte Waldgröße 51, den Erhalt der vorherigen Dungeon-Stockwerkzahl und den Ablauf mit echter Tastaturbedienung: W/D zum Elfenlager, Q/R zum Feuern, E zum Auffüllen, Pause und Fortsetzen, Karte und Expeditionsbuch. Beide Fälle bestanden ohne JavaScript- oder Konsolenfehler.

## Ergebnis und Desktop-Prüfung

- **116 automatisierte Tests bestanden**, ohne Fehler oder übersprungene Fälle.
- **Zwei neue Browserfälle bestanden**, gegen den Produktionsbuild.
- **macOS-App gebaut und nativ geprüft**, Apple Silicon, 1280 × 800 logische Pixel, Grafikstufe Hoch. Echte Tastaturbewegung zum Elfenlager, MG- und Raketenfeuer, vollständiger Nachschub, pausierte Abklingzeit, Karte und Höhlenziele funktionierten. Anschließend wurden im selben Prozess Katakomben aufgebaut, eine Leiter zur zweiten Ebene benutzt und erneut der Wald gestartet. Keine JavaScript- oder Konsolenfehler.
- `npm run build` erfolgreich; lokale Electron-Paketierung erfolgreich. Die Anwendung ist ad-hoc signiert; keine Notarisierung.
- Native Grafikmessung bei 1280 × 768 logischen Pixeln, Hoch: **46,6 FPS bei 25 × 25**, **39,1 FPS bei 51 × 51 mit acht Wölfen/Orks**. Der Renderer verwendete im großen Wald 111 GPU-Geometrien und 66 Texturen. Diese kurzen Messungen sind keine allgemeine Hardwaregarantie.

Aufnahmen: [Planung](screenshots/forest-planner.png), [Wald](screenshots/forest-gameplay.png), [Nachschub](screenshots/forest-elf-resupply.png), [Felshöhle](screenshots/forest-cave.png), [Wurzelhöhle](screenshots/forest-roots.png), [Schlucht](screenshots/forest-ravine.png).

## Darstellung und Plattformgrenzen

Native Grafikprüfungen verwenden Electron auf macOS mit echten lokalen Materialien. Aufnahmen zeigen Wald, beide Höhlentypen und Figuren; einzelne Grafikaufnahmen stellen die Kamera gezielt an Prüfpositionen. Die Simulationstests prüfen die tatsächliche Begehbarkeit dieser Bereiche getrennt.

Die Wölfe verwenden ein texturiertes, mit Skelett versehenes CC0-Modell von NewDLC mit eigener Laufanimation, roten Augen und zusätzlichen Fangzähnen. Orks und Elfen sind eigene konstruierte Modelle mit prozeduralen Oberflächen. Die Umwelt verwendet fotografische Materialien und gescannte Farne. Die Charaktere sind keine photogrammetrisch erfassten Figuren.

Bildraten gelten nur für diesen Rechner, die geprüfte Ansicht und die jeweilige Auflösung. Native Windows-Ausführung wurde hier nicht geprüft. Die vorhandene Windows-Paketkonfiguration bleibt erhalten.
