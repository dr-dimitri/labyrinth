# Vertical labyrinth integration

User requests a larger labyrinth, climbing up/down, and Alien-inspired eerie exploration music. Preserve shooter/gameplay/progression. Root owns UI/main/style/docs/build; audio agent audio+audio test; world agent content+simulation+unit tests; visual agent renderer+visual helper.

## World / simulation contract

- Maze size upper limit51 (was35), fresh recommended size25; levels1..3, default3 for UI. Pure constructors may default1 to preserve API/backwards tests; root always supplies levels.
- `generateExpedition(config)` provides `levels` array of level definitions. Each `{index,y,maze}` plus any local content helper fields. Floor height constant `LEVEL_HEIGHT=6` exported from simulation or expedition. `maze` is initially level0 maze.
- Global rooms/objectives/treasures/hazards/rescue positions have `level` integer and absolute world `y` floor base; preserve x,z world units. Every object id unique across floors. Public arrays stay global, except `simulation.maze` is the currently active floor.
- Exactly3 seal/repair objectives spread across requested floors; rescue on highest floor. The portal remains on ground floor0 for every mission so missions require climbing back down. `simulation.exit` uses grid `{x,z,level:0}`; local maze.exit remains compatible. Ground sanctuary only truly safe; other floors may have room variety. At least one valid sanctuary overall.
- `simulation.levels` exposes floor definitions; `player.level` and `player.y` absolute floor base. `simulation.exploredByLevel` array of Sets; `simulation.explored` aliases current set.
- `ladders` global array `{id,x,z,fromLevel,toLevel,bottomY,topY}`. Use 2 distinct connectors per adjacent floor pair where feasible. Both endpoint cells must be open, reachable, clear of other interactions, and protected from wall shifts. Keep connectors distinct on middle floors. At least one ground ladder near start (but outside exact sanctuary center) for discoverability. Carve connector niches/cells fairly without disconnecting floors.
- `interaction` includes climb action label 'Nach oben klettern · Ebene2'/'Nach unten ...'. E initiates visible smooth automatic climbing (about3secs) between absolute heights; no teleporting camera. `climbing` null or `{ladderId,fromLevel,toLevel,progress,duration,fromY,toY}`. While climbing lock horizontal movement/fire, advance y, pause freezes. At destination update level/maze/explored alias, increment mapRevision to rebuild scene. Safe landing plus brief grace. Preserve player x,z. Root displays progress and level status.
- All interactions/hazards/monsters/weapons/sanctuary/exit check current level. Prevent hitting or collecting objects on another floor. Rays use absolute heights and floor/ceiling collision. Enemy AI may update same-level actors and follow stairs or retain inactive-floor actors safely; meaningful no impossible floor attacks. Rescue MUST traverse ladders with player and remain reachable; all missions completable across levels. Portal only wins on ground floor.
- World events affect active floor safely; protected ladder cells never close. Saved result same profile schema; metadata may add levels.
- Compass route targets correct floor; if objective elsewhere, reveal route to next ladder in the needed direction. Map path/help should guide up and down, not dead-end.
- Provide meaningful unit tests maximum51 and all floor connectivity, ladder reachability, smooth up/down+pause, cross-floor interaction/weapon isolation, cross-floor missions+escort, safe wall changes. Existing tests preserved/updated where behavior changed.

## Visuals

- Existing renderer currently builds one floor. Continue active-floor rendering for performance up to51x51. Offset entire world geometry to floor base (while absolute dynamic object positions must not double-offset) or build base-local consistently.
- Smooth visible ladder shafts with actual rungs and landing platforms; openings in active floor/ceiling at ladder cells; nearby destination landing/shaft visible during ascent/descent. No full duplicated giant floor needed. On mapRevision transition rebuild current floor without reloading shared assets; new viewpoint's absolute camera y stays continuous.
- Filter global content by current player.level. Render portals ground only. Handle player/climbing y for camera, flashlight, particles and first-person weapons, monsters/rescue worldbase.
- Recompute geometry/room count/resource cleanup correctly for bigger worlds and repeated climbs. Respect screenshot honesty: original meshes vs scanned assets.

## Root UI

- size range max51 default25; level selector1..3 default3; persist levels, migrate old smaller defaults once. labels mention size per level and total explored levels.
- HUD active floor/climb progress; E automatic ascent/descent, weapon lock while climbing; minimap current-floor indicator and ladder up/down glyphs. Journal mission overview includes floor count.
- root audio agent composes original sci-fi horror ambience while preserving combat.
