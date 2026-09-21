import { test, expect } from '@playwright/test';

test.use({ viewport: { width: 960, height: 640 } });

test('short fire taps survive frames without a simulation tick and clear on pause, focus loss and restart', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    localStorage.setItem('nachtgang-blacksite-settings-v1', JSON.stringify({ difficulty: 'easy', quality: 'balanced', volume: 0 }));
    // Own the frame clock so both input edges arrive before the next frame,
    // including a frame shorter than the simulation's 1/120-second tick.
    let now = 0, nextFrame;
    performance.now = () => now;
    window.requestAnimationFrame = callback => { nextFrame = callback; return 1; };
    window.advanceGameFrame = milliseconds => {
      now += milliseconds;
      const callback = nextFrame; nextFrame = null; callback(now);
    };
    // Pointer capture is covered by the regular gameplay tests. Avoid its
    // asynchronous focus events interfering with the controlled frame clock.
    HTMLCanvasElement.prototype.requestPointerLock = () => Promise.resolve();
  });
  await page.goto('/');
  await expect(page.locator('#start-button')).toBeEnabled();

  const results = await page.evaluate(() => {
    const key = (type, code) => document.dispatchEvent(new KeyboardEvent(type, { code, bubbles: true }));
    const tapKey = code => { key('keydown', code); key('keyup', code); };
    const tapMouse = () => {
      document.querySelector('#world canvas').dispatchEvent(new MouseEvent('mousedown', { button: 0, bubbles: true }));
      document.dispatchEvent(new MouseEvent('mouseup', { button: 0, bubbles: true }));
    };
    const click = id => document.getElementById(id).click();
    const ammo = () => document.getElementById('ammo').textContent;
    const step = window.advanceGameFrame;
    const settle = () => { for (let i = 0; i < 14; i++) step(100); };
    const result = {};
    click('start-button'); tapKey('Digit2'); step(0);
    result.initial = ammo();

    tapKey('KeyQ'); step(1);
    result.beforeSimulationTick = ammo();
    step(9); result.keyboardTap = ammo();
    settle(); result.afterRelease = ammo();
    tapMouse(); step(10); result.mouseTap = ammo();
    settle();

    // A rejected shot during reload must not become a delayed automatic shot.
    tapKey('KeyR'); tapKey('KeyQ'); step(10);
    for (let i = 0; i < 30; i++) step(100);
    result.afterReload = ammo();

    tapKey('KeyQ'); tapKey('Escape'); step(100);
    click('resume-button'); step(10); result.afterPause = ammo();
    tapMouse(); window.dispatchEvent(new Event('blur')); step(100);
    click('resume-button'); step(10); result.afterFocusLoss = ammo();

    tapMouse(); tapKey('Escape'); click('leave-button'); click('start-button');
    step(10); result.afterRestart = ammo();
    key('keydown', 'KeyQ');
    for (let i = 0; i < 5; i++) step(100);
    key('keyup', 'KeyQ'); result.heldFire = ammo();
    tapKey('Escape');
    return result;
  });
  expect(results).toEqual({
    initial: '05', beforeSimulationTick: '05', keyboardTap: '04',
    afterRelease: '04', mouseTap: '03', afterReload: '05',
    afterPause: '05', afterFocusLoss: '05', afterRestart: '30', heldFire: '25',
  });
  expect(errors).toEqual([]);
});
