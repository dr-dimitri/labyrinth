import './style.css';
import { WorldRenderer } from './renderer.js';
import { GameSimulation, CELL } from './simulation.js';
import { findPath } from './maze.js';
import { AudioEngine } from './audio.js';
import { BIOMES, MISSIONS, TOOLS } from './expedition.js';
import { createProfile, normalizeProfile, getUnlocks, recordExpedition } from './progression.js';
import { moveAim, pointAim } from './aim-input.js';
import { getTerrainZone, getTerrainCave } from './forest-world.js';

const $ = id => document.getElementById(id);
const audio = new AudioEngine();
const keys = new Set(), mouseButtons = new Set(), pendingShots = new Set();
const PROFILE_KEY = 'nachtgang-profile-v1';
const SETTINGS_KEY = 'nachtgang-settings-v1';
const toolById = id => TOOLS.find(tool => tool.id === id);
let world, simulation, mode = 'menu', danger = 'normal', yaw = 0, pitch = 0, light = true;
let profile = createProfile(), journalReturnMode = 'menu';
let soundEnabled = false, soundPreference = null, volume = .55, sensitivity = .002;
let aim = {x:0,y:0}, hadPointerLock = false, lastTime = performance.now();
let messageUntil = 0, lastMapUpdate = 0, lastConfig, damageUntil = 0;
let previousBiome, dungeonLevels = 3;
const forestZones = {forest:'Dunkelwald',ravine:'Felsschlucht','cave-rock':'Tropfsteingrotte','cave-roots':'Wurzelhöhle'};
const regionName = (point) => getTerrainCave(simulation?.terrain,point.x,point.z)?.name || forestZones[getTerrainZone(simulation?.terrain,point.x,point.z)];
const descriptions = {calm:'Erkunden und ausprobieren. Keine Monster, kein Gefahrenschaden.', normal:'Bis zu 8 Gegner pro Ebene. Neue Wellen alle 9 Sekunden.', nightmare:'Bis zu 12 Gegner pro Ebene. Neue Wellen alle 6 Sekunden.'};
const unlockHints = {ruins:'Nach deiner ersten erfolgreichen Expedition', mine:'Ab 8 Fundstücken oder 3 erfolgreichen Expeditionen', flare:'Nach deiner ersten erfolgreichen Expedition', compass:'Ab 6 geborgenen Fundstücken'};

function showPlan(name, focus = false) {
  document.querySelectorAll('[data-plan]').forEach(button => {
    const selected = button.dataset.plan === name;
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
    $(`plan-${button.dataset.plan}`).classList.toggle('hidden', !selected);
    if (selected && focus) button.focus();
  });
}
function fillSelect(id, definitions, unlocked, fallback) {
  const select = $(id), previous = select.value;
  select.replaceChildren(...definitions.map(definition => {
    const option = document.createElement('option');
    option.value = definition.id;
    option.disabled = !unlocked.includes(definition.id);
    option.textContent = definition.name + (option.disabled ? ` · ${unlockHints[definition.id] || definition.unlockText || 'Gesperrt'}` : '');
    return option;
  }));
  select.value = unlocked.includes(previous) ? previous : fallback;
}
function refreshProgression() {
  const unlocked = getUnlocks(profile);
  fillSelect('biome', BIOMES, unlocked.biomes, 'catacombs');
  fillSelect('mission', MISSIONS, MISSIONS.map(item => item.id), 'seals');
  fillSelect('tool-0', TOOLS, unlocked.tools, 'machinegun');
  fillSelect('tool-1', TOOLS, unlocked.tools, 'rocket');
  $('profile-summary').textContent = `${profile.completedRuns} Rückkehrten · ${profile.earned} Fundstücke`;
  $('expedition-number').textContent = `N° ${String(profile.completedRuns + profile.failedRuns + 1).padStart(3, '0')}`;
}
function updatePlanner() {
  const biome = BIOMES.find(item => item.id === $('biome').value);
  const mission = MISSIONS.find(item => item.id === $('mission').value);
  const forest = biome.id === 'forest';
  if (forest) {
    if (previousBiome && previousBiome !== 'forest') dungeonLevels = Number($('levels').value);
    $('levels').value = '1';
  } else if (previousBiome === 'forest') $('levels').value = String(dungeonLevels);
  previousBiome = biome.id;
  $('levels').disabled = forest;
  document.querySelector('label[for="size"]').textContent = forest ? 'Waldgröße' : 'Größe pro Ebene';
  document.querySelector('label[for="levels"]').textContent = forest ? 'Gelände' : 'Stockwerke';
  $('levels').options[0].textContent = forest ? 'Wald & Tiefen' : '1 Ebene';
  $('biome-description').textContent = biome.description;
  $('mission-name').textContent = mission.name;
  $('mission-description').textContent = mission.briefing || mission.description;
  $('mission-exploration').textContent = forest
    ? 'Erkunde die Tropfsteingrotte und die Wurzelhöhle. In den Elfenlagern findest du Schutz und mit E frische Munition. Halte in den Höhlen nach verlorenen Truhen Ausschau.'
    : 'Löse das Runenrätsel der Bibliothek, entwässere die überflutete Halle und öffne die Schatzkammer. Das Heiligtum bietet Schutz und neue Kraft.';
  $('start-button').firstElementChild.textContent = forest ? 'DUNKELWALD BETRETEN' : 'LABYRINTH BETRETEN';
  for (let i = 0; i < 2; i++) {
    const tool = toolById($(`tool-${i}`).value);
    $(`tool-${i}-description`).textContent = tool.description;
    // A loadout contains two different items; one weapon cannot duplicate its ammunition.
    for (const option of $(`tool-${i}`).options) option.disabled = !getUnlocks(profile).tools.includes(option.value) || option.value === $(`tool-${1-i}`).value;
  }
  $('expedition-summary').textContent = `${biome.name} · ${forest ? 'Schlucht & 2 Höhlen' : `${$('levels').value} Ebenen`} · ${mission.name} · ${toolById($('tool-0').value).name} + ${toolById($('tool-1').value).name}`;
  saveSettings();
}
function paintRange(input) {
  const percent = (Number(input.value)-Number(input.min))/(Number(input.max)-Number(input.min))*100;
  input.style.background = `linear-gradient(to right, #bfd69c ${percent}%, #425444 ${percent}%)`;
}
function updateSettings() {
  $('size-value').textContent = `${$('size').value} × ${$('size').value}`;
  const complexity = Number($('complexity').value);
  $('complexity-value').textContent = complexity < 30 ? 'Überschaubar' : complexity < 70 ? 'Verschlungen' : 'Unerbittlich';
  document.querySelectorAll('.range').forEach(paintRange);
  document.querySelectorAll('[data-danger]').forEach(button => {
    const selected = button.dataset.danger === danger;
    button.classList.toggle('selected', selected);button.setAttribute('aria-pressed', String(selected));
  });
  $('danger-description').textContent = descriptions[danger];
  $('volume-value').textContent = `${Math.round(volume*100)} %`;
  $('sensitivity-value').textContent = `${$('sensitivity').value} %`;
  saveSettings();
}
function saveSettings() {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({worldVersion:2,dungeonLevels:$('biome').value === 'forest' ? dungeonLevels : Number($('levels').value),levels:Number($('levels').value),size:Number($('size').value),complexity:Number($('complexity').value),seed:$('seed').value,danger,volume,quality:$('quality').value,sensitivity:Number($('sensitivity').value),biome:$('biome').value,mission:$('mission').value,loadout:[$('tool-0').value,$('tool-1').value]}));
  } catch { /* Storage is optional. */ }
}
function saveProfile() {
  try { localStorage.setItem(PROFILE_KEY, JSON.stringify(profile)); }
  catch { showMessage('Der Fortschritt bleibt in dieser Sitzung erhalten. Lokales Speichern ist nicht verfügbar.', 6); }
}
function restoreSettings() {
  try { profile = normalizeProfile(JSON.parse(localStorage.getItem(PROFILE_KEY) || 'null')); } catch { profile = createProfile(); }
  refreshProgression();
  try {
    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || 'null');
    if (!saved) return;
    if (Number.isFinite(saved.size)) $('size').value = String(saved.worldVersion === 2 ? saved.size : Math.max(25,saved.size));
    if ([1,2,3].includes(saved.levels)) $('levels').value = String(saved.levels);
    if ([1,2,3].includes(saved.dungeonLevels)) dungeonLevels = saved.dungeonLevels;
    if (Number.isFinite(saved.complexity)) $('complexity').value = String(saved.complexity);
    if (typeof saved.seed === 'string') $('seed').value = saved.seed.slice(0,32);
    if (Object.hasOwn(descriptions, saved.danger)) danger = saved.danger;
    if (Number.isFinite(saved.volume)) volume = Math.max(0, Math.min(1, saved.volume));
    if (['high','balanced'].includes(saved.quality)) $('quality').value = saved.quality;
    if (Number.isFinite(saved.sensitivity)) $('sensitivity').value = String(saved.sensitivity);
    const unlocked = getUnlocks(profile);
    if (unlocked.biomes.includes(saved.biome)) $('biome').value = saved.biome;
    if (MISSIONS.some(item => item.id === saved.mission)) $('mission').value = saved.mission;
    if (Array.isArray(saved.loadout) && saved.loadout.length === 2 && saved.loadout[0] !== saved.loadout[1] && saved.loadout.every(id => unlocked.tools.includes(id))) saved.loadout.forEach((id,i) => {$(`tool-${i}`).value = id;});
    $('volume').value = String(volume*100);sensitivity = Number($('sensitivity').value)*.00004;
  } catch { /* Ignore obsolete preferences. */ }
}
function showMessage(text, seconds = 4) {
  $('message').textContent = text;messageUntil = performance.now()+seconds*1000;$('message').classList.add('visible');
}
function formatTime(seconds) { return `${Math.floor(seconds/60).toString().padStart(2,'0')}:${Math.floor(seconds%60).toString().padStart(2,'0')}`; }
function updateSoundButton() {
  $('sound-label').textContent = soundEnabled && volume > 0 ? 'TON AN' : 'TON AKTIVIEREN';
  $('sound-toggle').setAttribute('aria-pressed', String(soundEnabled && volume > 0));
}
async function enableAudio() {
  audio.setVolume(soundEnabled ? volume : 0);
  if (!await audio.start()) { soundEnabled = false;updateSoundButton(); }
}
function clearInput() { keys.clear();mouseButtons.clear();pendingShots.clear(); }
function updateCrosshair() {
  $('crosshair').style.left = `${(aim.x+1)*50}%`;
  $('crosshair').style.top = `${(1-aim.y)*50}%`;
}
function currentView(movement = {}) { return {yaw,pitch,light,aimX:aim.x,aimY:aim.y,...movement}; }
function captureMouse() {
  if (mode !== 'playing' || document.pointerLockElement) return;
  try {
    const request = world.renderer.domElement.requestPointerLock?.();
    request?.catch?.(() => {if (mode === 'playing') showMessage('Maus oder Trackpad bewegt das Fadenkreuz · ← / → drehen · Q / R feuern',4);});
  } catch { showMessage('Maus oder Trackpad bewegt das Fadenkreuz · ← / → drehen · Q / R feuern',4); }
}
function releaseMouse() { if (document.pointerLockElement) document.exitPointerLock(); }
function startGame(config) {
  $('start-button').disabled = true;
  try {
    lastConfig = config || {levels:Number($('levels').value),size:Number($('size').value),complexity:Number($('complexity').value),seed:$('seed').value.trim() || 'NACHT-0471',danger,biome:$('biome').value,mission:$('mission').value,loadout:[$('tool-0').value,$('tool-1').value]};
    saveSettings();simulation = new GameSimulation(lastConfig);world.showGame(simulation);
    const firstLadder = simulation.ladders?.find(ladder => ladder.fromLevel === 0);
    const guide = firstLadder || simulation.allies?.[0];
    const firstTarget = guide ? {x:Math.round(guide.x/CELL),z:Math.round(guide.z/CELL)} : simulation.maze.exit;
    const path = findPath(simulation.maze, simulation.maze.start, firstTarget);
    const next = path[1] || {x:1,z:2};yaw = Math.atan2(-(next.x-simulation.maze.start.x), -(next.z-simulation.maze.start.z));pitch = 0;light = true;clearInput();
    aim = {x:0,y:0};updateCrosshair();mode = 'playing';lastTime = performance.now();
    $('menu').classList.add('hidden');$('hud').classList.remove('hidden');
    for (const id of ['pause-screen','result-screen','map-panel']) $(id).classList.add('hidden');
    $('damage').style.opacity = '0';damageUntil = 0;
    soundEnabled = soundPreference !== false && volume > 0;audio.setPaused(false);audio.setThreat(0);void enableAudio();updateSoundButton();
    captureMouse();updateHud();
    showMessage(simulation.terrain ? 'Elfen versorgen dich mit Munition · E ansprechen · M Waldkarte · J Auftrag' : '← / → drehen · Maus / Trackpad zielen · Q / R feuern · E klettern',6);
  } catch (error) { showError(error); }
  finally { $('start-button').disabled = false; }
}
function pauseGame() {
  if (mode !== 'playing') return;
  mode = 'paused';clearInput();releaseMouse();audio.setPaused(true);$('pause-screen').classList.remove('hidden');$('resume-button').focus();
}
function resumeGame() {
  if (mode !== 'paused') return;
  mode = 'playing';clearInput();lastTime = performance.now();$('pause-screen').classList.add('hidden');audio.setPaused(false);void enableAudio();captureMouse();
}
function returnToMenu() {
  mode = 'menu';clearInput();releaseMouse();simulation = null;world.showMenu();
  for (const id of ['hud','pause-screen','result-screen']) $(id).classList.add('hidden');
  $('menu').classList.remove('hidden');$('damage').style.opacity = '0';audio.setThreat(0);audio.setPaused(false);
  refreshProgression();updatePlanner();updateSoundButton();$('start-button').focus();
}
function finishGame(won) {
  if (mode === 'result') return;
  mode = 'result';clearInput();releaseMouse();
  if (won) audio.playWin();else audio.playLose();audio.setThreat(0);
  const before = getUnlocks(profile), oldEarned = profile.earned;
  profile = recordExpedition(profile, simulation.result);saveProfile();
  const after = getUnlocks(profile);
  const newUnlocks = [...BIOMES.filter(item => after.biomes.includes(item.id) && !before.biomes.includes(item.id)), ...TOOLS.filter(item => after.tools.includes(item.id) && !before.tools.includes(item.id))];
  $('hud').classList.add('hidden');$('result-screen').classList.remove('hidden');
  $('result-kicker').textContent = won ? 'AUFTRAG ERFÜLLT · SCHÄTZE GEBORGEN' : 'DIE HALLEN HABEN DICH GEFUNDEN';
  $('result-title').textContent = won ? 'Zurück im Licht.' : 'Verschollen.';
  $('result-description').textContent = won ? 'Du hast deinen Auftrag erfüllt und die Nacht überlebt. Deine Funde ermöglichen neue Expeditionen.' : 'Deine getragenen Schätze bleiben zurück. Entdeckte Feldnotizen behältst du. Passe deine Ausrüstung an und versuche einen neuen Weg.';
  $('result-stats').replaceChildren();
  for (const [label,value] of [['ZEIT',formatTime(simulation.elapsed)],['AUFTRAG',`${simulation.missionProgress.completed} / ${simulation.missionProgress.total}`],['FUNDSTÜCKE',`+${profile.earned-oldEarned}`],['WELT-CODE',simulation.config.seed]]) {
    const item = document.createElement('div'), small = document.createElement('small');small.textContent = label;item.append(small,document.createTextNode(String(value)));$('result-stats').append(item);
  }
  $('result-rewards').textContent = newUnlocks.length ? `Neu freigeschaltet: ${newUnlocks.map(item => item.name).join(', ')}.` : `Deine Sammlung: ${profile.earned} Fundstücke · ${profile.completedRuns} erfolgreiche Expeditionen.`;
  $('retry-button').textContent = won ? 'DIESE WELT ERNEUT BETRETEN ↗' : 'NOCH EIN VERSUCH ↗';$('retry-button').focus();
}
function updateHud() {
  if (!simulation) return;
  const progress = simulation.missionProgress;
  $('relic-count').textContent = `${progress.completed} / ${progress.total}`;
  document.querySelectorAll('.relic-glyph').forEach((el,i) => {el.classList.toggle('hidden',i >= progress.total);el.classList.toggle('collected',i < progress.completed);el.textContent = i < progress.completed ? '◆' : '◇';});
  $('objective').textContent = progress.text;
  const currentLevel = simulation.player.level || 0, levelCount = simulation.levels?.length || 1;
  $('floor-status').textContent = simulation.terrain ? `${regionName(simulation.player).toUpperCase()} · TIEFE ${Math.max(0,-simulation.player.y).toFixed(1).replace('.',',')} m` : simulation.climbing ? `KLETTERE ZU EBENE ${simulation.climbing.toLevel+1} · ${Math.round(simulation.climbing.progress/simulation.climbing.duration*100)} %` : `EBENE ${currentLevel+1} / ${levelCount} · ${currentLevel === 0 ? 'ERDGESCHOSS · AUSGANG' : 'OBERGESCHOSS'}`;
  $('floor-status').classList.toggle('climbing',!!simulation.climbing);
  $('equipment-hud').classList.toggle('climbing',!!simulation.climbing);
  $('crosshair').classList.toggle('climbing',!!simulation.climbing);
  $('biome-label').textContent = `${simulation.biome?.name || 'NACHTGANG'} · ${simulation.mission?.name || ''}`.toUpperCase();
  $('timer').textContent = formatTime(simulation.elapsed);
  $('stamina-fill').style.width = `${simulation.player.stamina}%`;
  $('stamina-fill').style.background = simulation.player.stamina < 25 ? '#d6a36c' : '#d0ddb5';
  $('stamina-value').textContent = String(Math.ceil(simulation.player.stamina));
  $('health-fill').style.width = `${simulation.player.health}%`;
  $('health-value').textContent = String(Math.ceil(simulation.player.health));
  $('treasure-count').textContent = `◆ ${simulation.carriedTreasure}`;
  const noise = simulation.player.noise || 0;
  $('noise-label').textContent = noise > .7 ? 'SEHR LAUT' : noise > .25 ? 'HÖRBAR' : 'LEISE';
  const interaction = simulation.interaction;
  const action = simulation.climbing ? {...simulation.climbing,label:`${simulation.climbing.toLevel > simulation.climbing.fromLevel ? 'Aufstieg' : 'Abstieg'} · Ebene ${simulation.climbing.toLevel+1}`} : simulation.activeInteraction;
  $('interact').classList.toggle('hidden', !interaction && !action);
  $('interaction-label').textContent = action ? action.label : interaction?.label || '';
  $('interaction-description').textContent = action ? simulation.climbing ? 'Halte dich fest. Am Ende steigst du automatisch aus.' : 'Bleib am Mechanismus, bis die Reparatur abgeschlossen ist.' : interaction?.description || '';
  $('interaction-progress').classList.toggle('hidden',!action);
  if (action) $('interaction-progress').firstElementChild.style.width = `${Math.min(100,action.progress/action.duration*100)}%`;
  simulation.inventory.forEach((item,i) => {
    $(`slot-${i}-name`).textContent = toolById(item.id)?.name || item.id;
    const reload = item.reloadRemaining > 0;
    $(`slot-${i}-count`).textContent = reload ? `Lädt ${item.reloadRemaining.toFixed(1)}s` : item.id === 'machinegun' ? `${item.magazine ?? 0} / ${item.charges}` : `${item.charges}`;
    $(`slot-${i}-heat`).style.width = `${(item.heat || 0)*100}%`;
    $(`slot-${i}`).classList.toggle('empty',item.charges <= 0 && !(item.magazine > 0));
    $(`slot-${i}`).classList.toggle('hot',(item.heat || 0) >= .85);
  });
  const event = simulation.worldEvent;
  $('world-warning').classList.toggle('hidden',!event);
  if (event) {$('world-warning').textContent = `${event.phase === 'warning' ? 'VORWARNUNG' : 'AKTIV'} · ${event.label} · ${Math.ceil(event.remaining)}s`;$('world-warning').classList.toggle('active',event.phase === 'active');}
  const threat = simulation.threat;
  $('threat-label').textContent = threat > .72 ? 'KONTAKT. BLEIB IN BEWEGUNG.' : threat > .35 ? 'DU BIST NICHT ALLEIN.' : 'DIE STILLE TRÜGT.';
  document.querySelector('.threat-block').style.color = threat > .6 ? '#ec9a76' : '#becfb4';
  $('damage').style.opacity = String(Math.max(performance.now() < damageUntil ? .8 : 0, Math.max(0,(35-simulation.player.health)/60)));
}
function drawMap() {
  if (!simulation) return;
  const canvas = $('minimap'),ctx = canvas.getContext('2d'),size = simulation.maze.size,unit = canvas.width/size;
  ctx.fillStyle = '#0b140e';ctx.fillRect(0,0,canvas.width,canvas.height);
  for (const key of simulation.explored) {
    const [x,z] = key.split(',').map(Number);
    if (!simulation.maze.grid[z]) continue;
    const zone = simulation.terrain && getTerrainZone(simulation.terrain,x*CELL,z*CELL);
    ctx.fillStyle = simulation.maze.grid[z][x] ? '#334330' : zone ? {forest:'#829272',ravine:'#857053','cave-rock':'#85939b','cave-roots':'#9a8563'}[zone] : '#829272';ctx.fillRect(x*unit+.5,z*unit+.5,unit-1,unit-1);
  }
  const level = simulation.player.level || 0;
  $('map-floor-label').textContent = simulation.terrain ? 'DUNKELWALD · WALD & TIEFEN' : `EBENE ${level+1} / ${simulation.levels?.length || 1}`;
  $('map-note').textContent = simulation.terrain ? 'Erkundete Wege: grün Wald · braun Schlucht · grau Grotte. ✦ Elfenlager · ○ Höhlenzugang · ◇ Ziel · □ Ausgang' : 'Nur erkundete Gänge dieser Ebene. ↑ Aufstieg · ↓ Abstieg · ◇ Ziel · □ Ausgang unten';
  const dot = (point,color,scale=.45) => {
    if ((point.level || 0) !== level) return;
    const x = Math.round(point.x/CELL),z = Math.round(point.z/CELL);
    if (simulation.explored.has(`${x},${z}`)) {ctx.fillStyle = color;ctx.fillRect((x+.5-scale/2)*unit,(z+.5-scale/2)*unit,unit*scale,unit*scale);}
  };
  for (const room of simulation.rooms) dot(room,room.type === 'sanctuary' ? '#8cf2c2' : '#819fc5',.65);
  simulation.objectives.filter(item => !item.completed).forEach(item => dot(item,'#f8eba9'));
  simulation.treasures.filter(item => !item.collected).forEach(item => dot(item,'#dba34d',.3));
  simulation.markers.forEach(item => dot(item,'#f5f5ee',.3));
  for (const ally of simulation.allies || []) {
    const x = Math.round(ally.x/CELL),z = Math.round(ally.z/CELL);
    if (!simulation.explored.has(`${x},${z}`)) continue;
    ctx.fillStyle = '#9affc2';ctx.font = `${Math.max(10,unit*.95)}px sans-serif`;ctx.textAlign = 'center';ctx.textBaseline = 'middle';
    ctx.fillText('✦',(x+.5)*unit,(z+.5)*unit);
  }
  for (const cave of simulation.terrain?.caves || []) for (const mouth of cave.mouths) {
    const x = Math.round(mouth.x/CELL),z = Math.round(mouth.z/CELL);
    if (!simulation.explored.has(`${x},${z}`)) continue;
    ctx.strokeStyle = '#9dd8f3';ctx.lineWidth = 1.5;ctx.beginPath();ctx.arc((x+.5)*unit,(z+.5)*unit,unit*.4,0,Math.PI*2);ctx.stroke();
  }
  if (simulation.rescue?.following) dot(simulation.rescue,'#9fe1fa');
  for (const ladder of simulation.ladders || []) {
    if (ladder.fromLevel !== level && ladder.toLevel !== level) continue;
    const x = Math.round(ladder.x/CELL),z = Math.round(ladder.z/CELL);
    if (!simulation.explored.has(`${x},${z}`)) continue;
    ctx.fillStyle = ladder.fromLevel === level ? '#8de8f0' : '#f2c485';
    ctx.font = `bold ${Math.max(10,unit*.85)}px Arial`;ctx.textAlign = 'center';ctx.textBaseline = 'middle';
    ctx.fillText(ladder.fromLevel === level ? '↑' : '↓',(x+.5)*unit,(z+.5)*unit);
  }
  const exit = simulation.exit || simulation.maze.exit;
  if ((exit.level || 0) === level && simulation.explored.has(`${exit.x},${exit.z}`)) {ctx.strokeStyle = '#8ff6c7';ctx.lineWidth = 2;ctx.strokeRect((exit.x+.15)*unit,(exit.z+.15)*unit,unit*.7,unit*.7);}
  ctx.save();ctx.translate((simulation.player.x/CELL+.5)*unit,(simulation.player.z/CELL+.5)*unit);ctx.rotate(-yaw);
  ctx.fillStyle = '#f3f4de';ctx.beginPath();ctx.moveTo(0,-unit*.58);ctx.lineTo(-unit*.35,unit*.4);ctx.lineTo(unit*.35,unit*.4);ctx.closePath();ctx.fill();ctx.restore();
}
function renderJournal() {
  $('journal-summary').textContent = `${profile.completedRuns} erfolgreiche Expeditionen · ${profile.failedRuns} Verluste · ${profile.earned} geborgene Fundstücke`;
  $('journal-mission').textContent = simulation ? `${simulation.terrain ? 'Dunkelwald mit begehbarer Schlucht und zwei Durchgangshöhlen. E bei freundlichen Elfen füllt deine Waffenmunition auf.' : `${simulation.levels?.length || 1} Ebenen · Ausgang auf Ebene 1.`} ${simulation.mission.name}: ${simulation.missionProgress.text} ${simulation.mission.briefing || simulation.mission.description} Getragene Schätze: ${simulation.carriedTreasure}.` : '';
  $('journal-objectives').replaceChildren(...(simulation?.objectives || []).map(objective => {
    const item = document.createElement('li');
    item.textContent = `${objective.completed ? '✓' : '◇'} ${simulation.terrain ? regionName(objective) : `Ebene ${(objective.level || 0)+1}`} · ${objective.label}`;
    return item;
  }));
  const unlocked = getUnlocks(profile);
  $('unlock-list').replaceChildren(...[...BIOMES,...TOOLS].map(item => {
    const free = unlocked.biomes.includes(item.id) || unlocked.tools.includes(item.id);
    const entry = document.createElement('div');entry.className = `unlock-entry${free ? '' : ' locked'}`;
    const detail = document.createElement('small');detail.textContent = free ? 'Verfügbar' : unlockHints[item.id] || item.unlockText;
    entry.append(document.createTextNode(`${free ? '✓ ' : '◇ '}${item.name}`),detail);return entry;
  }));
  const notes = [...new Set([...profile.journal,...(simulation?.journal || [])])];
  if (!notes.length) notes.push('Erkunde besondere Räume und lies ihre Spuren. Deine Entdeckungen bleiben auch nach einem verlorenen Versuch erhalten.');
  $('journal-entries').replaceChildren(...notes.map(note => {const li = document.createElement('li');li.textContent = note;return li;}));
}
function openJournal() {
  if (!['playing','paused','menu','result'].includes(mode)) return;
  journalReturnMode = mode;mode = 'journal';clearInput();releaseMouse();audio.setPaused(true);renderJournal();$('journal-dialog').showModal();
}
function closeJournal() {
  $('journal-dialog').close();mode = journalReturnMode;lastTime = performance.now();clearInput();audio.setPaused(mode === 'paused');
  if (mode === 'playing') captureMouse();
}
function renderPuzzle() {
  const puzzle = simulation?.activePuzzle;
  if (!puzzle) return;
  $('puzzle-clue').textContent = puzzle.clue;
  $('puzzle-progress').textContent = `Richtige Zeichen: ${Array.isArray(puzzle.progress) ? puzzle.progress.length : puzzle.progress} / 3`;
  if ($('rune-buttons').dataset.room !== puzzle.roomId) {
    $('rune-buttons').dataset.room = puzzle.roomId;
    $('rune-buttons').replaceChildren(...puzzle.symbols.map((symbol,index) => {
      const button = document.createElement('button');button.textContent = symbol;button.setAttribute('aria-label',`Rune ${index+1}: ${symbol}`);
      button.addEventListener('click',() => {simulation.chooseRune(index);processEvents();if (simulation.activePuzzle) renderPuzzle();else closePuzzle();});return button;
    }));
  }
}
function openPuzzle() {
  if (!simulation.activePuzzle || mode !== 'playing') return;
  mode = 'puzzle';clearInput();releaseMouse();audio.setPaused(true);renderPuzzle();$('puzzle-dialog').showModal();
}
function closePuzzle() {
  simulation?.closePuzzle();$('puzzle-dialog').close();mode = 'playing';lastTime = performance.now();clearInput();audio.setPaused(false);captureMouse();
}
function processEvents() {
  for (const event of simulation.events.splice(0)) {
    if (event.type === 'spawn') {audio.playSpawn();if (!event.text) showMessage('Etwas ist erwacht. Beobachte sein Verhalten.',4);}
    if (['relic','mission','treasure','resupply'].includes(event.type)) audio.playRelic();
    if (event.type === 'weapon') audio.playWeapon(event.weapon);
    if (event.type === 'explosion') audio.playExplosion();
    if (event.type === 'damage') {damageUntil = performance.now()+500;audio.playDamage();}
    if (event.type === 'world-warning') audio.playWarning();
    if (event.type === 'exhausted') showMessage('Außer Atem. Lass deine Ausdauer zurückkehren.',3);
    if (event.text && event.type !== 'explosion') showMessage(event.text,event.type === 'world-warning' ? 7 : 4);
    if (event.type === 'win') finishGame(true);
    if (event.type === 'lose') finishGame(false);
  }
}
function fireSlot(slot) {
  if (mode !== 'playing' || !simulation) return;
  // Resolve clicks on the next frame, after movement and the visible muzzle pose.
  pendingShots.add(slot);
}
function animate(time) {
  requestAnimationFrame(animate);
  const dt = Math.min(Math.max((time-lastTime)/1000,0),.05);lastTime = time;
  let movement = {moving:false,sprinting:false};
  if (mode === 'playing' && simulation) {
    if (keys.has('ArrowLeft')) yaw += dt*1.8;if (keys.has('ArrowRight')) yaw -= dt*1.8;
    pitch = Math.max(-1.25,Math.min(1.25,pitch + (Number(keys.has('PageUp'))-Number(keys.has('PageDown')))*dt*1.2));
    const forward = Number(keys.has('KeyW') || keys.has('ArrowUp'))-Number(keys.has('KeyS') || keys.has('ArrowDown'));
    const side = Number(keys.has('KeyD'))-Number(keys.has('KeyA'));
    movement = simulation.step(dt,{moveX:-Math.sin(yaw)*forward+Math.cos(yaw)*side,moveZ:-Math.cos(yaw)*forward-Math.sin(yaw)*side,sprint:keys.has('ShiftLeft') || keys.has('ShiftRight'),yaw,pitch,light,sneak:keys.has('KeyC')});
    world.prepareView(simulation,currentView(movement),dt);
    for (let slot = 0;slot < 2;slot++) {
      const held = keys.has(slot === 0 ? 'KeyQ' : 'KeyR') || mouseButtons.has(slot === 0 ? 0 : 2);
      if (pendingShots.has(slot) || (held && ['machinegun','laser'].includes(simulation.inventory[slot]?.id))) simulation.useTool(slot,yaw,pitch,world.getWeaponShot(slot,simulation,currentView(movement)));
    }
    pendingShots.clear();
    audio.setThreat(movement.threat);audio.update(dt,{...movement,sneaking:simulation.player.sneaking});processEvents();updateHud();
    if (!$('map-panel').classList.contains('hidden') && time-lastMapUpdate > 120) {drawMap();lastMapUpdate = time;}
  }
  if (time > messageUntil) $('message').classList.remove('visible');
  if (!document.hidden) world.update(['playing','menu'].includes(mode) ? dt : 0,simulation,currentView(movement));
}
function showError(error) {
  console.error(error);$('loading').classList.add('done');$('error-panel').classList.remove('hidden');mode = 'error';
  $('error-message').textContent = /webgl|context/i.test(error?.message || '') ? 'Die 3D-Grafik konnte nicht gestartet werden. Aktiviere bitte die Hardwarebeschleunigung und starte das Spiel erneut.' : 'Die lokalen Grafikdateien konnten nicht vollständig geladen werden. Bitte starte das Spiel erneut oder erstelle die Anwendung neu.';
}

document.querySelectorAll('[data-plan]').forEach((button,index,buttons) => {
  button.addEventListener('click',() => showPlan(button.dataset.plan));
  button.addEventListener('keydown',event => {if (['ArrowLeft','ArrowRight'].includes(event.code)) {event.preventDefault();showPlan(buttons[(index+(event.code === 'ArrowRight' ? 1 : buttons.length-1))%buttons.length].dataset.plan,true);}});
});
for (const id of ['biome','mission','tool-0','tool-1','levels']) $(id).addEventListener('change',updatePlanner);
for (const id of ['size','complexity']) $(id).addEventListener('input',updateSettings);
$('seed').addEventListener('change',saveSettings);
$('random-seed').addEventListener('click',() => {const bytes = new Uint32Array(1);crypto.getRandomValues(bytes);$('seed').value = `NACHT-${bytes[0].toString(36).toUpperCase().slice(0,6)}`;saveSettings();});
document.querySelectorAll('[data-danger]').forEach(button => button.addEventListener('click',() => {danger = button.dataset.danger;updateSettings();}));
$('volume').addEventListener('input',() => {volume = Number($('volume').value)/100;soundEnabled = volume > 0;soundPreference = soundEnabled;audio.setVolume(volume);updateSoundButton();updateSettings();});
$('quality').addEventListener('change',() => {world?.setQuality($('quality').value);saveSettings();});
$('sensitivity').addEventListener('input',() => {sensitivity = Number($('sensitivity').value)*.00004;updateSettings();});
$('sound-toggle').addEventListener('click',() => {soundEnabled = !soundEnabled;soundPreference = soundEnabled;if (soundEnabled && volume === 0) {volume = .55;$('volume').value = '55';updateSettings();}audio.setPaused(false);void enableAudio();updateSoundButton();});
$('help-button').addEventListener('click',() => $('help-dialog').showModal());
for (const id of ['close-help','understood-button']) $(id).addEventListener('click',() => $('help-dialog').close());
$('start-button').addEventListener('click',() => startGame());$('pause-button').addEventListener('click',pauseGame);
$('forest-button').addEventListener('click',() => {$('biome').value = 'forest';showPlan('world');updatePlanner();$('start-button').focus();});
$('resume-button').addEventListener('click',resumeGame);$('leave-button').addEventListener('click',returnToMenu);
$('retry-button').addEventListener('click',() => startGame(lastConfig));$('new-button').addEventListener('click',returnToMenu);
$('reload-button').addEventListener('click',() => location.reload());
for (const id of ['journal-button','hud-journal']) $(id).addEventListener('click',openJournal);
for (const id of ['close-journal','journal-back']) $(id).addEventListener('click',closeJournal);
$('journal-dialog').addEventListener('cancel',event => {event.preventDefault();closeJournal();});
$('close-puzzle').addEventListener('click',closePuzzle);
$('puzzle-dialog').addEventListener('cancel',event => {event.preventDefault();closePuzzle();});
document.addEventListener('keydown',event => {
  if (event.code === 'Escape') {
    if (event.repeat) {event.preventDefault();return;}
    if (mode === 'playing') {event.preventDefault();pauseGame();} else if (mode === 'paused') {event.preventDefault();resumeGame();}
    return;
  }
  if (event.code === 'KeyJ' && mode === 'journal') {if (!event.repeat) closeJournal();return;}
  if (mode !== 'playing') return;
  if (['KeyW','KeyA','KeyS','KeyD','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','PageUp','PageDown','Space','ShiftLeft','ShiftRight','KeyE','KeyF','KeyM','KeyQ','KeyR','KeyT','KeyJ','KeyC'].includes(event.code)) event.preventDefault();
  keys.add(event.code);if (event.repeat) return;
  if (event.code === 'KeyE') {simulation.interact();processEvents();updateHud();openPuzzle();}
  if (event.code === 'KeyQ') fireSlot(0);if (event.code === 'KeyR') fireSlot(1);
  if (event.code === 'KeyT') {simulation.reloadWeapons();processEvents();updateHud();}
  if (event.code === 'Space') {aim = {x:0,y:0};updateCrosshair();}
  if (event.code === 'KeyF') {light = !light;showMessage(light ? 'Dein Licht weist dir den Weg.' : 'Das Licht ist erloschen.',2);}
  if (event.code === 'KeyM') {$('map-panel').classList.toggle('hidden');drawMap();}
  if (event.code === 'KeyJ') openJournal();
});
document.addEventListener('keyup',event => keys.delete(event.code));
document.addEventListener('pointerlockchange',() => {
  const locked = !!document.pointerLockElement;if (hadPointerLock && !locked && mode === 'playing') pauseGame();hadPointerLock = locked;
});
document.addEventListener('mousemove',event => {
  if (mode !== 'playing') return;
  const rect = world.renderer.domElement.getBoundingClientRect();
  if (document.pointerLockElement) aim = moveAim(aim,event.movementX,event.movementY,rect.width,rect.height,sensitivity/.002);
  else if (event.target === world.renderer.domElement) aim = pointAim(event.clientX,event.clientY,rect);
  else return;
  updateCrosshair();
});
document.addEventListener('mouseup',event => mouseButtons.delete(event.button));
window.addEventListener('blur',() => {clearInput();pauseGame();});
document.addEventListener('visibilitychange',() => {if (document.hidden) {pauseGame();audio.setPaused(true);} else if (mode === 'menu' || mode === 'result') audio.setPaused(false);});
window.addEventListener('beforeunload',() => {audio.dispose();world?.dispose();});

try {
  restoreSettings();updateSettings();updatePlanner();showPlan('world');audio.setVolume(volume);
  world = new WorldRenderer($('world'),{quality:$('quality').value,onProgress:text => {$('loading-label').textContent = text;}});
  await world.ready;
  world.renderer.domElement.addEventListener('mousedown',event => {
    if (mode !== 'playing') return;
    if ([0,2].includes(event.button)) {event.preventDefault();mouseButtons.add(event.button);fireSlot(event.button === 0 ? 0 : 1);}
  });
  world.renderer.domElement.addEventListener('contextmenu',event => {if (mode === 'playing') event.preventDefault();});
  world.renderer.domElement.addEventListener('webglcontextlost',event => {event.preventDefault();pauseGame();showError(new Error('WebGL context lost'));});
  requestAnimationFrame(time => {world.update(0,null);$('loading').classList.add('done');lastTime = time;requestAnimationFrame(animate);});
} catch (error) { showError(error); }
