const VERSION = 1;
const MAX_VALUE = 1_000_000_000;
const integer = (value) => typeof value === 'number' && Number.isFinite(value)
  ? Math.min(MAX_VALUE, Math.max(0, Math.floor(value))) : 0;

function strings(value, maxLength) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((entry) => typeof entry === 'string')
    .map((entry) => entry.trim().slice(0, maxLength)).filter(Boolean))];
}

export function createProfile() {
  return { version: VERSION, completedRuns: 0, failedRuns: 0, earned: 0, journal: [], processedRuns: [] };
}

/** Treat local storage as untrusted data and always return independent arrays. */
export function normalizeProfile(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || value.version !== VERSION) return createProfile();
  return {
    version: VERSION,
    completedRuns: integer(value.completedRuns), failedRuns: integer(value.failedRuns), earned: integer(value.earned),
    journal: strings(value.journal, 500), processedRuns: strings(value.processedRuns, 128),
  };
}

export function getUnlocks(value) {
  const profile = normalizeProfile(value);
  const biomes = ['catacombs', 'forest'];
  const tools = ['stone', 'chalk', 'machinegun', 'laser', 'rocket'];
  if (profile.completedRuns >= 1) { biomes.push('ruins'); tools.push('flare'); }
  if (profile.earned >= 6) tools.push('compass');
  if (profile.earned >= 8 || profile.completedRuns >= 3) biomes.push('mine');
  return { biomes, tools };
}

/** Commit a finished run once. Treasure is banked only when the player escapes;
 * discoveries survive defeat. The caller may safely replay a saved result. */
export function recordExpedition(value, result) {
  const profile = normalizeProfile(value);
  if (!result || typeof result !== 'object' || typeof result.id !== 'string' || typeof result.won !== 'boolean') return profile;
  const id = result.id.trim().slice(0, 128);
  if (!id || profile.processedRuns.includes(id)) return profile;
  profile.processedRuns.push(id);
  profile.journal = strings([...profile.journal, ...strings(result.journal, 500)], 500);
  if (result.won) {
    profile.completedRuns = integer(profile.completedRuns + 1);
    profile.earned = integer(profile.earned + 2 + integer(result.treasure));
  } else profile.failedRuns = integer(profile.failedRuns + 1);
  return profile;
}
