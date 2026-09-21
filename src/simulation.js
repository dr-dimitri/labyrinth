import { createRng, walkable, findPath, reachableCells } from './maze.js';
import { generateExpedition, TOOLS, LEVEL_HEIGHT } from './expedition.js';
import { getTerrainHeight, getTerrainCeiling, forestSolidAt } from './forest-world.js';
export { LEVEL_HEIGHT };

export const CELL = 3.6;
export const PLAYER_RADIUS = 0.28;

const DANGERS = {
  calm: { firstSpawn: Infinity, spawnEvery: Infinity, cap: 0, speed: 0, distance: 7 },
  normal: { firstSpawn: 8, spawnEvery: 9, cap: 8, wave: 2, speed: 4.0, distance: 7, nearbyDistance: 18 },
  nightmare: { firstSpawn: 5, spawnEvery: 6, cap: 12, wave: 2, speed: 4.7, distance: 5, nearbyDistance: 16 },
};
const ENEMIES = {
  wolf: { health: 85, speed: 1.35, name: 'Der Rotaugenwolf', hitHeight: 0.75, hitRadius: 0.66 },
  orc: { health: 210, speed: 0.86, name: 'Der Waldork', hitHeight: 1.35, hitRadius: 0.88 },
  listener: { health: 110, speed: 1, name: 'Der blinde Wächter' },
  shade: { health: 75, speed: 1.12, name: 'Der Schatten' },
  watcher: { health: 145, speed: 1.25, name: 'Die Wanderstatue' },
};
const EVENT_LABELS = {
  shift: 'Das Labyrinth verschiebt sich', flood: 'Wasser steigt in den Gängen',
  blackout: 'Die Wandfackeln erlöschen', gas: 'Grubengas tritt aus',
};
const EPSILON = 1e-8;
const cellOf = ({ x, z }) => ({ x: Math.round(x / CELL), z: Math.round(z / CELL) });
const worldOf = ({ x, z }) => ({ x: x * CELL, z: z * CELL });
const distance = (a, b) => Math.hypot(a.x - b.x, a.z - b.z);
const finite = (value) => Number.isFinite(value) ? value : 0;
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const keyOf = (point) => `${point.x},${point.z}`;
let runSequence = 0;

/** Stateful game rules. All durations advance only through step(), so menus pause everything. */
export class GameSimulation {
  constructor(config = {}) {
    config = config && typeof config === 'object' ? config : {};
    const content = generateExpedition(config);
    Object.assign(this, content);
    this.allies ??= [];
    const danger = Object.hasOwn(DANGERS, config?.danger) ? config.danger : 'normal';
    const requestedTools = Array.isArray(config.loadout) ? config.loadout : ['stone', 'chalk'];
    const loadout = [0, 1].map((slot) => TOOLS.some((tool) => tool.id === requestedTools[slot])
      ? requestedTools[slot] : ['stone', 'chalk'][slot]);
    this.config = {
      size: this.maze.size, complexity: this.maze.complexity, seed: this.maze.seed,
      danger, biome: this.biome.id, mission: this.mission.id, loadout, levels: this.levels.length,
    };
    this.player = { ...worldOf(this.maze.start), level: 0, y: 0, stamina: 100, health: 100, noise: 0 };
    if (this.terrain) this.player.y = getTerrainHeight(this.terrain, this.player.x, this.player.z);
    this.inventory = loadout.map((id) => ({ id, charges: TOOLS.find((tool) => tool.id === id).charges,
      heat: 0, cooldown: 0, overheated: false,
      ...(id === 'machinegun' ? { magazine: 30, reloadRemaining: 0 } : {}) }));
    this.monsters = [];
    // Keep the original relic interface for the seals mission and existing integrations.
    this.relics = this.config.mission === 'seals' ? this.objectives.map((objective) => {
      Object.defineProperty(objective, 'collected', { enumerable: true, configurable: true,
        get() { return this.completed; }, set(value) { this.completed = Boolean(value); } });
      return objective;
    }) : this.maze.relics.map((cell) => ({ ...worldOf(cell), collected: false }));
    this.elapsed = 0;
    this.status = 'playing';
    this.events = [];
    this.exploredByLevel = this.levels.map(() => new Set());
    this.explored = this.exploredByLevel[0];
    this.climbing = null;
    this.markers = [];
    this.flares = [];
    this.decoys = [];
    this.projectiles = [];
    this.weaponEffects = [];
    this.carriedTreasure = 0;
    this.journal = [];
    this.mapRevision = 0;
    this.noise = 0;
    this.activeInteraction = null;
    this.activePuzzle = null;
    this.worldEvent = null;
    this.compassPath = [];
    this.compassRemaining = 0;
    this._runId = `${Date.now().toString(36)}-${++runSequence}-${Math.random().toString(36).slice(2, 9)}`;
    this._danger = DANGERS[danger];
    this._nextSpawn = this._danger.firstSpawn;
    this._nextMonsterId = 1;
    this._nextItemId = 1;
    this._monsterPaths = new Map();
    this._rescuePath = { waypoints: [], refreshIn: 0 };
    this._rng = createRng(`${this.maze.seed}:encounters:${danger}`);
    this._floors = reachableCells(this.maze);
    this._exhausted = false;
    this._recoveryDelay = 0;
    this._invulnerable = 0;
    this._soundPulse = 0;
    this._weaponNoticeAt = -10;
    this._nextWorldEvent = danger === 'calm' ? Infinity : danger === 'nightmare' ? 34 : 48;
    this._eventIndex = 0;
    this._view = { yaw: 0, pitch: 0, light: true };
    for (const hazard of this.hazards) Object.assign(hazard,
      { active: false, warning: false, remaining: 0, cooldown: 0 });
    for (const room of this.rooms) Object.assign(room,
      { drained: false, solved: false, restCooldown: 0, discovered: false });
    this._explore();
  }

  get worldEvent() { return this.levels[this.player.level].worldEvent ?? null; }
  set worldEvent(event) { this.levels[this.player.level].worldEvent = event; }

  _floorAt(x, z, level = this.player.level) { return this.terrain ? getTerrainHeight(this.terrain, x, z) : level * LEVEL_HEIGHT; }

  _ceilingAt(x, z, level = this.player.level) {
    return this.terrain ? getTerrainCeiling(this.terrain, x, z)
      : this.config.biome !== 'ruins' || level < this.levels.length - 1 ? level * LEVEL_HEIGHT + 4.15 : Infinity;
  }

  _onLevel(entity, level = this.player.level) { return (entity.level ?? this.player.level) === level; }

  _beginClimb(id) {
    const ladder = this.ladders.find((entry) => entry.id === id);
    if (!ladder || this.climbing) return false;
    const fromLevel = this.player.level;
    const toLevel = ladder.fromLevel === fromLevel ? ladder.toLevel : ladder.fromLevel;
    if (this.rescue?.following && (!this._onLevel(this.rescue) || distance(this.player, this.rescue) > 5
      || !this._lineOfSight(this.player, this.rescue))) {
      this._message('Der Forscher muss bei dir sein, bevor ihr gemeinsam klettern könnt.');
      return false;
    }
    this.activeInteraction = null;
    this.player.noise = this.noise = 0;
    this.climbing = { ladderId: id, fromLevel, toLevel, progress: 0, duration: 3,
      fromY: fromLevel * LEVEL_HEIGHT, toY: toLevel * LEVEL_HEIGHT,
      fromX: this.player.x, fromZ: this.player.z, toX: ladder.x, toZ: ladder.z,
      ...(this.rescue?.following ? { escortFrom: { x: this.rescue.x, z: this.rescue.z } } : {}) };
    this._message(`Du kletterst ${toLevel > fromLevel ? 'nach oben' : 'nach unten'} zu Ebene ${toLevel + 1}.`);
    return true;
  }

  _updateClimb(dt) {
    const climb = this.climbing;
    climb.progress = Math.min(climb.duration, climb.progress + dt);
    // Ease into the shaft before ascending, avoiding a camera snap when E is
    // pressed at the edge of the interaction radius. Floor changes only at the
    // landing; the shaft and its immediate endpoints remain protected.
    const alignment = Math.min(1, climb.progress / 0.35);
    const aligned = alignment * alignment * (3 - 2 * alignment);
    this.player.x = climb.fromX + (climb.toX - climb.fromX) * aligned;
    this.player.z = climb.fromZ + (climb.toZ - climb.fromZ) * aligned;
    const t = clamp((climb.progress - 0.2) / (climb.duration - 0.2), 0, 1);
    const smooth = t * t * (3 - 2 * t);
    this.player.y = climb.fromY + (climb.toY - climb.fromY) * smooth;
    if (climb.escortFrom) {
      this.rescue.x = climb.escortFrom.x + (climb.toX - climb.escortFrom.x) * smooth;
      this.rescue.z = climb.escortFrom.z + (climb.toZ - climb.escortFrom.z) * smooth;
      this.rescue.y = this.player.y;
    }
    if (climb.progress + EPSILON < climb.duration) return;
    this.player.level = climb.toLevel;
    this.player.y = climb.toY;
    this.maze = this.levels[climb.toLevel].maze;
    this.explored = this.exploredByLevel[climb.toLevel];
    this._floors = reachableCells(this.maze);
    this._monsterPaths.clear();
    this._rescuePath = { waypoints: [], refreshIn: 0 };
    if (climb.escortFrom) {
      this.rescue.level = climb.toLevel;
      this.rescue.y = climb.toY;
      this.rescue.waiting = false;
      const objective = this.objectives.find((entry) => entry.type === 'survivor');
      if (objective) Object.assign(objective, { x: this.rescue.x, z: this.rescue.z, y: climb.toY, level: climb.toLevel });
    }
    this.climbing = null;
    this._invulnerable = 1.5;
    this.mapRevision += 1;
    this._explore();
    if (this.compassRemaining > 0) this._revealRoute();
    this._message(`Ebene ${this.player.level + 1} erreicht${climb.escortFrom ? ' – der Forscher ist bei dir' : ''}.`);
  }

  get nearbyRelic() {
    if (this.status !== 'playing' || this.config.mission !== 'seals' || this.climbing) return -1;
    let nearest = -1;
    let nearestDistance = 1.55;
    this.relics.forEach((relic, index) => {
      const separation = distance(this.player, relic);
      if (!relic.collected && separation <= nearestDistance && this._lineOfSight(this.player, relic)) {
        nearest = index;
        nearestDistance = separation;
      }
    });
    return nearest;
  }

  get threat() {
    if (!this.monsters.length || this.inSanctuary || this.climbing) return 0;
    const closest = Math.min(...this.monsters.filter((monster) => this._onLevel(monster)).map((monster) => distance(monster, this.player)));
    return clamp(1 - closest / 22, 0, 1);
  }

  get inSanctuary() { return this._isSanctuary(this.player); }

  get missionProgress() {
    const completed = this.objectives.filter((objective) => objective.completed).length;
    const total = this.objectives.length;
    const ready = completed === total;
    let text = this.config.mission === 'repair' ? `Mechanismen repariert: ${completed}/${total}`
      : this.config.mission === 'rescue' ? 'Finde den vermissten Forscher'
        : `Siegel geborgen: ${completed}/${total}`;
    if (this.config.mission === 'rescue' && this.rescue?.following) {
      text = this.rescue.waiting ? 'Der Forscher wartet – kehre zu ihm zurück' : 'Begleite den Forscher zum Portal';
    }
    if (ready) text = 'Das Portal ist geöffnet – erreiche den Ausgang';
    return { completed, total, ready, text };
  }

  get result() {
    return { id: this._runId, won: this.status === 'won', treasure: this.carriedTreasure,
      biome: this.config.biome, mission: this.config.mission, levels: this.levels.length, journal: [...this.journal] };
  }

  get interaction() {
    if (this.status !== 'playing' || this.activePuzzle || this.climbing) return null;
    const choices = [];
    const add = (entity, type, label, description, range = 1.9, priority = 0) => {
      const separation = distance(this.player, entity);
      if (this._onLevel(entity) && separation <= range && this._lineOfSight(this.player, entity)) {
        choices.push({ type, id: entity.id, label, description, separation, priority });
      }
    };
    for (const objective of this.objectives) {
      if (objective.completed || (objective.type === 'survivor' && this.rescue?.following)) continue;
      if (objective.type === 'seal') add(objective, 'seal', 'Siegel bergen', objective.label, 1.55, 2);
      if (objective.type === 'mechanism') add(objective, 'repair', 'Mechanismus reparieren',
        'Bleibe 4 Sekunden beim Mechanismus. Bewegung oder Schaden unterbricht die Reparatur.', 1.9, 2);
      if (objective.type === 'survivor') add(objective, 'rescue', 'Forscher ansprechen',
        'Begleite ihn zum Ausgang. Wenn du zu weit vorausläufst, wartet er.', 2.1, 2);
    }
    for (const treasure of this.treasures) {
      if (!treasure.collected) add(treasure, 'treasure', `Schatz bergen · ${treasure.value} Fundstücke`,
        treasure.trapped ? 'Falle! Nach dem Öffnen bleiben 2,5 Sekunden, um zurückzuweichen.'
          : 'Nur eine erfolgreiche Flucht sichert deine Fundstücke.', 1.7, 1);
    }
    for (const room of this.rooms) {
      if (room.type === 'library' && !room.solved) add(room, 'library', 'Runenrätsel untersuchen',
        'Entschlüssle die Inschrift und entdecke den Weg zum nächsten Ziel.', 2.1);
      if (room.type === 'flooded' && !room.drained) add(room, 'drain', 'Schleuse öffnen',
        'Lässt das Wasser in diesem Raum dauerhaft ab.', 2.1);
      if (room.type === 'sanctuary' && room.restCooldown <= 0 && this.player.health < 100) {
        add(room, 'rest', 'Am Schrein ausruhen', 'Heilt deine Wunden. Wächter können den Schutzkreis nicht betreten.', 2.6);
      }
    }
    for (const ally of this.allies) {
      const needed = this._needsAmmunition();
      add(ally, 'resupply', ally.cooldown > 0 ? `Nachschub in ${Math.ceil(ally.cooldown)} s`
        : needed ? 'Munition bei der Elfe auffüllen' : 'Munitionsvorrat ist vollständig',
      `${ally.label} · ${ally.cooldown > 0 ? 'Die Elfe bereitet neue Munition vor.'
        : needed ? 'Füllt beide Schusswaffen und das MG-Magazin vollständig auf. Neuer Nachschub nach 45 Sekunden.'
          : 'Du bist gut versorgt. Kehre zurück, wenn du Munition benötigst.'}`, 2.3, 1);
    }
    for (const ladder of this.ladders) {
      if (ladder.fromLevel !== this.player.level && ladder.toLevel !== this.player.level) continue;
      const destination = ladder.fromLevel === this.player.level ? ladder.toLevel : ladder.fromLevel;
      add(ladder, 'climb', `Nach ${destination > this.player.level ? 'oben' : 'unten'} klettern · Ebene ${destination + 1}`,
        this.rescue?.following ? 'Warte auf den Forscher, dann klettert ihr gemeinsam.' : 'E startet den Aufstieg oder Abstieg. Du brauchst beide Hände. Feuern ist erst am nächsten Absatz wieder möglich.', 1.9, 3);
    }
    choices.sort((a, b) => b.priority - a.priority || a.separation - b.separation);
    return choices[0] ?? null;
  }

  collectRelic() {
    const index = this.nearbyRelic;
    if (index === -1) return false;
    this.relics[index].completed = true;
    const count = this.relics.filter((relic) => relic.collected).length;
    this.events.push({ type: 'relic', index, count, remaining: this.relics.length - count,
      text: `Siegel geborgen · ${count}/${this.relics.length}` });
    this._addJournal('Drei uralte Siegel bewachen das Portal des Labyrinths.');
    this._checkVictory();
    return true;
  }

  interact() {
    const action = this.interaction;
    if (!action) return false;
    if (action.type === 'climb') return this._beginClimb(action.id);
    if (action.type === 'resupply') return this._resupply(action.id);
    if (action.type === 'seal') return this.collectRelic();
    if (action.type === 'repair') {
      this.activeInteraction = { id: action.id, progress: 0, duration: 4, label: 'Mechanismus wird repariert' };
      this._message('Reparatur begonnen – bleibe stehen.');
    } else if (action.type === 'rescue') {
      this.rescue.following = true;
      this.rescue.waiting = false;
      this.events.push({ type: 'rescue', text: 'Der Forscher folgt dir. Begleite ihn bis zum Portal.' });
      this._addJournal('Ein Forscher hat überlebt. Zusammen suchen wir den Ausgang.');
    } else if (action.type === 'treasure') {
      const treasure = this.treasures.find((item) => item.id === action.id);
      treasure.collected = true;
      this.carriedTreasure += treasure.value;
      this.events.push({ type: 'treasure', value: treasure.value, trapped: treasure.trapped,
        text: treasure.trapped ? `+${treasure.value} Fundstücke – Falle ausgelöst! Sofort zurückweichen!`
          : `+${treasure.value} Fundstücke. Erreiche den Ausgang, um sie zu behalten.` });
      if (treasure.trapped && this.config.danger !== 'calm') this.hazards.push({
        id: `trap-${treasure.id}`, type: 'spikes', x: treasure.x, z: treasure.z, y: treasure.y, level: treasure.level,
        radius: 2.25, warning: true, active: false, remaining: 2.5, cooldown: 0, once: true,
      });
    } else {
      const room = this.rooms.find((entry) => entry.id === action.id);
      if (action.type === 'library') {
        this.activePuzzle = { roomId: room.id, symbols: [...room.puzzle.symbols],
          clue: room.puzzle.clue, progress: [] };
      } else if (action.type === 'drain') {
        room.drained = true;
        this.events.push({ type: 'mission', text: 'Die Schleuse ist offen. Das Wasser in diesem Raum läuft ab.' });
        this._addJournal('Die alte Schleuse legt einen sicheren Weg durch die Wasserhalle frei.');
      } else if (action.type === 'rest') {
        this.player.health = 100;
        room.restCooldown = 45;
        this._message('Der Schrein heilt deine Wunden.');
      }
    }
    return true;
  }

  _needsAmmunition() {
    return this.inventory.some((item) => ['machinegun', 'laser', 'rocket'].includes(item.id)
      && (item.charges < TOOLS.find((tool) => tool.id === item.id).charges
        || (item.id === 'machinegun' && item.magazine < 30)));
  }

  _resupply(id) {
    const elf = this.allies.find((ally) => ally.id === id);
    if (!elf || elf.cooldown > 0 || !this._needsAmmunition()) return false;
    for (const item of this.inventory) {
      if (!['machinegun', 'laser', 'rocket'].includes(item.id)) continue;
      item.charges = TOOLS.find((tool) => tool.id === item.id).charges;
      item.heat = 0;
      item.overheated = false;
      if (item.id === 'machinegun') { item.magazine = 30; item.reloadRemaining = 0; }
    }
    elf.cooldown = 45;
    this.events.push({ type: 'resupply', allyId: id, text: `${elf.label} hat deine Munition aufgefüllt. Gute Jagd – und komm sicher zurück!` });
    this._addJournal('Die Elfenlager bieten Schutz und erneuern alle 45 Sekunden deinen Munitionsvorrat.');
    return true;
  }

  chooseRune(index) {
    if (!this.activePuzzle || this.status !== 'playing' || !Number.isInteger(index) || index < 0 || index > 2) return false;
    const room = this.rooms.find((entry) => entry.id === this.activePuzzle.roomId);
    const progress = this.activePuzzle.progress;
    if (room.puzzle.sequence[progress.length] !== index) {
      this.activePuzzle.progress = [];
      this.events.push({ type: 'puzzle', correct: false, text: 'Die Runen erlöschen. Lies die Reihenfolge in der Inschrift.' });
      return false;
    }
    progress.push(index);
    if (progress.length === room.puzzle.sequence.length) {
      room.solved = true;
      this.carriedTreasure += 2;
      this._revealRoute();
      this._addJournal('Die Bibliothek verrät ihr Geheimnis: Die Runen weisen den Weg.');
      this.activePuzzle = null;
      this.events.push({ type: 'puzzle', correct: true, solved: true,
        text: 'Rätsel gelöst! +2 Fundstücke. Der Weg zum nächsten Ziel ist auf der Karte sichtbar.' });
    }
    return true;
  }

  closePuzzle() { this.activePuzzle = null; }

  useTool(slot, yaw = this._view.yaw, pitch = this._view.pitch, shot = null) {
    if (this.status !== 'playing' || this.activePuzzle || this.climbing || !Number.isInteger(slot)) return false;
    const item = this.inventory[slot];
    if (!item || item.charges <= 0) { this._weaponNotice('Dieser Ausrüstungsplatz ist leer.'); return false; }
    if (item.reloadRemaining > 0) return false;
    if (item.id === 'machinegun' && item.magazine <= 0) { this.reloadWeapons(); return false; }
    if (item.cooldown > 0) return false;
    const firearm = ['laser', 'machinegun', 'rocket'].includes(item.id);
    const firingRay = firearm ? this._firingRay(shot, yaw, pitch, item.id) : null;
    if (firearm && !firingRay) return false;
    const direction = firingRay?.direction ?? this._aim(yaw, pitch);
    const origin = firingRay?.origin;
    const id = this._nextItemId++;
    if (item.id === 'laser' || item.id === 'machinegun') {
      if (item.overheated) { this._weaponNotice('Laser überhitzt – lass ihn abkühlen.'); return false; }
      const ray = firingRay.obstruction ?? this._traceAim(origin, direction, 55);
      const hit = firingRay.obstruction ? null : ray.monster;
      this.weaponEffects.push({ id, slot, type: item.id === 'laser' ? 'laser' : 'bullet',
        ...origin, level: this.player.level, toX: ray.x, toZ: ray.z, toY: ray.y,
        age: 0, duration: item.id === 'laser' ? 0.16 : 0.09, hit: Boolean(hit) });
      if (hit) this._damageMonster(hit, item.id === 'laser' ? 38 : 21, item.id);
      if (item.id === 'laser') {
        item.heat = Math.min(1, item.heat + 0.28);
        item.overheated = item.heat >= 1 - EPSILON;
      } else item.magazine -= 1;
      item.cooldown = item.id === 'laser' ? 0.17 : 0.09;
      this._soundPulse = Math.max(this._soundPulse, 0.9);
      this.events.push({ type: 'weapon', weapon: item.id, slot, hit: Boolean(hit) });
      if (item.overheated) this._message('Laser überhitzt. Er ist nach kurzer Abkühlung wieder bereit.');
    } else if (item.id === 'rocket') {
      this.projectiles.push({ id, slot, type: 'rocket', ...origin, level: this.player.level,
        dx: direction.x, dz: direction.z, dy: direction.y, age: 0, duration: 3.6,
        ...(firingRay.obstruction ? { blockedImpact: firingRay.obstruction } : {}) });
      item.cooldown = 0.85;
      this._soundPulse = Math.max(this._soundPulse, 1.8);
      const obstacle = firingRay.obstruction ?? this._raycast3D(origin, direction, 5.2);
      this.events.push({ type: 'weapon', weapon: 'rocket', slot,
        text: obstacle.hit ? 'Rakete! Naher Einschlag – gehe sofort auf Abstand!' : 'Rakete abgefeuert.' });
    } else if (item.id === 'stone') {
      const target = this._raycastGround(this.player, direction, 13);
      this.decoys.push({ id, x: target.x, z: target.z, y: this._floorAt(target.x, target.z), level: this.player.level, fromX: this.player.x, fromZ: this.player.z,
        age: 0, remaining: 8, duration: 8, flightDuration: 0.45 });
      item.cooldown = 0.5;
      this.events.push({ type: 'tool', tool: item.id, text: 'Stein geworfen. Der blinde Wächter untersucht das Geräusch.' });
    } else if (item.id === 'chalk') {
      this.markers.push({ id, x: this.player.x, z: this.player.z, y: this.player.y, level: this.player.level, yaw: finite(yaw) });
      item.cooldown = 0.4;
      this.events.push({ type: 'tool', tool: item.id, text: 'Kreidepfeil gesetzt. Er bleibt sichtbar und erscheint auf der Karte.' });
    } else if (item.id === 'flare') {
      this.flares.push({ id, x: this.player.x, z: this.player.z, y: this.player.y, level: this.player.level, age: 0, remaining: 25, duration: 25 });
      item.cooldown = 0.5;
      this.events.push({ type: 'tool', tool: item.id, text: 'Leuchtfackel entzündet. Ihr Licht hält Schatten für 25 Sekunden fern.' });
    } else if (item.id === 'compass') {
      this._revealRoute();
      item.cooldown = 0.5;
      this.events.push({ type: 'tool', tool: item.id, text: 'Der Kompass zeigt auf der Karte den Weg zum nächsten Missionsziel.' });
    } else return false;
    item.charges -= 1;
    return true;
  }

  reloadWeapons() {
    if (this.status !== 'playing' || this.activePuzzle || this.climbing) return false;
    let started = false;
    for (const item of this.inventory) {
      if (item.id !== 'machinegun' || item.reloadRemaining > 0 || item.magazine >= 30
        || item.magazine >= item.charges || item.charges <= 0) continue;
      item.reloadRemaining = 1.7;
      started = true;
    }
    if (started) this.events.push({ type: 'reload', complete: false, text: 'Maschinengewehr wird nachgeladen …' });
    return started;
  }

  /** A large dt is subdivided to keep collisions, rocket impacts and timers reliable. */
  step(dt, input = {}) {
    let moving = false;
    let sprinting = false;
    if (this.status !== 'playing' || this.activePuzzle || !Number.isFinite(dt) || dt <= 0) {
      return { moving, sprinting, threat: this.threat };
    }
    let moveX = finite(input?.moveX);
    let moveZ = finite(input?.moveZ);
    const magnitude = Math.hypot(moveX, moveZ);
    if (magnitude > 1) { moveX /= magnitude; moveZ /= magnitude; }
    this._view = { yaw: finite(input.yaw), pitch: finite(input.pitch), light: input.light !== false };
    for (let remaining = dt; remaining > EPSILON && this.status === 'playing';) {
      const seconds = Math.min(0.05, remaining);
      remaining -= seconds;
      this.elapsed += seconds;
      this._invulnerable = Math.max(0, this._invulnerable - seconds);
      this._soundPulse = Math.max(0, this._soundPulse - seconds);
      if (this.climbing) {
        this._updateClimb(seconds);
        this._updateEquipment(seconds);
        this._updateStamina(seconds, false);
        continue;
      }
      const wantsMovement = Math.abs(moveX) + Math.abs(moveZ) > EPSILON;
      const sneaking = Boolean(input.sneak) && wantsMovement;
      this.player.sneaking = sneaking;
      const canSprint = Boolean(input?.sprint) && !sneaking && wantsMovement && !this._exhausted && this.player.stamina > 0;
      const speed = (sneaking ? 2.2 : canSprint ? 7.2 : 4.5) * this._movementFactor();
      const didMove = this._move(this.player, moveX * speed * seconds, moveZ * speed * seconds, PLAYER_RADIUS);
      moving ||= didMove;
      sprinting ||= didMove && canSprint;
      this.noise = this.player.noise = this._soundPulse > 0 ? 1 : didMove ? sneaking ? 0.05 : canSprint ? 1 : 0.3 : 0;
      this._updateStamina(seconds, didMove && canSprint);
      this._updateInteractions(seconds, didMove);
      this._updateEquipment(seconds);
      this._updateRooms(seconds);
      this._updateWorldEvent(seconds);
      this._updateHazards(seconds);
      this._updateProjectiles(seconds);
      this._explore();
      this._spawnIfDue();
      this._moveMonsters(seconds);
      this._moveRescue(seconds);
      if (this.status === 'playing') this._checkVictory();
    }
    return { moving, sprinting, threat: this.threat };
  }

  _canOccupy(x, z, radius, level = this.player.level) {
    const maze = this.levels[level]?.maze ?? this.maze;
    const left = Math.floor((x - radius + CELL / 2) / CELL);
    const right = Math.floor((x + radius + CELL / 2) / CELL);
    const top = Math.floor((z - radius + CELL / 2) / CELL);
    const bottom = Math.floor((z + radius + CELL / 2) / CELL);
    for (let cellZ = top; cellZ <= bottom; cellZ += 1) {
      for (let cellX = left; cellX <= right; cellX += 1) {
        if (walkable(maze, cellX, cellZ)) continue;
        const nearestX = clamp(x, cellX * CELL - CELL / 2, cellX * CELL + CELL / 2);
        const nearestZ = clamp(z, cellZ * CELL - CELL / 2, cellZ * CELL + CELL / 2);
        if ((x - nearestX) ** 2 + (z - nearestZ) ** 2 < radius ** 2 - EPSILON) return false;
      }
    }
    return true;
  }

  _move(body, deltaX, deltaZ, radius, avoidSanctuary = false) {
    const beforeX = body.x;
    const beforeZ = body.z;
    const valid = (x, z) => this._canOccupy(x, z, radius, body.level ?? this.player.level)
      && (!avoidSanctuary || !this._isSanctuary({ x, z, level: body.level ?? this.player.level }));
    if (valid(body.x + deltaX, body.z)) body.x += deltaX;
    if (valid(body.x, body.z + deltaZ)) body.z += deltaZ;
    if (this.terrain) body.y = this._floorAt(body.x, body.z, body.level ?? this.player.level);
    return Math.abs(body.x - beforeX) + Math.abs(body.z - beforeZ) > EPSILON;
  }

  _updateStamina(dt, sprinting) {
    if (sprinting) {
      this.player.stamina = Math.max(0, this.player.stamina - 22 * dt);
      this._recoveryDelay = 1.1;
      if (this.player.stamina <= EPSILON && !this._exhausted) {
        this.player.stamina = 0;
        this._exhausted = true;
        this.events.push({ type: 'exhausted', text: 'Erschöpft – gehe langsam, bis du dich erholt hast.' });
      }
    } else {
      const recoveringTime = Math.max(0, dt - this._recoveryDelay);
      this._recoveryDelay = Math.max(0, this._recoveryDelay - dt);
      this.player.stamina = Math.min(100, this.player.stamina + 13 * recoveringTime);
      if (this._exhausted && this.player.stamina >= 25) this._exhausted = false;
    }
  }

  _movementFactor() {
    if (this.inSanctuary) return 1;
    if (this.worldEvent?.type === 'flood' && this.worldEvent.phase === 'active') return 0.72;
    return this.rooms.some((room) => room.type === 'flooded' && !room.drained && this._insideRoom(this.player, room)) ? 0.6 : 1;
  }

  _insideRoom(point, room) {
    if (!this._onLevel(room, point.level ?? this.player.level)) return false;
    const cell = cellOf(point);
    return room.cells?.some((entry) => entry.x === cell.x && entry.z === cell.z)
      ?? distance(point, room) <= room.radius;
  }

  _isSanctuary(point) {
    return this.rooms.some((room) => room.type === 'sanctuary' && this._insideRoom(point, room));
  }

  _updateInteractions(dt, moved) {
    const action = this.activeInteraction;
    if (!action) return;
    const objective = this.objectives.find((entry) => entry.id === action.id);
    if (!objective || !this._onLevel(objective) || moved || distance(this.player, objective) > 2) {
      this.activeInteraction = null;
      this._message('Reparatur unterbrochen. Drücke E am Mechanismus, um neu zu beginnen.');
      return;
    }
    action.progress = Math.min(action.duration, action.progress + dt);
    this.noise = this.player.noise = Math.max(0.65, this.noise);
    if (action.progress + EPSILON >= action.duration) {
      objective.completed = true;
      this.activeInteraction = null;
      this._addJournal('Die vergessene Maschinerie erwacht. Ihre Räder versorgen das Portal.');
      this.events.push({ type: 'mission', text: `${objective.label} repariert · ${this.missionProgress.completed}/${this.objectives.length}` });
    }
  }

  _updateEquipment(dt) {
    for (const item of this.inventory) {
      item.cooldown = Math.max(0, item.cooldown - dt);
      if (item.reloadRemaining > 0) {
        item.reloadRemaining = Math.max(0, item.reloadRemaining - dt);
        if (item.reloadRemaining <= EPSILON) {
          item.reloadRemaining = 0;
          item.magazine = Math.min(30, item.charges);
          this.events.push({ type: 'reload', complete: true, text: 'Maschinengewehr nachgeladen.' });
        }
      }
      item.heat = Math.max(0, item.heat - dt * 0.18);
      if (item.overheated && item.heat <= 0.35) item.overheated = false;
    }
    for (const collection of [this.flares, this.decoys]) {
      for (const item of collection) { item.age += dt; item.remaining -= dt; }
      for (let index = collection.length - 1; index >= 0; index -= 1) {
        if (collection[index].remaining <= 0) collection.splice(index, 1);
      }
    }
    for (const effect of this.weaponEffects) effect.age += dt;
    this.weaponEffects = this.weaponEffects.filter((effect) => effect.age < effect.duration);
    this.compassRemaining = Math.max(0, this.compassRemaining - dt);
    if (this.compassRemaining === 0) this.compassPath = [];
  }

  _updateRooms(dt) {
    for (const ally of this.allies) ally.cooldown = Math.max(0, ally.cooldown - dt);
    for (const room of this.rooms) {
      room.restCooldown = Math.max(0, room.restCooldown - dt);
      if (!this._insideRoom(this.player, room)) continue;
      if (!room.discovered) {
        room.discovered = true;
        // The starting sanctuary is introduced in the briefing, without a recurring toast.
        if (room.type !== 'sanctuary') {
          this._message(`${room.name} entdeckt.`);
          this._addJournal(`${this.biome.name}: ${room.name} entdeckt.`);
        }
      }
      if (room.type === 'sanctuary') this.player.health = Math.min(100, this.player.health + 5 * dt);
    }
  }

  _updateHazards(dt) {
    if (this.config.danger === 'calm') return;
    for (const hazard of this.hazards) {
      if (!this._onLevel(hazard)) continue;
      hazard.cooldown = Math.max(0, (hazard.cooldown ?? 0) - dt);
      if (hazard.disabled) continue;
      const close = distance(hazard, this.player) <= hazard.radius + 1.2;
      if (!hazard.warning && !hazard.active && hazard.cooldown === 0 && close && !this.inSanctuary) {
        hazard.warning = true;
        hazard.remaining = 1.8;
        this._message(hazard.type === 'gas' ? 'Gas zischt aus dem Boden – verlasse die grüne Wolke!'
          : hazard.type === 'thorns' ? 'Die Dornen bewegen sich – halte Abstand!' : 'Die Bodenplatten knacken – weiche der Falle aus!');
      }
      if (hazard.warning || hazard.active) {
        hazard.remaining -= dt;
        if (hazard.remaining <= 0) {
          if (hazard.warning) { hazard.warning = false; hazard.active = true; hazard.remaining = 3.2; }
          else { hazard.active = false; hazard.cooldown = 5; if (hazard.once) hazard.disabled = true; }
        }
      }
      if (hazard.active && distance(hazard, this.player) <= hazard.radius
        && this._lineOfSight(hazard, this.player)) {
        this._damagePlayer(hazard.type === 'gas' ? 8 : hazard.type === 'thorns' ? 10 : 16, 'hazard');
      }
    }
    if (this.worldEvent?.type === 'gas' && this.worldEvent.phase === 'active' && !this.inSanctuary) {
      // Event gas remains localized to clearly marked mine vents, allowing safe routes.
      if (this.hazards.some((hazard) => this._onLevel(hazard) && hazard.type === 'gas' && distance(hazard, this.player) <= hazard.radius + 1.4
        && this._lineOfSight(hazard, this.player))) this._damagePlayer(8, 'gas');
    }
  }

  _spawnIfDue() {
    if (this.elapsed + EPSILON < this._nextSpawn) return;
    this._nextSpawn += this._danger.spawnEvery;
    const active = this.monsters.filter((monster) => this._onLevel(monster));
    const count = Math.min(this._danger.wave ?? 0, this._danger.cap - active.length);
    if (count <= 0) return;
    // One breadth-first traversal gives actual corridor distances, so even the
    // largest maze produces encounters in the player's part of the labyrinth.
    const start = cellOf(this.player);
    if (!walkable(this.maze, start.x, start.z)) return;
    const queue = [{ ...start, steps: 0 }];
    const visited = new Set([keyOf(start)]);
    const candidates = [];
    const reserved = new Set([this.maze.start, this.maze.exit,
      ...this.objectives.filter((objective) => this._onLevel(objective)).map(cellOf)].map(keyOf));
    for (let index = 0; index < queue.length; index += 1) {
      const cell = queue[index];
      const point = worldOf(cell);
      if (cell.steps >= this._danger.distance && !this._isSanctuary(point)
        && distance(point, this.player) >= CELL * 3
        && !this.ladders.some((ladder) => (ladder.fromLevel === this.player.level || ladder.toLevel === this.player.level)
          && distance(point, ladder) < 2.2)) candidates.push({ ...cell, point });
      for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const next = { x: cell.x + dx, z: cell.z + dz, steps: cell.steps + 1 };
        const key = keyOf(next);
        if (visited.has(key) || !walkable(this.maze, next.x, next.z)) continue;
        visited.add(key);
        queue.push(next);
      }
    }
    for (let member = 0; member < count; member += 1) {
      const available = candidates.filter(({ point }) => !active.some((monster) => distance(point, monster) < CELL * 1.5));
      if (!available.length) break;
      let pool = available.filter((cell) => cell.steps <= this._danger.nearbyDistance);
      // A busy local region may fill up. Expand only to the next reachable
      // band instead of scattering replacements across an enormous map.
      if (!pool.length) pool = available.filter((cell) => cell.steps <= available[0].steps + 8);
      const unreserved = pool.filter((cell) => !reserved.has(keyOf(cell)));
      if (unreserved.length) pool = unreserved;
      const unseen = pool.filter(({ point }) => !this._seen(point));
      if (unseen.length) pool = unseen;
      const cell = pool[Math.floor(this._rng() * pool.length)];
      const id = this._nextMonsterId++;
      const types = this.terrain ? ['wolf', 'orc', 'wolf'] : ['listener', 'shade', 'watcher'];
      const type = types[(id - 1) % types.length];
      const monster = { id, type, ...worldOf(cell), level: this.player.level, y: this._floorAt(cell.x * CELL, cell.z * CELL), age: 0, health: ENEMIES[type].health,
        maxHealth: ENEMIES[type].health, state: 'patrol', memory: 0, attackCooldown: 0 };
      this.monsters.push(monster);
      active.push(monster);
      const hint = type === 'wolf' ? 'Seine roten Augen sehen dich im Dunkeln. Halte Abstand von seinen Fängen.'
        : type === 'orc' ? 'Seine Rüstung hält viel aus. Nutze die Weite der Waldwege.' : type === 'listener' ? 'Er hört Schritte und geworfene Steine.'
        : type === 'shade' ? 'Deine Lampe und Leuchtfackeln halten ihn fern.' : 'Sie bewegt sich nur, solange du sie nicht ansiehst.';
      this.events.push({ type: 'spawn', id, x: monster.x, z: monster.z, level: monster.level, enemy: type,
        text: `${ENEMIES[type].name} ist erwacht. ${hint}` });
    }
  }

  _seen(point, maxDistance = 28, cone = 0.65) {
    if (!this._onLevel(point)) return false;
    const dx = point.x - this.player.x;
    const dz = point.z - this.player.z;
    const separation = Math.hypot(dx, dz);
    if (separation > maxDistance) return false;
    const base = (point.y ?? this._floorAt(point.x, point.z)) - this.player.y;
    const lowerAngle = Math.atan2(base + 0.1 - 1.72, Math.max(0.01, separation));
    const upperAngle = Math.atan2(base + (point.type === 'wolf' ? 1.45 : 2.35) - 1.72, Math.max(0.01, separation));
    const halfVerticalFov = 35 * Math.PI / 180;
    if (this._view.pitch - halfVerticalFov > upperAngle
      || this._view.pitch + halfVerticalFov < lowerAngle) return false;
    const dot = separation < 0.01 ? 1 : (-Math.sin(this._view.yaw) * dx - Math.cos(this._view.yaw) * dz) / separation;
    return dot > cone && this._lineOfSight(this.player, point);
  }

  _moveMonsters(dt) {
    for (let index = this.monsters.length - 1; index >= 0; index -= 1) {
      const monster = this.monsters[index];
      if (!this._onLevel(monster)) continue;
      monster.type ??= 'listener';
      monster.health ??= ENEMIES[monster.type].health;
      monster.maxHealth ??= ENEMIES[monster.type].health;
      monster.age += dt;
      monster.hitFlash = Math.max(0, (monster.hitFlash ?? 0) - dt);
      monster.memory = Math.max(0, (monster.memory ?? 0) - dt);
      monster.attackCooldown = Math.max(0, (monster.attackCooldown ?? 0) - dt);
      if (monster.age >= 90) { this._monsterPaths.delete(monster.id); this.monsters.splice(index, 1); continue; }
      let state = this._monsterPaths.get(monster.id);
      if (!state) { state = { waypoints: [], refreshIn: 0, target: null }; this._monsterPaths.set(monster.id, state); }
      let target = null;
      let speed = this._danger.speed * ENEMIES[monster.type].speed;
      const nearFlare = this.flares.find((flare) => distance(monster, flare) < 8 && this._lineOfSight(monster, flare));
      const illuminated = this._view.light && this._seen(monster, 17, 0.77);
      if (monster.type === 'watcher' && this._seen(monster, 32, 0.65)) {
        monster.state = 'frozen';
        continue;
      }
      if (monster.type === 'shade' && (illuminated || nearFlare)) {
        const source = nearFlare ?? this.player;
        const current = cellOf(monster);
        const options = this._floors.filter((cell) => Math.abs(cell.x - current.x) + Math.abs(cell.z - current.z) <= 3
          && !this._isSanctuary(worldOf(cell))
          && distance(worldOf(cell), source) > distance(monster, source) + 0.2);
        options.sort((a, b) => distance(worldOf(b), source) - distance(worldOf(a), source));
        target = options[0] ? worldOf(options[0]) : monster;
        monster.state = 'repelled';
        monster.memory = 0;
        speed *= 1.2;
      } else {
        const decoy = this.decoys.find((entry) => this._onLevel(entry) && entry.age >= entry.flightDuration
          && (findPath(this.maze, cellOf(monster), cellOf(entry)).length - 1) * CELL <= 38);
        const soundRange = monster.type === 'wolf' && distance(monster, this.player) < 13 ? 18 : this.noise >= 0.9 ? 31 : this.noise >= 0.6 ? 18 : this.noise > 0.1 ? 8 : this.noise > 0 ? 2.5 : 0;
        const hearsPlayer = soundRange > 0 && distance(monster, this.player) < soundRange
          && (findPath(this.maze, cellOf(monster), cellOf(this.player)).length - 1) * CELL <= soundRange;
        const seesPlayer = monster.type !== 'listener' && distance(monster, this.player) < 23
          && this._lineOfSight(monster, this.player);
        if (monster.type === 'listener' && decoy) {
          target = decoy; monster.state = 'investigating'; monster.lastKnown = { x: decoy.x, z: decoy.z }; monster.memory = 6;
        } else if (!this.inSanctuary && (hearsPlayer || seesPlayer)) {
          target = this.player; monster.state = 'hunting'; monster.lastKnown = { x: this.player.x, z: this.player.z }; monster.memory = 7;
        } else if (monster.memory > 0 && monster.lastKnown && !this._isSanctuary(monster.lastKnown)) {
          target = monster.lastKnown; monster.state = 'searching';
        } else {
          monster.state = 'patrol';
          if (!monster.patrolTarget || distance(monster, monster.patrolTarget) < 0.5) {
            const candidates = this._floors.filter((cell) => !this._isSanctuary(worldOf(cell)));
            monster.patrolTarget = worldOf(candidates[Math.floor(this._rng() * candidates.length)] ?? cellOf(monster));
          }
          target = monster.patrolTarget;
          speed *= 0.55;
        }
      }
      if (monster.state === 'repelled' && distance(monster, target) > 0.1 && this._lineOfSight(monster, target)) {
        // Break an existing chase immediately when light strikes the shade.
        const separation = distance(monster, target);
        const amount = Math.min(speed * dt, separation);
        state.waypoints = []; state.refreshIn = 0;
        this._move(monster, (target.x - monster.x) / separation * amount,
          (target.z - monster.z) / separation * amount, 0.32, true);
      } else this._followPath(monster, state, target, speed * dt, dt, true);
      if (monster.state !== 'repelled' && !this.inSanctuary && distance(monster, this.player) < 0.92
        && this._lineOfSight(monster, this.player) && monster.attackCooldown === 0) {
        this._damagePlayer(monster.type === 'orc' ? 38 : monster.type === 'wolf' ? 22 : monster.type === 'watcher' ? 34 : 25, 'monster', monster.id);
        monster.attackCooldown = monster.type === 'wolf' ? 1.1 : monster.type === 'orc' ? 1.9 : 1.6;
        monster.state = 'attacking';
      }
    }
  }

  _followPath(body, state, target, travel, dt, avoidSanctuary = false) {
    if (!target) return;
    state.refreshIn -= dt;
    const targetCell = cellOf(target);
    const targetKey = keyOf(targetCell);
    if (state.refreshIn <= 0 || state.target !== targetKey) {
      // Retain the current cell edge while replanning, preventing turn-back oscillation.
      const origin = state.waypoints.length ? cellOf(state.waypoints[0]) : cellOf(body);
      state.waypoints = findPath(this.maze, origin, targetCell).map(worldOf);
      if (state.waypoints.length && distance(body, state.waypoints[0]) < EPSILON) state.waypoints.shift();
      state.refreshIn = 0.65;
      state.target = targetKey;
    }
    while (travel > EPSILON) {
      let next = state.waypoints[0];
      if (!next) {
        if (keyOf(cellOf(body)) !== targetKey) break;
        next = target;
      }
      const separation = distance(body, next);
      if (separation < EPSILON) {
        if (state.waypoints.length) { state.waypoints.shift(); continue; }
        break;
      }
      const amount = Math.min(travel, separation);
      const moved = this._move(body, (next.x - body.x) / separation * amount,
        (next.z - body.z) / separation * amount, 0.32, avoidSanctuary);
      travel -= amount;
      if (!moved) { state.refreshIn = 0; state.waypoints = []; break; }
      if (state.waypoints.length && distance(body, next) < EPSILON) state.waypoints.shift();
    }
  }

  _moveRescue(dt) {
    if (!this.rescue?.following || this.rescue.rescued || !this._onLevel(this.rescue)) return;
    const separation = distance(this.rescue, this.player);
    const wasWaiting = this.rescue.waiting;
    this.rescue.waiting = separation > 22;
    if (this.rescue.waiting && !wasWaiting) this._message('Der Forscher ist zurückgeblieben. Kehre zu ihm zurück.');
    if (this.rescue.waiting || separation < 1.2) return;
    this._followPath(this.rescue, this._rescuePath, this.player, 6.1 * dt, dt);
    const objective = this.objectives.find((entry) => entry.type === 'survivor');
    if (objective) Object.assign(objective, { x: this.rescue.x, z: this.rescue.z, y: this.rescue.y, level: this.rescue.level });
  }

  _damageMonster(monster, amount, weapon) {
    monster.health ??= ENEMIES[monster.type ?? 'listener'].health;
    monster.health = Math.max(0, monster.health - amount);
    monster.hitFlash = 0.2;
    monster.lastKnown = { x: this.player.x, z: this.player.z };
    monster.memory = 7;
    if (monster.health <= 0) {
      const index = this.monsters.indexOf(monster);
      if (index >= 0) this.monsters.splice(index, 1);
      this._monsterPaths.delete(monster.id);
      this.events.push({ type: 'monster-defeated', monsterId: monster.id, weapon,
        text: `${ENEMIES[monster.type ?? 'listener'].name} besiegt. Weitere Kreaturen können erwachen.` });
    }
  }

  _damagePlayer(amount, source, monsterId) {
    if (amount <= 0 || this.status !== 'playing' || this.config.danger === 'calm' || this.inSanctuary || this.climbing || this._invulnerable > 0) return false;
    this.player.health = Math.max(0, this.player.health - amount);
    this._invulnerable = 1.1;
    this.activeInteraction = null;
    this.events.push({ type: 'damage', amount, source, monsterId,
      text: source === 'rocket' ? 'Zu nah an der Explosion! Raketen brauchen Sicherheitsabstand.'
        : source === 'monster' ? 'Getroffen! Suche Abstand, Licht oder einen Schutzraum.' : 'Verletzt! Verlasse die Gefahrenzone.' });
    if (this.player.health <= 0) {
      this.status = 'lost';
      this.events.push({ type: 'lose', monsterId, source, elapsed: this.elapsed });
    }
    return true;
  }

  _aim(yaw, pitch) {
    const angle = finite(yaw);
    const elevation = clamp(finite(pitch), -1.45, 1.45);
    return { x: -Math.sin(angle) * Math.cos(elevation), z: -Math.cos(angle) * Math.cos(elevation), y: Math.sin(elevation) };
  }

  _lineOfSight(from, to) {
    const level = from.level ?? this.player.level;
    if (!this._onLevel(to, level)) return false;
    const maze = this.levels[level]?.maze ?? this.maze;
    const separation = distance(from, to);
    const steps = Math.max(1, Math.ceil(separation / 0.22));
    const sightY = (entity) => (entity.y ?? this._floorAt(entity.x, entity.z, level))
      + (entity.type === 'rocket' ? 0 : entity.type === 'wolf' ? 0.75 : 1.35);
    const fromY = sightY(from);
    const toY = sightY(to);
    for (let step = 0; step <= steps; step += 1) {
      const amount = step / steps;
      const x = from.x + (to.x - from.x) * amount;
      const z = from.z + (to.z - from.z) * amount;
      const cell = cellOf({ x, z });
      if (this.terrain) {
        const y = fromY + (toY - fromY) * amount;
        if (forestSolidAt(maze, this.terrain, x, y, z, 0.02)) return false;
      } else if (!walkable(maze, cell.x, cell.z)) return false;
    }
    return true;
  }

  /** The cursor and hitscan weapons use the same wall/creature intersections. */
  getAimTarget(origin, direction, maxDistance = 55) {
    const ray = this._validatedRay(origin, direction);
    if (!ray || !Number.isFinite(maxDistance) || maxDistance <= 0) return null;
    const hit = this._traceAim(ray.origin, ray.direction, Math.min(maxDistance, 200));
    const { monster, ...result } = hit;
    return { ...result, ...(monster ? { monsterId: monster.id } : {}) };
  }

  _validatedRay(origin, direction) {
    const vector = (value) => value && typeof value === 'object'
      && ['x', 'y', 'z'].every((axis) => Number.isFinite(value[axis]));
    if (!vector(origin) || !vector(direction)) return null;
    const length = Math.hypot(direction.x, direction.y, direction.z);
    if (!Number.isFinite(length) || length < EPSILON) return null;
    return { origin: { x: origin.x, y: origin.y, z: origin.z, level: this.player.level },
      direction: { x: direction.x / length, y: direction.y / length, z: direction.z / length } };
  }

  _firingRay(shot, yaw, pitch, weapon) {
    const fallback = { origin: { x: this.player.x, y: this.player.y + (weapon === 'rocket' ? 1.42 : 1.48), z: this.player.z },
      direction: this._aim(yaw, pitch) };
    const source = shot === null ? fallback : shot;
    const ray = this._validatedRay(source?.origin, source?.direction);
    if (!ray) return null;
    const eye = { x: this.player.x, y: this.player.y + 1.72, z: this.player.z, level: this.player.level };
    const delta = { x: ray.origin.x - eye.x, y: ray.origin.y - eye.y, z: ray.origin.z - eye.z };
    const separation = Math.hypot(delta.x, delta.y, delta.z);
    if (separation > 2.5) return null;
    if (separation > EPSILON) {
      const toMuzzle = { x: delta.x / separation, y: delta.y / separation, z: delta.z / separation };
      const obstruction = this._raycast3D(eye, toMuzzle, separation);
      if (obstruction.hit) ray.obstruction = obstruction;
    }
    return ray;
  }

  _traceAim(origin, direction, maxDistance) {
    const surface = this._raycast3D(origin, direction, maxDistance);
    let hit = null;
    let hitDistance = surface.distance;
    for (const monster of this.monsters) {
      if (!this._onLevel(monster)) continue;
      const dx = monster.x - origin.x;
      const dy = (monster.y ?? this.player.y) + (ENEMIES[monster.type]?.hitHeight ?? 1.25) - origin.y;
      const dz = monster.z - origin.z;
      const projection = dx * direction.x + dy * direction.y + dz * direction.z;
      const radius = ENEMIES[monster.type]?.hitRadius ?? (monster.type === 'shade' ? 0.72 : 0.8);
      const perpendicularSq = Math.max(0, dx * dx + dy * dy + dz * dz - projection * projection);
      if (perpendicularSq > radius * radius) continue;
      const halfChord = Math.sqrt(radius * radius - perpendicularSq);
      if (projection + halfChord < 0) continue;
      const front = Math.max(0, projection - halfChord);
      if (front < hitDistance) { hitDistance = front; hit = monster; }
    }
    return { x: origin.x + direction.x * hitDistance, y: origin.y + direction.y * hitDistance,
      z: origin.z + direction.z * hitDistance, distance: hitDistance,
      hit: Boolean(hit) || surface.hit, ...(hit ? { monster: hit } : {}) };
  }

  _raycastGround(from, direction, maxDistance) {
    let point = { x: from.x, z: from.z };
    const magnitude = Math.hypot(direction.x, direction.z) || 1;
    for (let length = 0.1; length <= maxDistance; length += 0.1) {
      const next = { x: from.x + direction.x / magnitude * length, z: from.z + direction.z / magnitude * length };
      if (!this._canOccupy(next.x, next.z, 0.12)) break;
      point = next;
    }
    return point;
  }

  _raycast3D(from, direction, maxDistance) {
    const level = from.level ?? this.player.level;
    const pointAt = (length) => ({ x: from.x + direction.x * length,
      y: from.y + direction.y * length, z: from.z + direction.z * length });
    const blocked = (point) => this.terrain ? forestSolidAt(this.maze, this.terrain, point.x, point.y, point.z)
      : !this._canOccupy(point.x, point.z, 0.05, level)
        || point.y <= this._floorAt(point.x, point.z, level) + 0.12
        || point.y >= this._ceilingAt(point.x, point.z, level);
    if (blocked(from)) return { ...pointAt(0), distance: 0, hit: true };
    for (let previous = 0; previous < maxDistance;) {
      const length = Math.min(previous + 0.08, maxDistance);
      if (blocked(pointAt(length))) {
        let near = previous;
        let far = length;
        for (let refinement = 0; refinement < 8; refinement += 1) {
          const middle = (near + far) / 2;
          if (blocked(pointAt(middle))) far = middle; else near = middle;
        }
        return { ...pointAt(near), distance: near, hit: true };
      }
      previous = length;
    }
    return { ...pointAt(maxDistance), distance: maxDistance, hit: false };
  }

  _updateProjectiles(dt) {
    for (let index = this.projectiles.length - 1; index >= 0; index -= 1) {
      const rocket = this.projectiles[index];
      if (!this._onLevel(rocket)) continue;
      if (rocket.blockedImpact) {
        this._explode({ ...rocket, ...rocket.blockedImpact });
        this.projectiles.splice(index, 1);
        continue;
      }
      const base = (rocket.level ?? this.player.level) * LEVEL_HEIGHT;
      rocket.age += dt;
      let collided = false;
      const steps = Math.ceil(18 * dt / 0.15);
      for (let segment = 0; segment < steps; segment += 1) {
        const next = { x: rocket.x + rocket.dx * 18 * dt / steps,
          z: rocket.z + rocket.dz * 18 * dt / steps, y: rocket.y + rocket.dy * 18 * dt / steps };
        if (this.terrain ? forestSolidAt(this.maze, this.terrain, next.x, next.y, next.z, 0.13)
          : !this._canOccupy(next.x, next.z, 0.13) || next.y < this._floorAt(next.x, next.z) + 0.12
            || next.y > this._ceilingAt(next.x, next.z) - 0.03) { collided = true; break; }
        Object.assign(rocket, next);
        if (this.monsters.some((monster) => this._onLevel(monster) && Math.hypot(monster.x - rocket.x, monster.z - rocket.z, (monster.y ?? base) + (ENEMIES[monster.type]?.hitHeight ?? 1.25) - rocket.y) < (ENEMIES[monster.type]?.hitRadius ?? 0.8))) {
          collided = true; break;
        }
      }
      if (collided || rocket.age >= rocket.duration) {
        this._explode(rocket);
        this.projectiles.splice(index, 1);
      }
    }
  }

  _explode(rocket) {
    const radius = 5.2;
    this.weaponEffects.push({ id: this._nextItemId++, type: 'explosion', x: rocket.x, z: rocket.z,
      y: rocket.y, level: rocket.level ?? this.player.level, radius, age: 0, duration: 0.7 });
    for (const monster of [...this.monsters]) {
      const separation = Math.hypot(monster.x - rocket.x, monster.z - rocket.z, (monster.y ?? this.player.y) + (ENEMIES[monster.type]?.hitHeight ?? 1.25) - rocket.y);
      if (separation < radius && this._lineOfSight(rocket, monster)) {
        this._damageMonster(monster, 180 * (1 - separation / (radius * 1.25)), 'rocket');
      }
    }
    const playerDistance = Math.hypot(this.player.x - rocket.x, this.player.z - rocket.z, this.player.y + 1.25 - rocket.y);
    if (playerDistance < radius && this._lineOfSight(rocket, this.player)) {
      this._damagePlayer(Math.round(60 * (1 - playerDistance / radius)), 'rocket');
    }
    this._soundPulse = 2;
    this.events.push({ type: 'explosion', x: rocket.x, z: rocket.z, radius });
  }

  _updateWorldEvent(dt) {
    if (this.config.danger === 'calm') return;
    if (!this.worldEvent) {
      if (this.elapsed < this._nextWorldEvent) return;
      const types = this.terrain ? ['blackout'] : this.config.biome === 'mine' ? ['gas', 'blackout', 'shift']
        : this.config.biome === 'ruins' ? ['flood', 'shift', 'blackout'] : ['shift', 'blackout', 'flood'];
      this.queueWorldEvent(types[this._eventIndex++ % types.length]);
      return;
    }
    this.worldEvent.remaining -= dt;
    if (this.worldEvent.remaining > 0) return;
    if (this.worldEvent.phase === 'warning') {
      this.worldEvent.phase = 'active';
      this.worldEvent.remaining = this.worldEvent.duration;
      if (this.worldEvent.type === 'shift') {
        this.worldEvent.changedCells = this._shiftWalls();
        this.worldEvent.label = this.worldEvent.changedCells.length ? 'Neue Gänge haben sich geöffnet' : 'Das Mauerwerk kommt zur Ruhe';
      }
      this.events.push({ type: 'world-active', event: this.worldEvent.type, text: this.worldEvent.label });
    } else {
      this._message('Das Labyrinth kommt zur Ruhe.');
      this.worldEvent = null;
      this._nextWorldEvent = this.elapsed + (this.config.danger === 'nightmare' ? 32 : 45);
    }
  }

  /** Also used by deterministic scenario tests; warning always precedes activation. */
  queueWorldEvent(type) {
    if (this.terrain && type !== 'blackout') return false;
    if (!Object.hasOwn(EVENT_LABELS, type) || this.worldEvent || this.config.danger === 'calm') return false;
    const duration = type === 'shift' ? 5 : type === 'blackout' ? 17 : 20;
    this.worldEvent = { type, level: this.player.level, phase: 'warning', remaining: 8, duration, label: EVENT_LABELS[type] };
    const instruction = type === 'shift' ? 'Halte dich von beweglichen Mauern fern; alle Ziele bleiben erreichbar.'
      : type === 'gas' ? 'Meide die markierten Gasquellen; der Schutzraum bleibt sicher.'
        : type === 'flood' ? 'Wasser verlangsamt deine Schritte. Plane einen kurzen Fluchtweg.' : 'Deine eigene Lampe funktioniert weiter.';
    this.events.push({ type: 'world-warning', event: type, text: `${EVENT_LABELS[type]} in 8 Sekunden. ${instruction}` });
    return true;
  }

  _shiftWalls() {
    if (this.terrain) return [];
    const protectedCells = new Set();
    const protect = (point, radius = 0) => {
      if (!this._onLevel(point)) return;
      const cell = cellOf(point);
      for (let z = -radius; z <= radius; z += 1) for (let x = -radius; x <= radius; x += 1) {
        protectedCells.add(`${cell.x + x},${cell.z + z}`);
      }
    };
    for (const room of this.rooms.filter((entry) => this._onLevel(entry))) for (const cell of room.cells ?? []) protectedCells.add(keyOf(cell));
    for (const ladder of this.ladders) {
      if (ladder.fromLevel === this.player.level || ladder.toLevel === this.player.level) protect(ladder, 1);
    }
    protect(worldOf(this.maze.start)); protect(worldOf(this.maze.exit)); protect(this.player, 1);
    for (const entity of [...this.monsters, ...this.objectives, ...this.treasures, ...this.hazards,
      ...this.markers, ...this.flares, ...this.decoys, ...this.projectiles, ...(this.rescue ? [this.rescue] : [])]) protect(entity, 1);
    const opens = [];
    const closes = [];
    for (let z = 1; z < this.maze.size - 1; z += 1) for (let x = 1; x < this.maze.size - 1; x += 1) {
      if (protectedCells.has(`${x},${z}`)) continue;
      if (walkable(this.maze, x, z)) closes.push({ x, z });
      else if ((walkable(this.maze, x - 1, z) && walkable(this.maze, x + 1, z))
        || (walkable(this.maze, x, z - 1) && walkable(this.maze, x, z + 1))) opens.push({ x, z });
    }
    const changes = [];
    if (opens.length) {
      const cell = opens[Math.floor(this._rng() * opens.length)];
      this.maze.grid[cell.z][cell.x] = 0;
      changes.push({ ...cell, wall: false });
    }
    const initialFloorCount = reachableCells(this.maze).length;
    const offset = Math.floor(this._rng() * Math.max(1, closes.length));
    for (let index = 0; index < closes.length; index += 1) {
      const cell = closes[(index + offset) % closes.length];
      this.maze.grid[cell.z][cell.x] = 1;
      if (reachableCells(this.maze).length === initialFloorCount - 1) {
        changes.push({ ...cell, wall: true });
        break;
      }
      this.maze.grid[cell.z][cell.x] = 0;
    }
    if (changes.length) {
      this.mapRevision += 1;
      this._floors = reachableCells(this.maze);
      this._monsterPaths.clear();
      this._rescuePath = { waypoints: [], refreshIn: 0 };
      if (this.compassRemaining > 0) this._revealRoute();
    }
    return changes;
  }

  _revealRoute() {
    let targets = this.objectives.filter((objective) => !objective.completed);
    if (!targets.length || this.rescue?.following) targets = [{ ...worldOf(this.exit), level: 0 }];
    let local = targets.filter((target) => this._onLevel(target));
    this.compassTarget = null;
    if (!local.length && targets.length) {
      targets.sort((a, b) => Math.abs(a.level - this.player.level) - Math.abs(b.level - this.player.level));
      const direction = Math.sign(targets[0].level - this.player.level);
      local = this.ladders.filter((ladder) => direction > 0
        ? ladder.fromLevel === this.player.level : ladder.toLevel === this.player.level);
      this.compassTarget = { type: 'ladder', level: this.player.level + direction, targetLevel: targets[0].level };
    }
    const routes = local.map((target) => findPath(this.maze, cellOf(this.player), cellOf(target))).filter((route) => route.length);
    routes.sort((a, b) => a.length - b.length);
    this.compassPath = routes[0] ?? [];
    this.compassRemaining = 35;
    for (const cell of this.compassPath) this.explored.add(keyOf(cell));
  }

  _explore() {
    const origin = cellOf(this.player);
    const reveal = (x, z) => {
      if (x >= 0 && z >= 0 && x < this.maze.size && z < this.maze.size) this.explored.add(`${x},${z}`);
    };
    reveal(origin.x, origin.z);
    for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      for (let length = 1; length <= 2; length += 1) {
        const x = origin.x + dx * length;
        const z = origin.z + dz * length;
        reveal(x, z);
        if (!walkable(this.maze, x, z)) break;
      }
    }
  }

  _addJournal(text) {
    if (this.journal.includes(text)) return;
    this.journal.push(text);
    this.events.push({ type: 'journal', text });
  }

  _message(text) { this.events.push({ type: 'message', text }); }
  _weaponNotice(text) {
    if (this.elapsed - this._weaponNoticeAt < 1) return;
    this._weaponNoticeAt = this.elapsed;
    this._message(text);
  }

  _checkVictory() {
    if (this.status !== 'playing' || this.climbing || this.player.level !== 0) return;
    const exit = worldOf(this.exit);
    if (this.rescue?.following && this._onLevel(this.rescue, 0) && distance(this.rescue, exit) <= 2.8 && distance(this.player, exit) <= 3) {
      this.rescue.rescued = true;
      const objective = this.objectives.find((entry) => entry.type === 'survivor');
      if (objective) objective.completed = true;
    }
    if (this.missionProgress.ready && distance(this.player, exit) <= 1.2) {
      this.status = 'won';
      this.events.push({ type: 'win', elapsed: this.elapsed });
    }
  }
}
