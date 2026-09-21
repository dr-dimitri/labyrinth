import { test, expect } from '@playwright/test';

// Two full ladder animations must render on Chromium's CPU fallback in CI.
// A smaller desktop viewport keeps this input-driven test within three minutes;
// native visual checks cover the full-resolution, high-quality presentation.
test.use({ viewport: { width: 960, height: 720 } });

test('larger expeditions support a visible, pausable climb up and back down', async ({ page }) => {
  test.setTimeout(180_000);
  const eventually = expect.configure({ timeout: 60_000 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  // Balanced rendering keeps software Chromium responsive. World configuration
  // and navigation are exercised through the same controls the player uses.
  await page.addInitScript(() => {
    if (!localStorage.getItem('nachtgang-settings-v1')) {
      localStorage.setItem('nachtgang-settings-v1', JSON.stringify({ quality: 'balanced', volume: 0 }));
    }
  });
  await page.goto('/expedition.html');
  await eventually(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#size')).toHaveValue('25');
  await expect(page.locator('#levels')).toHaveValue('3');
  await page.locator('#size').focus();
  await page.keyboard.press('End');
  await expect(page.locator('#size-value')).toHaveText('51 × 51');
  await page.keyboard.press('Home');
  await expect(page.locator('#size-value')).toHaveText('9 × 9');
  await page.locator('#levels').selectOption('2');
  await expect(page.locator('#expedition-summary')).toContainText('2 Ebenen');
  await page.locator('#levels').selectOption('3');
  await page.locator('[data-danger="calm"]').click();
  await page.locator('#seed').fill('VERTICAL-EXPEDITION');
  await page.locator('#start-button').click();
  await eventually(page.locator('#hud')).toBeVisible();
  await expect(page.locator('#floor-status')).toHaveText(/^EBENE 1 \/ 3/);
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');

  // The first ladder is deliberately on a straight, visible path from spawn.
  await page.keyboard.down('KeyW');
  try {
    await eventually(page.locator('#interaction-label')).toContainText('Nach oben klettern');
  } finally {
    await page.keyboard.up('KeyW');
  }
  await page.keyboard.press('KeyE');
  await eventually(page.locator('#floor-status')).toHaveText(/^KLETTERE ZU EBENE 2 · \d+ %$/);
  const firstProgress = await page.locator('#floor-status').textContent();
  await page.keyboard.press('KeyQ');
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await eventually(page.locator('#floor-status')).not.toHaveText(firstProgress);
  await expect(page.locator('#floor-status')).toHaveClass(/climbing/);
  await page.keyboard.press('Escape');
  await expect(page.locator('#pause-screen')).toBeVisible();
  const pausedProgress = await page.locator('#floor-status').textContent();
  const pausedTime = await page.locator('#timer').textContent();
  await page.waitForTimeout(1100);
  await expect(page.locator('#floor-status')).toHaveText(pausedProgress);
  await expect(page.locator('#timer')).toHaveText(pausedTime);
  await page.locator('#resume-button').click();
  await eventually(page.locator('#floor-status')).toHaveText(/^EBENE 2 \/ 3/);
  await expect(page.locator('#floor-status')).not.toHaveClass(/climbing/);
  await expect(page.locator('#slot-0-count')).toHaveText('30 / 180');
  await page.keyboard.press('KeyM');
  await expect(page.locator('#map-panel')).toBeVisible();
  await eventually(page.locator('#map-floor-label')).toHaveText('EBENE 2 / 3');

  await eventually(page.locator('#interaction-label')).toContainText('Nach unten klettern');
  await page.keyboard.press('KeyE');
  await eventually(page.locator('#floor-status')).toHaveText(/^KLETTERE ZU EBENE 1 · \d+ %$/);
  await eventually(page.locator('#floor-status')).toHaveText(/^EBENE 1 \/ 3/);
  await eventually(page.locator('#map-floor-label')).toHaveText('EBENE 1 / 3');
  await expect(page.locator('#health-value')).toHaveText('100');
  await page.keyboard.press('Escape');
  await page.locator('#leave-button').click();
  await expect(page.locator('#menu')).toBeVisible();
  await page.reload();
  await eventually(page.locator('#loading')).toHaveClass(/done/);
  await expect(page.locator('#size')).toHaveValue('9');
  await expect(page.locator('#levels')).toHaveValue('3');
  await expect(page.locator('#seed')).toHaveValue('VERTICAL-EXPEDITION');
  await expect(page.locator('#expedition-summary')).toContainText('3 Ebenen');
  expect(errors).toEqual([]);
});
