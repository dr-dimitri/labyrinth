import './shooter.css';
import { ShooterSimulation, WEAPONS, EXTRACTION } from './shooter-simulation.js';
import { ShooterRenderer } from './shooter-renderer.js';
import { AudioEngine } from './audio.js';

const $ = id => document.getElementById(id);
const keys = new Set(), buttons = new Set(), audio = new AudioEngine();
let pendingFire = false;
const SETTINGS = 'nachtgang-blacksite-settings-v1';
let world, sim, mode = 'menu', yaw = 0, pitch = 0, last = performance.now(), bannerUntil = 0, toastUntil = 0, hitUntil = 0, killUntil = 0, damageUntil = 0;
let locked = false, pointerHintShown = false, sensitivity = .002, settings = { difficulty: 'normal', quality: 'balanced', sensitivity: 65, volume: 45 };
try { const saved = JSON.parse(localStorage.getItem(SETTINGS)); if (saved && typeof saved === 'object') settings = { ...settings, ...saved }; } catch { /* Local preferences are optional. */ }
if (!['easy', 'normal', 'hard'].includes(settings.difficulty)) settings.difficulty = 'normal';
if (!['balanced', 'high'].includes(settings.quality)) settings.quality = 'balanced';
for (const id of ['sensitivity', 'volume']) settings[id] = Number.isFinite(Number(settings[id])) ? Math.max(id === 'volume' ? 0 : 20, Math.min(id === 'volume' ? 100 : 160, Number(settings[id]))) : id === 'volume' ? 45 : 65;
for (const [id, value] of Object.entries(settings)) $(id).value = value;

const pad = number => String(Math.floor(number)).padStart(2, '0');
const timeText = seconds => `${pad(seconds / 60)}:${pad(seconds % 60)}`;
const clearInput = () => { keys.clear(); buttons.clear(); pendingFire = false; if (sim) sim.aiming = false; };
function setMode(next) {
  mode = next; clearInput(); document.body.dataset.mode = mode;
  $('menu').classList.toggle('hidden', mode !== 'menu'); $('hud').classList.toggle('hidden', !sim || mode === 'menu');
  $('pause-screen').classList.toggle('hidden', mode !== 'paused'); $('result-screen').classList.toggle('hidden', mode !== 'result');
  if (mode !== 'playing') { releaseMouse(); document.body.classList.remove('scoped'); $('scope').classList.add('hidden'); $('damage').style.opacity = '0'; }
  audio.setPaused(mode !== 'playing');
}
function updateSettings() {
  settings = { difficulty: $('difficulty').value, quality: $('quality').value, sensitivity: Number($('sensitivity').value), volume: Number($('volume').value) };
  sensitivity = settings.sensitivity * .000035;
  audio.setVolume(settings.volume / 100);
  $('difficulty-label').textContent = { easy: 'Rekrut', normal: 'Operator', hard: 'Veteran' }[settings.difficulty];
  try { localStorage.setItem(SETTINGS, JSON.stringify(settings)); } catch { /* Still playable with storage disabled. */ }
}
function toast(message, seconds = 3) { $('toast').textContent = message; $('toast').classList.add('visible'); toastUntil = performance.now() + seconds * 1000; }
function banner(label, title, subtitle, seconds = 3) { $('banner-label').textContent = label; $('banner-title').textContent = title; $('banner-subtitle').textContent = subtitle; $('banner').classList.add('visible'); bannerUntil = performance.now() + seconds * 1000; }
function captureMouse() {
  const hint = () => {
    if (mode === 'playing' && !pointerHintShown) { pointerHintShown = true; toast('Zum Umsehen mit gedrückter Maustaste ziehen. Pfeiltasten funktionieren ebenfalls.', 6); }
  };
  try {
    const request = world.renderer.domElement.requestPointerLock?.();
    request?.catch(hint);
    if (!world.renderer.domElement.requestPointerLock) hint();
  } catch { hint(); }
}
function releaseMouse() { if (document.pointerLockElement) document.exitPointerLock?.(); }
function start() {
  if (!world || $('start-button').disabled) return;
  sim = new ShooterSimulation({ difficulty: settings.difficulty, seed: (Date.now() & 0xffffffff) >>> 0 });
  yaw = pitch = 0; world.reset(); setMode('playing'); captureMouse(); void audio.start();
  banner('VIPER 01 · VERBINDUNG STEHT', 'EINSATZ BEGINNT', 'Drei Wellen. Ein Ausgang. Bleib in Bewegung.', 4);
  hitUntil = killUntil = damageUntil = 0; $('hitmarker').classList.remove('active'); $('kill-confirm').classList.remove('visible'); last = performance.now(); updateHud();
}
function pause() { if (mode === 'playing') { setMode('paused'); updateHud(); $('resume-button').focus(); } }
function resume() { if (mode === 'paused' && !document.querySelector('dialog[open]')) { setMode('playing'); last = performance.now(); captureMouse(); void audio.start(); } }
function menu() { setMode('menu'); sim = null; world.reset(); $('toast').classList.remove('visible'); $('start-button').focus(); }
function finish(won) {
  setMode('result');
  $('result-eyebrow').textContent = won ? 'EXTRAKTION ERFOLGREICH' : 'SIGNAL VERLOREN';
  $('result-title').innerHTML = won ? 'MISSION<br>ERFÜLLT.' : 'EINSATZ<br>GESCHEITERT.';
  $('result-description').textContent = won ? 'Außenposten gesichert. Viper 01, willkommen zurück.' : 'Suche Deckung, wechsle deine Position und nutze die erhöhten Containerdächer.';
  $('result-kills').textContent = sim.kills; $('result-score').textContent = sim.score; $('result-time').textContent = timeText(sim.time);
  $('retry-button').focus();
}
function processEvents() {
  const events = sim.events.splice(0); world.events(events, sim);
  for (const e of events) {
    if (e.type === 'shot') { audio.playWeapon(e.weapon === 'sniper' ? 'sniper' : 'machinegun'); if (e.hit) { hitUntil = performance.now() + 160; $('hitmarker').classList.toggle('headshot', e.head); } }
    if (e.type === 'enemy-shot') audio.playEnemyShot(Math.hypot(e.from.x - sim.player.x, e.from.z - sim.player.z));
    if (e.type === 'explosion') audio.playExplosion();
    if (e.type === 'damage') { damageUntil = performance.now() + 380; audio.playDamage(); }
    if (e.type === 'kill') { killUntil = performance.now() + 1600; $('kill-confirm').textContent = `${e.head ? 'KOPFTREFFER' : 'ZIEL AUSGESCHALTET'}  +${e.points} XP`; }
    if (e.type === 'wave') { banner('FEINDLICHE VERSTÄRKUNG', `WELLE ${pad(e.wave)}`, `${e.count} Kontakte im Einsatzgebiet`, 3); audio.playWarning(); }
    if (e.type === 'wave-clear') { banner('SEKTOR VORERST GESICHERT', 'DURCHATMEN.', 'Nachschub erhalten · Nächste Welle in 7 Sekunden', 4); audio.playRelic(); }
    if (e.type === 'extract') { banner('ALLE KONTAKTE NEUTRALISIERT', 'ZUR EVAKUIERUNG', 'Erreiche den grünen Ring am Nordtor.', 5); audio.playRelic(); }
    if (e.type === 'supply') toast('NACHSCHUB  +45 Sturmgewehr · +5 Scharfschützengewehr', 2);
    if (e.type === 'destroy') toast('DECKUNG ZERSTÖRT  +25 XP', 1.6);
    if (e.type === 'win') finish(true);
    if (e.type === 'lose') finish(false);
  }
}
function updateHud() {
  if (!sim) return;
  const p = sim.player, w = sim.weapons[sim.weapon], spec = WEAPONS[sim.weapon], alive = sim.alive.length;
  $('wave').textContent = pad(Math.max(1, sim.wave)); $('enemy-count').textContent = alive; $('score').textContent = sim.score;
  $('health-value').textContent = Math.ceil(p.health); $('health-fill').style.width = `${p.health}%`; $('health-fill').parentElement.setAttribute('aria-valuenow', String(Math.ceil(p.health)));
  $('stamina-fill').style.width = `${p.stamina}%`; $('stance').textContent = sim.climbing ? 'KLETTERT' : p.prone ? 'LIEGEND' : !p.grounded ? 'IN DER LUFT' : sim.sprinting ? 'SPRINT' : 'STEHEND';
  $('concealment').classList.toggle('hidden-state', sim.hidden);
  $('concealment').lastElementChild.textContent = sim.hidden ? 'VERSTECKT · KEIN SICHTKONTAKT' : sim.alive.some(e => e.seesPlayer) ? 'ENTDECKT · DECKUNG SUCHEN' : 'SEKTOR BEOBACHTEN';
  $('weapon-name').textContent = spec.name; $('weapon-type').textContent = spec.label; $('ammo').textContent = pad(w.ammo); $('reserve').textContent = w.reserve; $('grenades').textContent = sim.grenades;
  $('fire-mode').textContent = sim.weapon === 'sniper' ? 'PRÄZISION' : 'AUTO'; $('ammo').style.color = w.ammo < 5 ? '#f58a62' : '';
  $('reload-progress').classList.toggle('hidden', !w.reload); $('reload-progress').lastElementChild.style.transform = `scaleX(${1 - w.reload / spec.reload})`;
  const scoped = sim.aiming && sim.weapon === 'sniper' && mode === 'playing';
  $('scope').classList.toggle('hidden', !scoped); document.body.classList.toggle('scoped', scoped);
  $('crosshair').classList.toggle('hidden', scoped || !!sim.climbing); $('crosshair').classList.toggle('aiming', sim.aiming);
  $('interaction').classList.toggle('hidden', !sim.mantleTarget() || !!sim.climbing || mode !== 'playing');
  const grenade = sim.projectiles.filter(g => Math.hypot(g.x - p.x, g.z - p.z) < 8).sort((a, b) => a.fuse - b.fuse)[0];
  $('grenade-warning').classList.toggle('hidden', !grenade); if (grenade) $('grenade-warning').lastElementChild.textContent = `${grenade.fuse.toFixed(1)} s`;
  const heading = ((-yaw * 180 / Math.PI) % 360 + 360) % 360;
  $('heading').textContent = `${String(Math.round(heading)).padStart(3, '0')}°`;
  const directions = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'], index = Math.round(heading / 45) % 8;
  $('compass-strip').textContent = `${directions[(index + 6) % 8]}  ·  ${directions[(index + 7) % 8]}  ·  ${directions[index]}  ·  ${directions[(index + 1) % 8]}  ·  ${directions[(index + 2) % 8]}`;
  $('objective').textContent = sim.extractionAnnounced ? 'Erreiche die Evakuierung am Nordtor' : 'Überstehe die Angriffswellen';
  $('objective-detail').textContent = sim.extractionAnnounced ? sim.extractionProgress > 0 ? `Evakuierung in ${(3 - sim.extractionProgress).toFixed(1)} s` : `${Math.ceil(Math.hypot(p.x - EXTRACTION.x, p.z - EXTRACTION.z))} m bis zum Evakuierungspunkt` : sim.intermission > 0 ? `Verstärkung in ${Math.ceil(sim.intermission)} s` : `${sim.kills} Abschüsse · ${timeText(sim.time)}`;
}
function animate(now) {
  requestAnimationFrame(animate);
  const dt = Math.min(.1, Math.max(0, (now - last) / 1000)); last = now;
  if (mode === 'playing' && sim) {
    const scoped = sim.aiming && sim.weapon === 'sniper';
    yaw += (Number(keys.has('ArrowLeft')) - Number(keys.has('ArrowRight'))) * dt * (scoped ? .35 : 1.6);
    pitch = Math.max(-1.45, Math.min(1.45, pitch + (Number(keys.has('PageUp')) - Number(keys.has('PageDown'))) * dt));
    const previousTime = sim.time;
    sim.step(dt, { yaw, pitch, forward: Number(keys.has('KeyW') || keys.has('ArrowUp')) - Number(keys.has('KeyS') || keys.has('ArrowDown')), side: Number(keys.has('KeyD')) - Number(keys.has('KeyA')), sprint: keys.has('ShiftLeft') || keys.has('ShiftRight'), aim: buttons.has(2) || keys.has('KeyZ'), fire: pendingFire || buttons.has(0) || keys.has('KeyQ') });
    // Keep short taps until a fixed simulation tick has processed them. A
    // rejected shot (reload/cooldown) must not queue a later automatic shot.
    if (sim.time > previousTime) pendingFire = false;
    processEvents(); updateHud(); audio.setThreat(sim.alive.some(e => e.seesPlayer) ? .85 : sim.alive.length ? .35 : 0); audio.update(dt, { moving: sim.moving && sim.player.grounded, sprinting: sim.sprinting, sneaking: sim.player.prone });
    $('damage').style.opacity = String(Math.max(now < damageUntil ? .65 : 0, Math.max(0, (35 - sim.player.health) / 55)));
  }
  $('banner').classList.toggle('visible', now < bannerUntil); $('toast').classList.toggle('visible', now < toastUntil);
  $('hitmarker').classList.toggle('active', now < hitUntil); $('kill-confirm').classList.toggle('visible', now < killUntil);
  if (!document.hidden) world.update(dt, sim, mode);
}
function openDialog(id) { pause(); clearInput(); $(id).showModal(); }
for (const [button, dialog] of [['settings-button', 'settings-dialog'], ['pause-settings', 'settings-dialog'], ['help-button', 'help-dialog'], ['loadout-button', 'loadout-dialog']]) $(button).addEventListener('click', () => openDialog(dialog));
for (const id of ['difficulty', 'quality', 'sensitivity', 'volume']) $(id).addEventListener('input', () => { updateSettings(); if (id === 'quality') world?.setQuality(settings.quality); });
$('start-button').addEventListener('click', start); $('retry-button').addEventListener('click', start);
$('pause-button').addEventListener('click', pause); $('resume-button').addEventListener('click', resume);
$('leave-button').addEventListener('click', menu); $('result-menu').addEventListener('click', menu); $('reload-page').addEventListener('click', () => location.reload());
document.addEventListener('keydown', event => {
  if (document.querySelector('dialog[open]')) return;
  if (event.code === 'Escape') { event.preventDefault(); if (!event.repeat) { if (mode === 'playing') pause(); else if (mode === 'paused') resume(); } return; }
  if (mode !== 'playing') return;
  if (['KeyW', 'KeyA', 'KeyS', 'KeyD', 'Space', 'ShiftLeft', 'ShiftRight', 'KeyC', 'ControlLeft', 'ControlRight', 'KeyE', 'KeyR', 'KeyG', 'Digit1', 'Digit2', 'KeyQ', 'KeyZ', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown'].includes(event.code)) event.preventDefault();
  keys.add(event.code); if (event.repeat) return;
  if (event.code === 'KeyQ') pendingFire = true;
  if (event.code === 'Space') sim.jump();
  if (['KeyC', 'ControlLeft', 'ControlRight'].includes(event.code)) sim.toggleProne();
  if (event.code === 'KeyR') sim.reload();
  if (event.code === 'KeyG') sim.throwGrenade();
  if (event.code === 'KeyE') sim.mantle();
  if (event.code === 'Digit1' || event.code === 'Digit2') sim.switchWeapon(event.code === 'Digit1' ? 'rifle' : 'sniper');
});
document.addEventListener('keyup', e => keys.delete(e.code));
document.addEventListener('mouseup', e => buttons.delete(e.button));
document.addEventListener('mousemove', e => {
  if (mode !== 'playing' || (!document.pointerLockElement && !buttons.size)) return;
  const factor = sim.aiming ? sim.weapon === 'sniper' ? .22 : .65 : 1;
  yaw -= e.movementX * sensitivity * factor; pitch = Math.max(-1.45, Math.min(1.45, pitch - e.movementY * sensitivity * factor));
});
document.addEventListener('pointerlockchange', () => { const next = !!document.pointerLockElement; if (locked && !next && mode === 'playing') pause(); locked = next; });
window.addEventListener('blur', pause); document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
window.addEventListener('beforeunload', () => { audio.dispose(); world?.dispose(); });
function showError(error) {
  console.error(error); $('loading').classList.add('done'); setMode('error'); $('error-panel').classList.remove('hidden');
  $('error-message').textContent = /webgl|context/i.test(error?.message || '') ? 'Die 3D-Grafik benötigt WebGL 2. Aktiviere die Hardwarebeschleunigung und starte das Spiel erneut.' : 'Das Einsatzgebiet konnte nicht vollständig geladen werden. Bitte lade das Spiel erneut.';
}
try {
  updateSettings();
  world = new ShooterRenderer($('world'), { quality: settings.quality, onProgress: text => { $('loading-label').textContent = text; } });
  await world.ready;
  world.renderer.domElement.addEventListener('mousedown', e => { if (mode === 'playing' && [0, 2].includes(e.button)) { e.preventDefault(); buttons.add(e.button); if (e.button === 0) pendingFire = true; } });
  world.renderer.domElement.addEventListener('contextmenu', e => e.preventDefault());
  world.renderer.domElement.addEventListener('wheel', e => { if (mode === 'playing') { e.preventDefault(); sim.switchWeapon(sim.weapon === 'rifle' ? 'sniper' : 'rifle'); } }, { passive: false });
  world.renderer.domElement.addEventListener('webglcontextlost', e => { e.preventDefault(); pause(); showError(new Error('WebGL context lost')); });
  $('start-button').disabled = false; world.update(0, null, 'menu'); $('loading').classList.add('done'); requestAnimationFrame(animate);
} catch (error) { showError(error); }
