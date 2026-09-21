import test from 'node:test';
import assert from 'node:assert/strict';
import { createProfile, normalizeProfile, getUnlocks, recordExpedition } from '../src/progression.js';

test('new players can immediately equip every requested shooter weapon', () => {
  const profile = createProfile();
  assert.deepEqual(getUnlocks(profile), { biomes: ['catacombs', 'forest'], tools: ['stone', 'chalk', 'machinegun', 'laser', 'rocket'] });
  const other = createProfile();
  profile.journal.push('private');
  assert.deepEqual(other.journal, []);
});

test('victory banks treasure, unlocks regions and tools, and duplicate results do not reward twice', () => {
  const original = createProfile();
  const victory = { id: 'run-a', won: true, treasure: 4, biome: 'catacombs', mission: 'seals', journal: ['Eintrag A'] };
  const first = recordExpedition(original, victory);
  assert.equal(first.completedRuns, 1);
  assert.equal(first.earned, 6);
  assert.equal(original.completedRuns, 0);
  assert.deepEqual(original.processedRuns, []);
  assert.deepEqual(getUnlocks(first), { biomes: ['catacombs', 'forest', 'ruins'], tools: ['stone', 'chalk', 'machinegun', 'laser', 'rocket', 'flare', 'compass'] });
  assert.deepEqual(recordExpedition(first, victory), first);
  assert.deepEqual(recordExpedition(first, { ...victory, treasure: 100, journal: ['duplicate'] }), first);
  const second = recordExpedition(first, { ...victory, id: 'run-b', treasure: 0 });
  assert.equal(second.earned, 8);
  assert.ok(getUnlocks(second).biomes.includes('mine'));
  assert.deepEqual(second.journal, ['Eintrag A']);
});

test('defeat preserves discoveries but loses carried treasure and does not open the next biome', () => {
  const profile = recordExpedition(createProfile(), { id: 'failed', won: false, treasure: 50, journal: ['Der Schatten fürchtet Licht.'] });
  assert.equal(profile.earned, 0);
  assert.equal(profile.completedRuns, 0);
  assert.equal(profile.failedRuns, 1);
  assert.deepEqual(profile.journal, ['Der Schatten fürchtet Licht.']);
  assert.deepEqual(getUnlocks(profile).biomes, ['catacombs', 'forest']);
  assert.deepEqual(recordExpedition(profile, { id: 'failed', won: true, treasure: 50 }), profile);
});

test('three successful runs open the mine even without enough banked value', () => {
  let profile = createProfile();
  for (let id = 0; id < 3; id += 1) profile = recordExpedition(profile, { id: `run-${id}`, won: true, treasure: 0 });
  assert.equal(profile.earned, 6);
  assert.ok(getUnlocks(profile).biomes.includes('mine'));
});

test('corrupt storage and malformed results never introduce invalid counts or shared arrays', () => {
  for (const value of [null, undefined, [], 'text', 42, {}, { version: 999 }]) assert.deepEqual(normalizeProfile(value), createProfile());
  const invalid = normalizeProfile({ version: 1, completedRuns: Infinity, failedRuns: -9, earned: NaN,
    journal: [null, false, '', '  clue  ', 'clue', 42], processedRuns: ['id', 'id', {}, ''] });
  assert.equal(invalid.completedRuns, 0);
  assert.equal(invalid.failedRuns, 0);
  assert.equal(invalid.earned, 0);
  assert.deepEqual(invalid.journal, ['clue']);
  assert.deepEqual(invalid.processedRuns, ['id']);
  const original = createProfile();
  for (const result of [null, {}, { id: '', won: true }, { id: 'x', won: 'true' }, { id: 123, won: true }]) {
    assert.deepEqual(recordExpedition(original, result), original);
  }
  for (const treasure of [NaN, Infinity, -15, '10', null, Symbol('bad')]) {
    const value = recordExpedition(original, { id: 'valid', won: true, treasure });
    assert.equal(value.earned, 2);
    assert.equal(value.completedRuns, 1);
  }
  const restored = normalizeProfile(invalid);
  restored.journal.push('later');
  assert.deepEqual(invalid.journal, ['clue']);
});
