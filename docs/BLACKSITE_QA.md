# Blacksite – Umsetzung und Prüfung

Stand: 18. September 2026. Blacksite ist der neue Einstieg unter `/` und im Electron-Fenster. Die bisherige Expedition bleibt als eigener Einstieg unter `/expedition.html` erhalten.

## Spielbare Funktionen

Die Arena enthält drei Wellen mit 5, 7 und 9 bewaffneten Gegnern. Danach wird der Evakuierungsring am Nordtor freigeschaltet. Sieg erfordert drei ununterbrochene Sekunden im Ring. Bei Tod stehen Neustart und Hauptmenü zur Verfügung.

Die Bewegung unterstützt normalisiertes WASD, Sprint mit Ausdauer, Sprung und Schwerkraft, Hinlegen mit niedriger Augenhöhe und zeitlich interpoliertes Klettern auf Kanten bis 3,3 Meter. Containerdächer tragen die Spielfigur; beim Zerstören des Containers fällt sie herunter. Während des Kletterns sind Schüsse und Granaten gesperrt.

Die KI prüft Sichtstrahlen gegen die aktuelle Deckung, folgt über ein Navigationsraster, bewegt sich seitlich im Feuergefecht und sucht nach Verletzungen hohe Deckung. Ohne Sichtkontakt wird nur die letzte sichtbare beziehungsweise hörbare Position verfolgt. Das HUD meldet verdeckte und entdeckte Zustände. Nähe allein vermittelt hinter Hindernissen keinen neuen Standort.

Das AR-4 und die M82 haben getrennte Magazine, Reserven, Feuerraten und Nachladezeiten. Die M82 ändert die Kameraprojektion für einen sechsfachen optischen Zoom. Kopftreffer verursachen mehr Schaden. Augen- und Mündungsstrahl verhindern Schüsse durch nahe Deckung.

Granaten fliegen mit Schwerkraft und Abprallen. Der 2,8-Sekunden-Zünder läuft ausschließlich mit der Simulation. Explosionen prüfen Deckung vor dem Schaden und verursachen auch Eigenschaden. Kisten, Barrieren und Container sind zerstörbar; Fässer lösen Kettenexplosionen aus. Die massiven Gebäude, Türme und die Geländegrenze sind statisch.

## Automatisierte Prüfung

- `npm test`: **139 Tests bestanden**, davon 13 neue Blacksite-Tests. Sie prüfen Bewegung, Diagonalgeschwindigkeit, Frameratenunabhängigkeit, Sprung, Hinlegen, Treffer hinter Deckung, Kopftreffer, Zoom-Zielrichtung, Munition, Nachladen, Granatenzünder, Abprallen an dünnen Wänden, Explosionsdeckung, Zerstörung, Kettenreaktionen, Containerdächer, Verstecken, KI-Schussvorwarnung, Tod, alle drei Wellen, Evakuierung, Heilverzögerung und das Anhalten der Simulationszeit.
- `npm run test:e2e -- tests/e2e/shooter.spec.js`: **2 Browser-Tests bestanden**. Sie bedienen Menüs, Waffen, Nachladen, Hinlegen, Aufstehen, Springen, Zielfernrohr, Granaten, Pause, Wiederaufnahme, Neustart und gespeicherte Grafik-/Schwierigkeitsoptionen. Beide Grafikstufen und eine kompakte Fensterbreite wurden benutzt. Der Spieltest prüft zusätzlich auf JavaScript- und Konsolenfehler.
- `npm run build`: Produktionsbuild mit Blacksite und Expedition erfolgreich.
- Visuelle Kontrolle im Codex-Browser und anhand der Browser-Testbilder: Hauptmenü, Waffenansicht, Gesundheitsbalken, Gelände und Zielfernrohr.

Die bestehenden Expedition-Browsertests zeigen jetzt auf ihren expliziten Einstieg `/expedition.html`; sie wurden in dieser Änderung nicht vollständig erneut ausgeführt. Die 126 bestehenden Tests für Spielregeln und Ressourcen sind Bestandteil des erfolgreichen `npm test`-Laufs.

## Grafik und Laufzeit

Die fotografischen Oberflächen stammen aus den bereits mitgelieferten, dokumentierten Ressourcen. Waffen, Soldaten, Bauten, Vegetation und Effekte sind eigene prozedurale Modelle. Der Look kombiniert PBR, gerichtete dynamische Schatten, atmosphärischen Himmel, Nebel und dezentes Bloom; die hohe Stufe ergänzt GTAO-Kontaktschatten. Das ist ein eigenständiger WebGL-Spielprototyp, keine fotorealistische AAA-Produktion.

Statische Bauteile werden pro Material zusammengefasst; zerstörbare Objekte bleiben dabei separat entfernbar. Vegetation und Steine verwenden Instanzen. Nicht mehr benötigte Effekte und Gegnergeometrien werden freigegeben. Der Simulationstakt beträgt 120 Hz mit begrenztem Aufholschritt.

Die Software-Grafik des automatisierten Chromium läuft deutlich langsamer als native GPU-Grafik; der Browser-Spieltest benötigt deshalb bis zu drei Minuten. Ein eingebetteter Browser kann den Mausfang verweigern. In diesem Fall sind Ziehen und Pfeiltasten verfügbar; das Electron-Fenster unterstützt den klassischen Mausfang. Ein neues signiertes Desktop-Installationspaket und native Windows-Tests sind nicht Teil dieser Prüfung.
