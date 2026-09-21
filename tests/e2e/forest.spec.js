import { test, expect } from '@playwright/test';

// Use full Chromium: its real mouse capture keeps keyboard-driven movement at
// normal speed on macOS, including when a trackpad is used for aiming.
test.use({ channel: 'chromium', viewport: { width: 960, height: 720 } });

async function openPlanner(page) {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.addInitScript(() => {
    if (!localStorage.getItem('nachtgang-settings-v1')) {
      localStorage.setItem('nachtgang-settings-v1', JSON.stringify({ quality: 'balanced', volume: 0 }));
    }
  });
  await page.goto('/expedition.html');
  await expect(page.locator('#loading')).toHaveClass(/done/);
  return errors;
}

test('the unlocked forest preserves dungeon floors and its saved terrain settings across reloads', async ({ page }) => {
  const errors = await openPlanner(page);
  await expect(page.locator('#profile-summary')).toHaveText('0 Rückkehrten · 0 Fundstücke');
  await page.locator('#levels').selectOption('2');
  await page.locator('#forest-button').click();
  await expect(page.locator('#biome')).toHaveValue('forest');
  await expect(page.locator('#levels')).toHaveValue('1');
  await expect(page.locator('#levels')).toBeDisabled();
  await expect(page.locator('label[for="levels"]')).toHaveText('Gelände');
  await expect(page.locator('#expedition-summary')).toContainText('Dunkelwald · Schlucht & 2 Höhlen');
  await expect(page.locator('#biome-description')).toContainText('Wölfe und Orks');
  await page.locator('#size').focus();
  await page.keyboard.press('End');
  await expect(page.locator('#size-value')).toHaveText('51 × 51');
  await page.locator('#seed').fill('FOREST-PERSISTENCE');
  await page.locator('[data-danger="calm"]').click();
  await page.reload();
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#biome')).toHaveValue('forest');
  await expect(page.locator('#levels')).toBeDisabled();
  await expect(page.locator('#size')).toHaveValue('51');
  await expect(page.locator('#seed')).toHaveValue('FOREST-PERSISTENCE');
  await expect(page.locator('[data-danger="calm"]')).toHaveAttribute('aria-pressed', 'true');
  await page.locator('#biome').selectOption('catacombs');
  await expect(page.locator('#levels')).toBeEnabled();
  await expect(page.locator('#levels')).toHaveValue('2');
  await expect(page.locator('label[for="levels"]')).toHaveText('Stockwerke');
  await expect(page.locator('#expedition-summary')).toContainText('2 Ebenen');
  await page.locator('#forest-button').click();
  await expect(page.locator('#levels')).toHaveValue('1');
  await expect(page.locator('#levels')).toBeDisabled();
  expect(errors).toEqual([]);
});

test('forest players walk to a friendly elf, refill both weapons, and keep supply cooldown frozen while paused', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = await openPlanner(page);
  await page.locator('#forest-button').click();
  await expect(page.locator('#size')).toHaveValue('25');
  await page.locator('[data-danger="calm"]').click();
  await page.locator('#seed').fill('FOREST-FRIENDS');
  await page.locator('#start-button').click();
  await expect(page.locator('#hud')).toBeVisible();
  await expect.poll(() => page.evaluate(() => Boolean(document.pointerLockElement))).toBe(true);
  await expect(page.locator('#biome-label')).toContainText('DUNKELWALD');
  await expect(page.locator('#floor-status')).toHaveText(/^DUNKELWALD · TIEFE \d+,\d m$/);
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await expect(page.locator('#slot-1-count')).toHaveText('3');

  // The first camp is diagonally adjacent to spawn and the initial keyboard
  // viewing direction follows +X. This is real movement through the terrain.
  await page.keyboard.down('KeyW');
  await page.keyboard.down('KeyD');
  try {
    await expect(page.locator('#interaction-label')).toHaveText('Munitionsvorrat ist vollständig');
  } finally {
    await page.keyboard.up('KeyW');
    await page.keyboard.up('KeyD');
  }
  await expect(page.locator('#interaction-description')).toContainText('Aelwen');
  await page.keyboard.press('KeyE');
  await expect(page.locator('#interaction-label')).toHaveText('Munitionsvorrat ist vollständig');
  await page.keyboard.press('KeyQ');
  await expect.poll(async () => Number((await page.locator('#slot-0-count').textContent()).split(' / ')[0])).toBeLessThan(30);
  await page.keyboard.press('KeyR');
  await expect(page.locator('#slot-1-count')).toHaveText('2');
  await expect(page.locator('#interaction-label')).toHaveText('Munition bei der Elfe auffüllen');
  await page.keyboard.press('KeyE');
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await expect(page.locator('#slot-1-count')).toHaveText('3');
  await expect(page.locator('#interaction-label')).toHaveText(/^Nachschub in \d+ s$/);
  await page.keyboard.press('Escape');
  await expect(page.locator('#pause-screen')).toBeVisible();
  const pausedSupply = await page.locator('#interaction-label').textContent();
  const pausedClock = await page.locator('#timer').textContent();
  await page.waitForTimeout(1200);
  await expect(page.locator('#interaction-label')).toHaveText(pausedSupply);
  await expect(page.locator('#timer')).toHaveText(pausedClock);
  await page.locator('#resume-button').click();
  await expect(page.locator('#pause-screen')).not.toBeVisible();
  await expect(page.locator('#interaction-label')).not.toHaveText(pausedSupply);
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await expect(page.locator('#slot-1-count')).toHaveText('3');
  await expect(page.locator('#health-value')).toHaveText('100');
  await page.keyboard.press('KeyM');
  await expect(page.locator('#map-panel')).toBeVisible();
  await expect(page.locator('#map-floor-label')).toHaveText('DUNKELWALD · WALD & TIEFEN');
  await expect(page.locator('#map-note')).toContainText('Elfenlager');
  await expect(page.locator('#map-note')).toContainText('Höhlenzugang');
  await page.keyboard.press('KeyJ');
  await expect(page.locator('#journal-dialog')).toBeVisible();
  await expect(page.locator('#journal-mission')).toContainText('begehbarer Schlucht und zwei Durchgangshöhlen');
  await expect(page.locator('#journal-mission')).toContainText('freundlichen Elfen');
  await expect(page.locator('#journal-objectives')).toContainText('Tropfsteingrotte');
  await expect(page.locator('#journal-objectives')).toContainText('Wurzelhöhle');
  await expect(page.locator('#journal-entries')).toContainText('erneuern alle 45 Sekunden');
  await page.locator('#journal-back').click();
  await expect(page.locator('#journal-dialog')).not.toBeVisible();
  await expect(page.locator('#error-panel')).not.toBeVisible();
  expect(errors).toEqual([]);
});
