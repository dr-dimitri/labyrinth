# Internal expedition integration contract

User approved the complete variety proposal: 3 missions, 3 enemy behaviours, 2 tool slots, special rooms, warned dynamic events, optional treasure/progression, 3 distinct biomes.

## Content / progression (src/expedition.js, src/progression.js)

- Export `BIOMES`, `MISSIONS`, `TOOLS` as arrays of objects with `id`, German `name`, `description`; biomes ids `catacombs`, `ruins`, `mine`; missions `seals`, `repair`, `rescue`; tools `stone`, `chalk`, `flare`, `compass`, plus `charges`.
- `generateExpedition(config)` returns `{ maze, rooms, objectives, treasures, hazards, mission, biome, rescue }`.
- Maze existing format, 0=floor/1=wall, CELL=3.6. Every gameplay position below uses WORLD metres `{x,z}` except `room.cells` array of integer `{x,z}` grid cells. `maze.relics` still has 3 reachable cell points for compatibility. Protect outer walls, ensure all floors/objects accessible.
- Four special room types `sanctuary`, `library`, `flooded`, `treasury`, seeded placement/carved areas, each `{id,type,name,x,z,radius,cells,puzzle?}`. Puzzle has `symbols: string[3]`, `sequence: number[3]`, `clue: string`. Start in/near sanctuary, objectives outside sanctuary.
- Objectives `{id,type,x,z,label,completed:false}`: seals 3 type `seal`, repair 3 type `mechanism`, rescue 1 type `survivor` plus optional lore locations represented room content. `mission` and `biome` return definition object.
- `rescue` for rescue mission `{x,z,following:false,rescued:false}` else null.
- Treasures 2+ `{id,x,z,value,trapped,label,collected:false}` optional and distinct from mission objectives.
- Hazards `{id,type,x,z,radius}` biome-specific: `spikes` catacombs, `thorns` ruins, `gas` mine. Room flooded and global events implemented simulation.
- Progression: `createProfile()` and `normalizeProfile(value)` schema validated; `getUnlocks(profile)` returns `{biomes:string[],tools:string[]}`; `recordExpedition(profile,result)` returns new profile, idempotent by `result.id`.
- Profile fields `version, completedRuns, failedRuns, earned, journal:string[], processedRuns:string[]`. Start catacombs + stone/chalk; first victory unlocks ruins and flare; earned>=6 unlocks compass; earned>=8 or wins>=3 unlocks mine. Result `{id,won,treasure,biome,mission,journal}`; win banks base2+treasure, death loses unbanked treasure; journal kept either way. Corrupt storage safe.

## Simulation (src/simulation.js)

Keep exports GameSimulation,CELL,PLAYER_RADIUS and existing fields/functions for compatibility where practical. Constructor config extends `{mission='seals',biome='catacombs',loadout:['stone','chalk'], ...old}`. Call generateExpedition. UI validates unlocks; pure sim normalizes ids.

- Fields: `maze,config,player:{x,z,stamina,health},monsters,elapsed,status,events,explored` plus `rooms,objectives,treasures,hazards,rescue` from expedition.
- `inventory` exactly 2 items `{id,charges}`; `markers`, `flares`, `decoys` arrays world-space objects with unique ids; `carriedTreasure` number; `journal` array strings; `mapRevision` number.
- `missionProgress` getter `{completed,total,ready,text}`. `interaction` getter closest action `{type,id,label,description?}` or null. `interact()` performs action (collect/repair start/talk/drain/rest/chest/library); `collectRelic()` compatibility wrapper for seals. `activeInteraction` {id,progress,duration,label} for repair.
- Library: `activePuzzle` null or `{roomId,symbols,clue,progress}`; `chooseRune(index)` handles prefix matching, resets wrong answer, marks solved and gives map hint/bonus on success; `closePuzzle()` resets activePuzzle. UI freezes simulation while puzzle panel open.
- `step(dt,{moveX,moveZ,sprint,yaw,pitch,light=true})` returns `{moving,sprinting,threat}`. `useTool(slot,yaw)` handles Q(slot0)/R(slot1), safe raycast throw, chalk, flare, compass reveal.
- Monsters types `listener` (sound/decoys, never omniscient), `shade` (repelled by visible flashlight cone or flares), `watcher` (moves only outside view cone/LOS). Each has id,x,z,age,type; optional state. Types cycle spawns, safe path distance remains. Sacred sanctuary protects/restores. Pause by skipping step.
- Global `worldEvent` null or `{type,phase:'warning'|'active',remaining,duration,label}` types `shift`,`flood`,`blackout`,`gas`. 8s warning, bounded event durations. Shift changes maze only if ALL remaining floor cells/objectives/start/exit remain reachable; never closes player/monster/NPC/item/room cells. Increment mapRevision on structural edits. Flood slows/raises local or global water; blackout extinguishes environmental torches (player flashlight still works). Calm mode no damaging events/monsters; can retain harmless room interactions.
- Hazards should give warnings, avoid unannounced instant death; health and invulnerability sensible. Dynamic runtime hazard fields active/warning, rooms flooded/drained/solved/rested/trap etc as necessary, document extra fields to root+renderer agent.
- Events retain old types + use descriptive `{type:'message',text}` for gameplay notices; structured `mission`, `tool`, `treasure`, `damage`, `world-warning`, `world-active`, `puzzle`, `journal`, `rescue` optional UI handles generic text. win/lose only once. Result getter `{id,won,treasure,biome,mission,journal}`.

## Visuals (renderer agent owns renderer.js plus expedition visuals helper)

Consume above fields; preserve real PBR assets. Render biome geometry/palette (catacombs halls, overgrown open ruins with vines, mine rock/timber/rails); 4 recognizable room props. Objectives show seal, repair mechanism, escort survivor visual (spectral explorer okay; explanatory UI). Show treasure chests/trap warnings, chalk arrows, airborne stones, flare pools, escort progress and water/gas.
Three enemies distinguish visibly: guardian listener, dark shade, actual statue watcher; preserve shared-asset cleanup. Renderer `update(dt,sim,view)` same signature. Rebuild static geometry when sim.mapRevision changes, never reload source assets. Existing renderer.relicMeshes may remain for seals but objective count may differ by mission. Torch blackout honors worldEvent. No main.js/index.html/style.css edits.

## Root UI

Root owns main.js/index.html/style.css/audio.js, integration and native packaging. Add biome/mission/loadout selectors with visible unlock criteria, run briefing, objective/interact/HUD/tools/health/noise/events, puzzle dialog, journal/progression summary, result rewards/unlock announcements. Save profile separately from settings. Use keys E/Q/R/J plus existing; preserve focus/pause/mouse capture. Tests and docs coordinated per owner.

## Final shooter additions

- User expanded scope to laser, rocket and machinegun, increased player/enemy speed, adaptive industrial-combat / eerie-stealth music.
- All three weapons available from the start. Default UI loadout machinegun/rocket. `useTool(slot,yaw,pitch)`; Q/R or captured LMB/RMB. Holding MG/laser repeats; rocket/tool actions fire once per press.
- MG `charges` is total remaining ammunition including current `magazine`, initially180/30; `reloadRemaining`1.7seconds, `reloadWeapons()` on T and automatic reload when empty.
- Laser charges80 with normalized heat/overheated; rockets3 with simulated trajectory and wall-blocked splash. Runtime `projectiles` and `weaponEffects` drive visuals; events `weapon` and `explosion` drive sound.
- `step` accepts `sneak`; C gives2.2m/s and noise.05; walk4.5/sprint7.2. `player.sneaking` controls quiet footstep audio. Normal pursuit4.0–5.0m/s, nightmare4.7–5.875m/s.
- `activePuzzle.progress` is an array of selected indices; UI displays its length.
- Calm ignores all player damage, including own rockets. Structured event text carries near-impact warning.
- Root owns adaptive WebAudio ambient/combat layers, with144BPM original riff and drums, smoothly driven by threat; no external soundtrack recordings.
