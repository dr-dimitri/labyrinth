import { test, expect } from '@playwright/test';

test('configure, explore, pause, resume and retain an expedition without runtime errors', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  // Native visual QA covers high detail; software-rendered Chromium uses the
  // public balanced preference to keep interaction checks fast in CI.
  await page.addInitScript(() => {
    if (!localStorage.getItem('nachtgang-settings-v1')) localStorage.setItem('nachtgang-settings-v1', JSON.stringify({ quality: 'balanced' }));
  });
  await page.goto('/expedition.html');
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#world canvas')).toBeVisible();
  await expect(page.locator('#error-panel')).not.toBeVisible();
  await expect(page.locator('#biome option[value="catacombs"]')).toBeEnabled();
  await expect(page.locator('#biome option[value="ruins"]')).toBeDisabled();
  await expect(page.locator('#biome option[value="mine"]')).toBeDisabled();
  await expect(page.locator('#biome option[value="ruins"]')).toContainText('erfolgreichen Expedition');
  await expect(page.locator('#tool-0')).toHaveValue('machinegun');
  await expect(page.locator('#tool-1')).toHaveValue('rocket');
  await expect(page.locator('#tool-0 option[value="laser"]')).toBeEnabled();
  await page.locator('#help-button').click();
  await expect(page.locator('#help-dialog')).toBeVisible();
  await page.locator('#understood-button').click();
  await expect(page.locator('#help-dialog')).not.toBeVisible();

  await page.locator('#size').focus();
  await page.keyboard.press('Home');
  await page.locator('#complexity').focus();
  await page.keyboard.press('End');
  await expect(page.locator('#size-value')).toHaveText('9 × 9');
  await expect(page.locator('#complexity-value')).toHaveText('Unerbittlich');
  await page.locator('[data-danger="calm"]').click();
  await page.locator('#seed').fill('TEST-EXPLORATION');
  await page.locator('#sound-toggle').click();
  await page.locator('#sound-toggle').click();
  await expect(page.locator('#sound-toggle')).toHaveAttribute('aria-pressed', 'false');
  await page.locator('#start-button').click();
  await expect(page.locator('#hud')).toBeVisible();
  await expect(page.locator('#menu')).not.toBeVisible();
  await expect(page.locator('#relic-count')).toHaveText('0 / 3');
  await expect(page.locator('#sound-toggle')).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('#slot-0-name')).toHaveText('Maschinengewehr');
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await expect(page.locator('#slot-1-count')).toHaveText('3');
  await page.keyboard.down('KeyQ');
  await expect.poll(async () => Number((await page.locator('#slot-0-count').textContent()).split(' / ')[0])).toBeLessThan(28);
  await expect(page.locator('#noise-label')).toHaveText('SEHR LAUT');
  await page.keyboard.up('KeyQ');
  const afterFiring = (await page.locator('#slot-0-count').textContent()).split(' / ').map(Number);
  expect(afterFiring[1]).toBeLessThan(180);
  expect(afterFiring[1] - afterFiring[0]).toBe(150);
  await page.keyboard.press('KeyT');
  await expect(page.locator('#slot-0-count')).toContainText('Lädt');
  await expect(page.locator('#slot-0-count')).toHaveText(`30 / ${afterFiring[1]}`, { timeout: 40_000 });
  await page.keyboard.press('KeyR');
  await expect(page.locator('#slot-1-count')).toHaveText('2');
  await expect(page.locator('#health-value')).toHaveText('100');
  await expect(page.locator('#timer')).not.toHaveText('00:00');
  await page.keyboard.press('KeyM');
  await expect(page.locator('#map-panel')).toBeVisible();
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(600);
  await page.keyboard.up('KeyW');
  await page.keyboard.press('KeyF');
  await expect(page.locator('#message')).toHaveText('Das Licht ist erloschen.');
  await page.keyboard.press('KeyF');
  await page.keyboard.down('Escape');
  await expect(page.locator('#pause-screen')).toBeVisible();
  await page.keyboard.down('Escape'); // A held key generates repeat=true, not another toggle.
  await expect(page.locator('#pause-screen')).toBeVisible();
  await page.keyboard.up('Escape');
  const timer = await page.locator('#timer').textContent();
  await page.waitForTimeout(1100);
  await expect(page.locator('#timer')).toHaveText(timer);
  await page.locator('#resume-button').click();
  await expect(page.locator('#pause-screen')).not.toBeVisible();
  await page.keyboard.press('Escape');
  await page.locator('#leave-button').click();
  await expect(page.locator('#menu')).toBeVisible();
  await page.reload();
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#seed')).toHaveValue('TEST-EXPLORATION');
  await expect(page.locator('#size')).toHaveValue('9');
  await expect(page.locator('#complexity')).toHaveValue('100');
  await expect(page.locator('[data-danger="calm"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#quality')).toHaveValue('balanced');
  expect(errors).toEqual([]);
});

test('laser equipment, rescue briefing, journal pause and persistent unlocks work together', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  // Exercise the public saved-profile format, including restored discoveries.
  // Gameplay itself is driven only through the visible controls and keyboard.
  await page.addInitScript(() => {
    if (!localStorage.getItem('nachtgang-settings-v1')) localStorage.setItem('nachtgang-settings-v1', JSON.stringify({ quality: 'balanced', volume: 0 }));
    if (!localStorage.getItem('nachtgang-profile-v1')) localStorage.setItem('nachtgang-profile-v1', JSON.stringify({
      version: 1, completedRuns: 1, failedRuns: 1, earned: 6,
      journal: ['Ein alter Kompass weist durch die Ruinen.'], processedRuns: ['saved-victory', 'saved-defeat'],
    }));
  });
  await page.goto('/expedition.html');
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#profile-summary')).toHaveText('1 Rückkehrten · 6 Fundstücke');
  await expect(page.locator('#biome option[value="ruins"]')).toBeEnabled();
  await expect(page.locator('#biome option[value="mine"]')).toBeDisabled();
  await expect(page.locator('#tool-0 option[value="flare"]')).toBeEnabled();
  await expect(page.locator('#tool-0 option[value="compass"]')).toBeEnabled();
  await page.locator('#biome').selectOption('ruins');
  await page.locator('#size').focus();
  await page.keyboard.press('Home');
  await page.locator('[data-danger="calm"]').click();
  await page.locator('#tab-mission').click();
  await page.locator('#mission').selectOption('rescue');
  await expect(page.locator('#mission-description')).toContainText('geleite');
  await page.locator('#tab-loadout').click();
  await page.locator('#tool-0').selectOption('laser');
  await expect(page.locator('#tool-1 option[value="laser"]')).toBeDisabled();
  await expect(page.locator('#expedition-summary')).toContainText('Lasergewehr');
  await page.locator('#start-button').click();
  await expect(page.locator('#hud')).toBeVisible();
  await expect(page.locator('#relic-count')).toHaveText('0 / 1');
  await expect(page.locator('.relic-glyph:not(.hidden)')).toHaveCount(1);
  await expect(page.locator('#slot-0-count')).toHaveText('80');
  await expect(page.locator('#biome-label')).toContainText('RUINEN');
  await page.keyboard.down('KeyQ');
  await expect.poll(async () => Number(await page.locator('#slot-0-count').textContent())).toBeLessThan(79);
  await expect.poll(async () => page.locator('#slot-0-heat').evaluate(node => parseFloat(node.style.width))).toBeGreaterThan(0);
  await page.keyboard.up('KeyQ');
  await page.keyboard.press('KeyJ');
  await expect(page.locator('#journal-dialog')).toBeVisible();
  await expect(page.locator('#journal-mission')).toContainText('Die letzte Spur');
  await expect(page.locator('#journal-entries')).toContainText('Ein alter Kompass weist durch die Ruinen.');
  await expect(page.locator('#unlock-list .locked')).toContainText(['Verlassene Mine']);
  const timer = await page.locator('#timer').textContent();
  const ammunition = await page.locator('#slot-0-count').textContent();
  const heat = await page.locator('#slot-0-heat').getAttribute('style');
  await page.waitForTimeout(1200);
  await expect(page.locator('#timer')).toHaveText(timer);
  await expect(page.locator('#slot-0-count')).toHaveText(ammunition);
  await expect(page.locator('#slot-0-heat')).toHaveAttribute('style', heat);
  await page.locator('#journal-back').click();
  await expect(page.locator('#journal-dialog')).not.toBeVisible();
  await expect(page.locator('#pause-screen')).not.toBeVisible();
  await expect(page.locator('#timer')).not.toHaveText(timer);
  await page.keyboard.press('Escape');
  await page.locator('#leave-button').click();
  await page.reload();
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#biome')).toHaveValue('ruins');
  await expect(page.locator('#mission')).toHaveValue('rescue');
  await expect(page.locator('#tool-0')).toHaveValue('laser');
  await expect(page.locator('#profile-summary')).toHaveText('1 Rückkehrten · 6 Fundstücke');
  await page.locator('#journal-button').click();
  await expect(page.locator('#journal-entries')).toContainText('Ein alter Kompass weist durch die Ruinen.');
  await expect(page.locator('#unlock-list .locked')).toContainText(['Verlassene Mine']);
  expect(errors).toEqual([]);
});

test('a missing photographic material shows a recoverable startup error', async ({ page }) => {
  await page.route('**/assets/textures/wall/color.jpg', route => route.abort('failed'));
  await page.goto('/expedition.html');
  await expect(page.locator('#error-panel')).toBeVisible();
  await expect(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#error-message')).toContainText('Grafikdateien');
  await expect(page.locator('#reload-button')).toBeEnabled();
});
