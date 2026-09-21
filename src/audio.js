/** Original synthesized sci-fi horror score and game sounds. No audio files required. */
export class AudioEngine {
  constructor() {
    this.context = null;
    this.volume = 0.55;
    this.threat = 0;
    this.paused = false;
    this.started = false;
    this.disposed = false;
    this._nodes = new Set();
    this._sources = new Set();
    this._timer = null;
    this._voices = [];
    this._nextDrift = 0;
    this._nextGesture = 0;
    this._ambienceStep = 0;
    this._nextPulse = 0;
    this._nextBeat = 0;
    this._combatStep = 0;
    this._stepClock = 0;
    this._stepSide = 1;
    this._randomState = 0x4c414259;
  }

  /** Call from a pointer/keyboard interaction to satisfy browser audio policy. */
  async start() {
    if (this.disposed) return false;
    if (!this.context) {
      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
      if (!Context) return false;
      try {
        this.context = new Context({ latencyHint: "interactive" });
        this._buildGraph();
      } catch (error) {
        this.dispose();
        console.warn("Die Audioausgabe konnte nicht gestartet werden.", error);
        return false;
      }
    }
    try {
      if (this.context.state === "suspended") await this.context.resume();
      if (this.disposed || this.context.state !== "running") return false;
      this.started = true;
      this._setGate();
      this._schedule();
      return true;
    } catch {
      // The game remains playable when a browser declines audio playback.
      return false;
    }
  }

  setVolume(value) {
    this.volume = clamp(value);
    if (this.master && !this.disposed) {
      this.master.gain.setTargetAtTime(this.volume * 0.72, this.context.currentTime, 0.08);
    }
  }

  setThreat(value) {
    this.threat = clamp(value);
    if (this.airGain && !this.disposed) {
      const now = this.context.currentTime;
      this.airGain.gain.setTargetAtTime(0.018 + this.threat * 0.012, now, 0.6);
      this.padFilter.frequency.setTargetAtTime(1850 + this.threat * 550, now, 1.3);
      const combat = this.threat > .12 ? Math.min(1, (this.threat - .12) / .55) : 0;
      this.combatBus.gain.setTargetAtTime(combat * .7, now, combat >= this._combatLevel ? .18 : 1.4);
      this.musicBus.gain.setTargetAtTime(.9 - combat * .63, now, .7);
      this._combatLevel = combat;
    }
  }

  setPaused(value) {
    this.paused = Boolean(value);
    this._stepClock = 0;
    if (!this.context || this.disposed) return;
    this._setGate();
    if (this.paused) {
      this._clearTimer();
    } else if (this.started) {
      // Skip missed events; resuming never produces a burst of queued sounds.
      this._nextPulse = this.context.currentTime + 0.5;
      this._nextGesture = this.context.currentTime + 3;
      this._nextDrift = this.context.currentTime + 8;
      this._nextBeat = this.context.currentTime + .05;
      this._schedule();
    }
  }

  update(dt, { moving = false, sprinting = false, sneaking = false } = {}) {
    if (!this._isPlaying()) return;
    if (!moving) {
      this._stepClock = 0;
      return;
    }
    // A long background-tab frame must not generate a pile of footsteps.
    this._stepClock -= Math.min(Math.max(Number(dt) || 0, 0), 0.1);
    if (this._stepClock <= 0) {
      this._footstep(sprinting, sneaking);
      this._stepClock = sneaking ? .65 : sprinting ? 0.22 : 0.35;
    }
  }

  playRelic() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    [74, 77, 81, 86].forEach((note, index) => {
      this._tone(midi(note), now + index * 0.105, 1.4, 0.045, "sine", (index - 1.5) * 0.2);
    });
  }

  playSpawn() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    this._tone(92, now, 1.45, 0.065, "sine", 0, 43);
    this._noise(now, 1.3, 0.036, 320, 0, "lowpass", 0.15);
  }

  playWeapon(weapon) {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    if (weapon === 'machinegun') {
      this._noise(now, .085, .18, 2200, -.12, 'lowpass', .002);
      this._tone(160, now, .1, .085, 'triangle', -.12, 48);
    } else if (weapon === 'sniper') {
      this._noise(now, .28, .23, 1700, 0, 'lowpass', .002);
      this._tone(120, now, .4, .13, 'triangle', 0, 29);
      this._noise(now + .34, .065, .035, 3600, .15, 'highpass', .003);
    } else if (weapon === 'laser') {
      this._tone(1450, now, .18, .055, 'sawtooth', -.1, 180);
      this._tone(2200, now, .12, .025, 'sine', .1, 650);
    } else if (weapon === 'rocket') {
      this._noise(now, .65, .16, 900, .1, 'lowpass', .015);
      this._tone(155, now, .5, .09, 'triangle', .1, 42);
    }
  }

  playExplosion() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    this._noise(now, .95, .22, 950, 0, 'lowpass', .004);
    this._tone(90, now, .8, .16, 'sine', 0, 24);
  }

  playEnemyShot(distance = 10) {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime, gain = .06 / (1 + distance / 18);
    this._noise(now, .08, gain, 1400, 0, 'lowpass', .003);
    this._tone(145, now, .1, gain * .5, 'triangle', 0, 50);
  }

  playDamage() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    this._noise(now, .15, .1, 330, 0, 'lowpass', .004);
    this._tone(72, now, .3, .08, 'sine', 0, 35);
  }

  playWarning() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    this._tone(220, now, .4, .045, 'sine');
    this._tone(165, now + .45, .65, .04, 'sine');
  }

  playWin() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    [62, 65, 69, 74, 77, 81].forEach((note, index) => {
      this._tone(midi(note), now + index * 0.19, 2.2, 0.045, "sine", (index - 2.5) * 0.15);
    });
    this.setThreat(0);
  }

  playLose() {
    if (!this._isPlaying()) return;
    const now = this.context.currentTime;
    this._tone(146.83, now, 2, 0.065, "sine", -0.1, 55);
    this._tone(110, now + 0.1, 1.9, 0.04, "sine", 0.1, 36.71);
    this._noise(now, 1.1, 0.04, 480, 0, "lowpass", 0.06);
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.started = false;
    this._clearTimer();
    for (const source of this._sources) {
      source.onended = null;
      try { source.stop(); } catch { /* A one-shot may have already ended. */ }
    }
    for (const node of this._nodes) {
      try { node.disconnect(); } catch { /* Already disconnected. */ }
    }
    this._sources.clear();
    this._nodes.clear();
    this._voices.length = 0;
    if (this.context && this.context.state !== "closed") {
      this.context.close().catch(() => {});
    }
  }

  _node(node) {
    this._nodes.add(node);
    return node;
  }

  _source(source) {
    this._sources.add(source);
    return this._node(source);
  }

  _rand() {
    // A small deterministic generator keeps the ambience reproducible.
    let value = this._randomState;
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    this._randomState = value >>> 0;
    return this._randomState / 4294967296;
  }

  _buildGraph() {
    const ctx = this.context;
    const now = ctx.currentTime;
    this.master = this._node(ctx.createGain());
    this.master.gain.value = this.volume * 0.72;
    this.gate = this._node(ctx.createGain());
    this.gate.gain.value = 0;
    this.limiter = this._node(ctx.createDynamicsCompressor());
    this.limiter.threshold.value = -14;
    this.limiter.knee.value = 12;
    this.limiter.ratio.value = 8;
    this.limiter.attack.value = 0.005;
    this.limiter.release.value = 0.3;
    this.bus = this._node(ctx.createGain());
    this.bus.gain.value = 0.8;
    this.bus.connect(this.limiter);
    this.limiter.connect(this.gate);
    this.gate.connect(this.master);
    this.master.connect(ctx.destination);

    this.reverb = this._node(ctx.createConvolver());
    this.reverb.buffer = this._impulse(2.8);
    const wet = this._node(ctx.createGain());
    wet.gain.value = 0.23;
    this.reverb.connect(wet);
    wet.connect(this.bus);

    this.musicBus = this._node(ctx.createGain());
    this.musicBus.gain.value = 0.9;
    this.padFilter = this._node(ctx.createBiquadFilter());
    this.padFilter.type = "lowpass";
    this.padFilter.frequency.value = 1850 + this.threat * 550;
    this.padFilter.Q.value = 0.35;
    this.musicBus.connect(this.padFilter);
    const ambienceOutput = this._node(ctx.createGain());
    ambienceOutput.gain.value = MUSIC_BOOST;
    this.padFilter.connect(ambienceOutput);
    ambienceOutput.connect(this.bus);
    // The entire long reverb tail passes through musicBus, so combat can duck
    // the exploration score without an unducked ambience lingering underneath.
    this.ambienceInput = this._node(ctx.createGain());
    this.ambienceInput.gain.value = .42;
    this.ambienceInput.connect(this.musicBus);
    this.spaceReverb = this._node(ctx.createConvolver());
    this.spaceReverb.buffer = this._impulse(7.4);
    const spaceWet = this._node(ctx.createGain());
    spaceWet.gain.value = 0.52;
    this.ambienceInput.connect(this.spaceReverb);
    this.spaceReverb.connect(spaceWet);
    spaceWet.connect(this.musicBus);

    // An original industrial riff layer crossfades with nearby danger.
    this.combatBus = this._node(ctx.createGain());
    this.combatBus.gain.value = 0;
    this._combatLevel = 0;
    const distortion = this._node(ctx.createWaveShaper());
    distortion.curve = Float32Array.from({ length: 2048 }, (_, index) => Math.tanh((index / 1023.5 - 1) * 3));
    distortion.oversample = '2x';
    const combatFilter = this._node(ctx.createBiquadFilter());
    combatFilter.type = 'lowpass';combatFilter.frequency.value = 4200;
    const combatLowCut = this._node(ctx.createBiquadFilter());
    combatLowCut.type = 'highpass';combatLowCut.frequency.value = 38;
    this.combatBus.connect(distortion);distortion.connect(combatFilter);
    combatFilter.connect(combatLowCut);
    const combatOutput = this._node(ctx.createGain());
    combatOutput.gain.value = MUSIC_BOOST;
    combatLowCut.connect(combatOutput);combatOutput.connect(this.bus);
    const combatReverb = this._node(ctx.createGain());combatReverb.gain.value = .08;
    combatOutput.connect(combatReverb);combatReverb.connect(this.reverb);

    // Unresolved, inharmonic frequencies replace the old repeating chord loop.
    // Independent pitch and amplitude drifts create slow beating and breathing;
    // this is a textural score, with no borrowed melody or sampled soundtrack.
    for (let index = 0; index < DRONES.length; index++) {
      const envelope = this._node(ctx.createGain());
      const amplitude = index < 2 ? 0.032 : 0.01;
      envelope.gain.value = amplitude;
      const panner = this._pan((index - 2) * 0.28);
      envelope.connect(panner);
      panner.connect(this.ambienceInput);
      const oscillator = this._source(ctx.createOscillator());
      oscillator.type = "sine";
      oscillator.frequency.value = DRONES[index];
      oscillator.connect(envelope);
      oscillator.start(now);
      const drift = this._source(ctx.createOscillator());
      drift.frequency.value = 0.017 + index * 0.0067;
      const depth = this._node(ctx.createGain());
      depth.gain.value = 7 + index * 2;
      drift.connect(depth);
      depth.connect(oscillator.detune);
      drift.start(now);
      const breath = this._source(ctx.createOscillator());
      breath.frequency.value = 0.024 + index * 0.0091;
      const breathDepth = this._node(ctx.createGain());
      breathDepth.gain.value = amplitude * .56;
      breath.connect(breathDepth);
      breathDepth.connect(envelope.gain);
      breath.start(now + index * .21);
      this._voices.push(oscillator);
    }

    this.noiseBuffer = ctx.createBuffer(1, Math.ceil(ctx.sampleRate * 3), ctx.sampleRate);
    const noise = this.noiseBuffer.getChannelData(0);
    let previous = 0;
    for (let index = 0; index < noise.length; index++) {
      previous = (previous + (this._rand() * 2 - 1) * 0.035) / 1.035;
      noise[index] = previous * 4.2;
    }
    const air = this._source(ctx.createBufferSource());
    air.buffer = this.noiseBuffer;
    air.loop = true;
    const airFilter = this._node(ctx.createBiquadFilter());
    airFilter.type = "bandpass";
    airFilter.frequency.value = 290;
    airFilter.Q.value = 0.85;
    this.airGain = this._node(ctx.createGain());
    this.airGain.gain.value = 0.018 + this.threat * 0.012;
    air.connect(airFilter);
    airFilter.connect(this.airGain);
    this.airGain.connect(this.ambienceInput);
    air.start(now);
    this._nextDrift = now + 11;
    this._nextGesture = now + 2.5;
    this._nextPulse = now + 1;
    this._nextBeat = now + .05;
  }

  _impulse(duration) {
    const ctx = this.context;
    const length = Math.ceil(ctx.sampleRate * duration);
    const buffer = ctx.createBuffer(2, length, ctx.sampleRate);
    for (let channel = 0; channel < 2; channel++) {
      const data = buffer.getChannelData(channel);
      let smooth = 0;
      for (let index = 0; index < length; index++) {
        smooth = smooth * 0.45 + (this._rand() * 2 - 1) * 0.55;
        data[index] = smooth * Math.pow(1 - index / length, 3.2);
      }
    }
    return buffer;
  }

  _pan(position) {
    const ctx = this.context;
    if (typeof ctx.createStereoPanner === "function") {
      const panner = this._node(ctx.createStereoPanner());
      panner.pan.value = position;
      return panner;
    }
    // Gain is a safe mono fallback on older WebKit audio implementations.
    return this._node(ctx.createGain());
  }

  _setGate() {
    this.gate.gain.setTargetAtTime(this.paused ? 0 : 1, this.context.currentTime, 0.14);
  }

  _isPlaying() {
    return this.started && !this.paused && !this.disposed && this.context?.state === "running";
  }

  _clearTimer() {
    if (this._timer !== null) clearTimeout(this._timer);
    this._timer = null;
  }

  _schedule() {
    if (!this._isPlaying() || this._timer !== null) return;
    const now = this.context.currentTime;
    if (now >= this._nextDrift) {
      this._voices.forEach((voice, index) => {
        voice.frequency.setTargetAtTime(DRONES[index] * (0.975 + this._rand() * .05), now, 7.5);
      });
      this._nextDrift = now + 19 + this._rand() * 12;
    }
    if (now >= this._nextGesture) {
      if (this._combatLevel < .45) this._ambientGesture(now);
      // Leave several seconds of empty space after each decaying gesture.
      this._nextGesture = now + 14 + this._rand() * 13;
    }
    if (now >= this._nextPulse) {
      if (this.threat > 0.06) {
        const level = this.threat * 0.085;
        this._tone(58, now, 0.24, level, "sine", 0, 41);
        this._tone(53, now + 0.17, 0.18, level * 0.62, "sine", 0, 39);
      }
      this._nextPulse = now + 1.35 - this.threat * 0.73;
    }
    // Audio-clock scheduling keeps the rhythm steady even at low frame rates.
    if (this._nextBeat < now - .2) this._nextBeat = now + .025;
    while (this._nextBeat < now + .12) {
      if (this._combatLevel > .015) this._combatBeat(this._nextBeat, this._combatStep);
      this._combatStep = (this._combatStep + 1) % 32;
      this._nextBeat += 60 / 144 / 4;
    }
    this._timer = setTimeout(() => {
      this._timer = null;
      this._schedule();
    }, 25);
  }

  _ambientGesture(when, kind = this._ambienceStep++ % 3) {
    const position = this._rand() * 1.5 - .75;
    if (kind === 0) {
      // Uneven partials suggest a large metal structure resonating in darkness.
      const fundamental = 126 + this._rand() * 18;
      [1, 1.4142, 2.718, 4.173].forEach((ratio, index) => {
        this._ambientTone(fundamental * ratio, when + index * .013,
          6.8 - index * .7, .027 / (1 + index * 1.3), position,
          fundamental * ratio * (index % 2 ? 1.014 : .982), .07);
      });
    } else if (kind === 1) {
      // A bowed, breath-like cluster rises slowly, then vanishes without resolving.
      this._noise(when, 5.2, .042, 710, position, 'bandpass', 1.5, this.ambienceInput);
      this._ambientTone(683, when + .2, 8.2, .009, position, 631, 2.3);
      this._ambientTone(719, when + 1.1, 6.8, .006, -position, 728, 1.8);
    } else {
      // Distant, irregular sub-bass pulses never establish a regular beat.
      this._ambientTone(61, when, 1.6, .03, position * .4, 43, .18);
      this._ambientTone(54, when + 2.35, 2.2, .018, -position * .4, 39, .24);
      this._ambientTone(177, when + 1.3, 7.5, .012, position, 184, 1.6);
    }
  }

  _ambientTone(frequency, when, duration, amplitude, position, endFrequency, attack) {
    const ctx = this.context;
    const oscillator = this._source(ctx.createOscillator());
    oscillator.type = 'sine';
    oscillator.frequency.setValueAtTime(frequency, when);
    oscillator.frequency.exponentialRampToValueAtTime(endFrequency, when + duration);
    const envelope = this._node(ctx.createGain());
    envelope.gain.setValueAtTime(0, when);
    envelope.gain.linearRampToValueAtTime(amplitude, when + attack);
    envelope.gain.exponentialRampToValueAtTime(.0001, when + duration);
    envelope.gain.linearRampToValueAtTime(0, when + duration + .04);
    const panner = this._pan(position);
    oscillator.connect(envelope);
    envelope.connect(panner);
    panner.connect(this.ambienceInput);
    this._cleanOnEnd(oscillator, [envelope, panner]);
    oscillator.start(when);
    oscillator.stop(when + duration + .06);
  }

  _combatBeat(when, step) {
    const bus = this.combatBus;
    const riff = [26,26,null,26,29,26,31,null,26,26,38,26,33,null,31,29,
      26,26,null,26,29,31,26,26,26,null,38,33,31,29,28,null];
    const note = riff[step];
    if (note !== null) {
      this._tone(midi(note), when, .12, .09, 'sawtooth', -.28, midi(note) * .995, bus);
      this._tone(midi(note + 7), when, .085, .045, 'sawtooth', .28, midi(note + 7), bus);
      this._tone(midi(note - 12), when, .16, .06, 'sine', 0, midi(note - 12), bus);
    }
    if ([0,3,8,10,16,19,24,27].includes(step)) {
      this._tone(135, when, .22, .22, 'sine', 0, 42, bus);
      this._noise(when, .035, .07, 2600, 0, 'highpass', .002, bus);
    }
    if (step % 8 === 4) {
      this._noise(when, .16, .16, 2600, .06, 'highpass', .002, bus);
      this._tone(185, when, .11, .09, 'triangle', .06, 115, bus);
    }
    if (step % 2 === 0 || this.threat > .75) this._noise(when, step % 8 === 6 ? .13 : .04, .035, 6300, -.32, 'highpass', .001, bus);
    if (step === 0) this._noise(when, .6, .035, 5600, .38, 'highpass', .002, bus);
  }

  _footstep(sprinting, sneaking = false) {
    const now = this.context.currentTime;
    this._stepSide *= -1;
    const position = this._stepSide * 0.15;
    const amplitude = sneaking ? .018 : sprinting ? 0.11 : 0.076;
    this._noise(now, 0.13, amplitude, 420 + this._rand() * 260, position, "lowpass", 0.008);
    this._tone(95 + this._rand() * 18, now, 0.12, amplitude * 0.52, "sine", position, 48);
  }

  _tone(frequency, when, duration, amplitude, type = "sine", position = 0, endFrequency = frequency, destination = this.bus) {
    const ctx = this.context;
    const oscillator = this._source(ctx.createOscillator());
    oscillator.type = type;
    oscillator.frequency.setValueAtTime(frequency, when);
    if (frequency !== endFrequency) {
      oscillator.frequency.exponentialRampToValueAtTime(Math.max(20, endFrequency), when + duration);
    }
    const envelope = this._node(ctx.createGain());
    envelope.gain.setValueAtTime(0, when);
    envelope.gain.linearRampToValueAtTime(amplitude, when + Math.min(0.025, duration * 0.12));
    envelope.gain.exponentialRampToValueAtTime(0.0001, when + duration);
    envelope.gain.linearRampToValueAtTime(0, when + duration + 0.025);
    const panner = this._pan(position);
    oscillator.connect(envelope);
    envelope.connect(panner);
    panner.connect(destination);
    if (destination === this.bus) panner.connect(this.reverb);
    this._cleanOnEnd(oscillator, [envelope, panner]);
    oscillator.start(when);
    oscillator.stop(when + duration + 0.04);
  }

  _noise(when, duration, amplitude, frequency, position, filterType = "bandpass", attack = 0.012, destination = this.bus) {
    const ctx = this.context;
    const source = this._source(ctx.createBufferSource());
    source.buffer = this.noiseBuffer;
    source.loop = true;
    const filter = this._node(ctx.createBiquadFilter());
    filter.type = filterType;
    filter.frequency.value = frequency;
    filter.Q.value = 0.6;
    const envelope = this._node(ctx.createGain());
    envelope.gain.setValueAtTime(0, when);
    envelope.gain.linearRampToValueAtTime(amplitude, when + Math.min(attack, duration * 0.35));
    envelope.gain.exponentialRampToValueAtTime(0.0001, when + duration);
    envelope.gain.linearRampToValueAtTime(0, when + duration + 0.02);
    const panner = this._pan(position);
    source.connect(filter);
    filter.connect(envelope);
    envelope.connect(panner);
    panner.connect(destination);
    if (destination === this.bus) panner.connect(this.reverb);
    this._cleanOnEnd(source, [filter, envelope, panner]);
    source.start(when, this._rand() * 1.5);
    source.stop(when + duration + 0.04);
  }

  _cleanOnEnd(source, nodes) {
    source.onended = () => {
      for (const node of [source, ...nodes]) {
        node.disconnect();
        this._nodes.delete(node);
      }
      this._sources.delete(source);
      source.onended = null;
    };
  }
}

const DRONES = [37.0, 37.31, 56.73, 83.17, 113.91];
// Lift the score by 3.5 dB after its effects; keep saved volume, SFX and limiter.
const MUSIC_BOOST = 1.5;

function midi(note) {
  return 440 * Math.pow(2, (note - 69) / 12);
}

function clamp(value) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? Math.min(1, Math.max(0, numeric)) : 0;
}
