# Tamagotchi

Ein Desktop-Haustier für macOS, das über Claude-Code- und Codex-Sessions wacht. Jede Agent-Session bekommt ein eigenes
Mini-Haustier mit festem Aussehen. Das große Haustier zeigt neue Meldungen zwei Minuten lang als Sprechblase, danach
liegen sie in der Inbox.

## Was es kann

- **Haustiere:** Stimmung je nach Lage (arbeitet, wartet auf dich, fertig, schläft), Requisiten für Rückfragen,
  laufende Pipelines, Sichtprüfungen und Merges. Ziehen verschiebt, Klick öffnet die dringendste Meldung oder den Chat.
- **Übersicht** (Doppelklick oder ⌃⌥I), mit allen Agenten in der Seitenleiste:
  - **Live:** Kennzahlen, eine Karte pro Agent mit Auftrag und aktuellem Werkzeug, MRs mit Bewegung, Tagesverlauf.
  - **Inbox:** gegliedert in Jetzt dran, Kann warten, Gelesen, Zurückgestellt und Erledigt. Mit Suche, Filter,
    Wiedervorlage, Anheften, eigener Einstufung, Rückgängig und Tastaturbedienung.
  - **Aufgaben und MRs:** Ticket, Workspace und Session zu jeder Aufgabe. Bei roter Pipeline das Ende des Job-Logs
    und „Fix auftragen“, bei offenen Kommentaren „Kommentare an Agent geben“.
  - **Bericht:** Standup-Notiz und Tagesrückblick zum Kopieren, Zeit pro Ticket, auf Klick nach ClickUp gebucht.
  - **Agentenansicht:** Überblick, Verlauf der Turns aus dem Transkript, Änderungen (Git-Stand, Diff, bearbeitete
    Dateien), Rückfragen und Verbrauch (Kontextkurve, Werkzeuge).
- **Wächter:** meldet Agenten, die wiederholt scheitern, sich im Kreis drehen, lange still sind oder einen sehr
  vollen Kontext haben.
- **Menüleiste:** Zähler für wartende Agenten, rote Pipelines und ungelesene Meldungen, dazu ein Kurzmenü.
- **Ruhe-Modus:** bei Bildschirmfreigabe (Zoom, Teams, Meet, Slack) oder von Hand verschwinden die Haustiere. Danach
  gibt es eine einzige Zusammenfassung.
- **Chat und Aufträge:** Fragen per `claude -p`. Arbeitsaufträge startet das Haustier auf Klick als eigene
  Claude-Code-Session.

## Datenquellen

- Hooks schreiben nach `~/.claude/tamagotchi/events.jsonl` (`pet.sh`, `notify.sh` aus den dotfiles).
- GitLab per `glab`, GitHub per `gh`, ClickUp über den ClickUp-MCP in `claude -p`.
- Der Zustand liegt in `~/.claude/tamagotchi/state.json`.

## Bauen

```sh
./build.sh          # baut ~/Applications/Tamagotchi.app und (re)startet den LaunchAgent
tools/icon.sh       # AppIcon.icns aus dem Pixel-Haustier neu rendern
tools/icon.sh x.png # oder aus einem eigenen 1024×1024-PNG mit transparenten Ecken
```

Das aktuelle Icon ist aus `icon-source.png` (generiert mit dem Prompt aus `ICON-PROMPT.md`) entstanden:
`tools/squircle.swift` schneidet das Squircle aus und setzt es ins macOS-Raster, `tools/icon.sh` macht daraus `AppIcon.icns`.

Braucht die Xcode Command Line Tools (swiftc), macOS 14 oder neuer und für den Chat die Freigabe für Bildschirmaufnahme.
