import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';

// Render the real Web Audio graph, including its compressor and distortion.
// This checks the resulting signal rather than substituting mock audio nodes.
test('adaptive soundtrack renders distinct quiet/combat layers without clipping or retained one-shots', async ({ page }) => {
  const source = readFileSync(new URL('../../src/audio.js', import.meta.url), 'utf8');
  const result = await page.evaluate(async source => {
    const Engine = new Function(source.replace('export class AudioEngine', 'class AudioEngine') + '; return AudioEngine;')();
    async function render(threat) {
      const engine = new Engine();
      engine.context = new OfflineAudioContext(2, 48_000 * 6, 48_000);
      engine._buildGraph();
      engine.gate.gain.setValueAtTime(1, 0);
      engine.setThreat(threat);
      if (threat) for (let step = 0; step < 48; step++) engine._combatBeat(.05 + step * 60 / 144 / 4, step % 32);
      const buffer = await engine.context.startRendering();
      let square = 0, peak = 0, finite = true;
      const data = buffer.getChannelData(0);
      for (let i = 48_000; i < data.length; i++) {
        square += data[i] * data[i];peak = Math.max(peak, Math.abs(data[i]));finite &&= Number.isFinite(data[i]);
      }
      return { rms: Math.sqrt(square / (data.length - 48_000)), peak, finite, nodes: engine._nodes.size };
    }
    return { quiet: await render(0), combat: await render(1) };
  }, source);
  expect(result.quiet.finite && result.combat.finite).toBe(true);
  expect(result.quiet.rms).toBeGreaterThan(.001);
  expect(result.combat.rms).toBeGreaterThan(result.quiet.rms * 1.5);
  expect(result.combat.peak).toBeLessThan(.95);
  expect(result.combat.nodes).toBe(result.quiet.nodes);
});

test('sparse horror gestures produce spatial sound and release every temporary audio node', async ({ page }) => {
  const source = readFileSync(new URL('../../src/audio.js', import.meta.url), 'utf8');
  const result = await page.evaluate(async source => {
    const Engine = new Function(source.replace('export class AudioEngine', 'class AudioEngine') + '; return AudioEngine;')();
    async function render(gestures) {
      const engine = new Engine();
      engine.context = new OfflineAudioContext(2, 24_000 * 36, 24_000);
      engine._buildGraph();
      engine.gate.gain.setValueAtTime(1, 0);
      engine.setThreat(0);
      const persistentNodes = engine._nodes.size;
      if (gestures) [0, 1, 2].forEach((kind, index) => engine._ambientGesture(1 + index * 11, kind));
      const buffer = await engine.context.startRendering();
      return { buffer, remainingNodes: engine._nodes.size, persistentNodes };
    }
    const baseline = await render(false);
    const score = await render(true);
    const dry = baseline.buffer.getChannelData(0);
    const left = score.buffer.getChannelData(0), right = score.buffer.getChannelData(1);
    let peak = 0, finite = true, stereoEnergy = 0;
    const gestures = [0, 1, 2].map(index => {
      let energy = 0;
      for (let i = (1 + index * 11) * 24_000; i < (10 + index * 11) * 24_000; i++) {
        energy += (left[i] - dry[i]) ** 2;
        stereoEnergy += (left[i] - right[i]) ** 2;
      }
      return Math.sqrt(energy / (9 * 24_000));
    });
    for (const sample of left) { peak = Math.max(peak, Math.abs(sample)); finite &&= Number.isFinite(sample); }
    return { gestures, stereoEnergy, peak, finite, remainingNodes: score.remainingNodes, persistentNodes: score.persistentNodes };
  }, source);
  expect(result.finite).toBe(true);
  for (const rms of result.gestures) expect(rms).toBeGreaterThan(.0002);
  expect(result.stereoEnergy).toBeGreaterThan(.1);
  expect(result.peak).toBeLessThan(.95);
  expect(result.remainingNodes).toBe(result.persistentNodes);
});
