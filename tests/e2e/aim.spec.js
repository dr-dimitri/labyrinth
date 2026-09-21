import { test, expect } from '@playwright/test';

// Chromium's full headless browser supports real pointer lock; its lightweight
// headless shell rejects even a direct button-triggered request on macOS.
test.use({ channel: 'chromium', viewport: { width: 960, height: 720 } });

async function startExpedition(page, { fallback = false } = {}) {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.addInitScript(({ fallback }) => {
    localStorage.setItem('nachtgang-settings-v1', JSON.stringify({ quality: 'balanced', volume: 0 }));
    // Model a browser without mouse capture. All later inputs use Playwright's
    // real mouse/keyboard APIs and the same public controls as a player.
    if (fallback) Object.defineProperty(Element.prototype, 'requestPointerLock', { configurable: true, value: undefined });
  }, { fallback });
  await page.goto('/expedition.html');
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await page.locator('#size').focus();
  await page.keyboard.press('Home');
  await page.locator('#levels').selectOption('1');
  await page.locator('[data-danger="calm"]').click();
  await page.locator('#seed').fill('INDEPENDENT-AIM');
  await page.locator('#start-button').click();
  await expect(page.locator('#hud')).toBeVisible();
  await expect(page.locator('#crosshair')).toBeVisible();
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await expect(page.locator('#slot-1-count')).toHaveText('3');
  await expect.poll(() => page.evaluate(() => !!document.pointerLockElement)).toBe(!fallback);
  return errors;
}

async function reticle(page) {
  return page.locator('#crosshair').evaluate(node => {
    const box = node.getBoundingClientRect();
    return { x: box.x + box.width / 2, y: box.y + box.height / 2, left: node.style.left, top: node.style.top };
  });
}

async function mapImage(page) {
  return page.locator('#minimap').evaluate(canvas => canvas.toDataURL());
}

async function magazine(page) {
  return Number((await page.locator('#slot-0-count').textContent()).split(' / ')[0]);
}

test('captured mouse aims independently while keyboard turns, and mouse fire survives a pause safely', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = await startExpedition(page);
  const center = await reticle(page);
  expect(center.x).toBeCloseTo(480, 0);
  expect(center.y).toBeCloseTo(360, 0);
  await page.keyboard.press('KeyM');
  const initialMap = await mapImage(page);
  await page.mouse.move(300, 260);
  await page.mouse.move(590, 310);
  await expect.poll(async () => {
    const point = await reticle(page);
    return Math.hypot(point.x - center.x, point.y - center.y);
  }).toBeGreaterThan(40);
  const aimed = await reticle(page);
  expect(aimed.x).toBeGreaterThan(0);
  expect(aimed.x).toBeLessThan(960);
  expect(aimed.y).toBeGreaterThan(0);
  expect(aimed.y).toBeLessThan(720);
  // Reopening the visible map redraws its player arrow immediately. A mouse
  // aim adjustment must leave that arrow's viewing direction unchanged.
  await page.keyboard.press('KeyM');
  await page.keyboard.press('KeyM');
  expect(await mapImage(page)).toBe(initialMap);
  await page.keyboard.down('ArrowRight');
  try {
    await expect.poll(() => mapImage(page)).not.toBe(initialMap);
  } finally {
    await page.keyboard.up('ArrowRight');
  }
  expect(await reticle(page)).toEqual(aimed);
  const scroll = await page.evaluate(() => ({ x: scrollX, y: scrollY }));
  for (const key of ['PageUp', 'PageDown']) {
    await page.keyboard.down(key);
    await page.waitForTimeout(250);
    await page.keyboard.up(key);
  }
  expect(await page.evaluate(() => ({ x: scrollX, y: scrollY }))).toEqual(scroll);
  expect(await reticle(page)).toEqual(aimed);
  await page.keyboard.press('Space');
  expect(await reticle(page)).toEqual(center);

  await page.mouse.move(680, 280);
  const beforePause = await reticle(page);
  await page.mouse.down({ button: 'left' });
  await expect.poll(() => magazine(page)).toBeLessThan(29);
  await page.keyboard.press('Escape');
  await expect(page.locator('#pause-screen')).toBeVisible();
  await page.mouse.up({ button: 'left' });
  const pausedAmmo = await page.locator('#slot-0-count').textContent();
  await page.mouse.move(180, 150);
  await page.waitForTimeout(500);
  expect(await reticle(page)).toEqual(beforePause);
  await expect(page.locator('#slot-0-count')).toHaveText(pausedAmmo);
  await page.locator('#resume-button').click();
  await expect(page.locator('#pause-screen')).not.toBeVisible();
  await expect.poll(() => page.evaluate(() => !!document.pointerLockElement)).toBe(true);
  expect(await reticle(page)).toEqual(beforePause);
  await page.waitForTimeout(500);
  await expect(page.locator('#slot-0-count')).toHaveText(pausedAmmo);
  await page.mouse.click(480, 360, { button: 'right' });
  await expect(page.locator('#slot-1-count')).toHaveText('2');
  await expect(page.locator('#health-value')).toHaveText('100');
  await expect(page.locator('#error-panel')).not.toBeVisible();
  expect(errors).toEqual([]);
});

test('trackpad fallback moves the crosshair directly, clamps edges, and adapts to resizing', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = await startExpedition(page, { fallback: true });
  await page.mouse.move(620, 280);
  await expect.poll(async () => Math.abs((await reticle(page)).x - 620)).toBeLessThan(1);
  expect((await reticle(page)).y).toBeCloseTo(280, 0);
  const aimed = await reticle(page);
  await page.keyboard.press('KeyM');
  const initialMap = await mapImage(page);
  await page.keyboard.down('ArrowLeft');
  try {
    await expect.poll(() => mapImage(page)).not.toBe(initialMap);
  } finally {
    await page.keyboard.up('ArrowLeft');
  }
  expect(await reticle(page)).toEqual(aimed);
  await page.mouse.move(2, 718);
  const edge = await reticle(page);
  expect(edge.x).toBeGreaterThan(10);
  expect(edge.y).toBeLessThan(710);
  await page.keyboard.press('Space');
  expect((await reticle(page)).x).toBeCloseTo(480, 0);
  expect((await reticle(page)).y).toBeCloseTo(360, 0);

  await page.setViewportSize({ width: 840, height: 640 });
  await page.mouse.move(540, 250);
  await expect.poll(async () => Math.abs((await reticle(page)).x - 540)).toBeLessThan(1);
  expect((await reticle(page)).y).toBeCloseTo(250, 0);
  await page.mouse.click(540, 250, { button: 'left' });
  await expect.poll(() => magazine(page)).toBeLessThan(30);
  await page.mouse.click(540, 250, { button: 'right' });
  await expect(page.locator('#slot-1-count')).toHaveText('2');
  await page.keyboard.press('Space');
  expect((await reticle(page)).x).toBeCloseTo(420, 0);
  expect((await reticle(page)).y).toBeCloseTo(320, 0);
  expect(await page.evaluate(() => !!document.pointerLockElement)).toBe(false);
  await expect(page.locator('#health-value')).toHaveText('100');
  await expect(page.locator('#error-panel')).not.toBeVisible();
  expect(errors).toEqual([]);
});
