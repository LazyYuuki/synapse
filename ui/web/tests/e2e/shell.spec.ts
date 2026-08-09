import { expect, test } from '@playwright/test';
import { AxeBuilder } from '@axe-core/playwright';

test('operator shell exposes the initial regions', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByRole('heading', { name: 'Run setup' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Current run' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Activity' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Connect', exact: true })).toBeEnabled();
  await expect(page.getByRole('button', { name: 'Start run' })).toBeDisabled();
});

test('shell has no horizontal overflow at its configured viewport', async ({ page }) => {
  await page.goto('/');

  const hasOverflow = await page
    .locator('html')
    .evaluate((root) => root.scrollWidth > root.clientWidth);
  expect(hasOverflow).toBe(false);
});

test('conversation uses a locked panel with its own scroll viewport', async ({ page }) => {
  await page.goto('/');

  const layout = await page.locator('.chat-panel').evaluate((panel) => {
    const timeline = panel.querySelector<HTMLElement>('.chat-timeline');
    if (!timeline) throw new Error('chat timeline missing');
    return {
      panelHeight: panel.getBoundingClientRect().height,
      panelOverflow: getComputedStyle(panel).overflow,
      timelineHeight: timeline.getBoundingClientRect().height,
      timelineOverflowY: getComputedStyle(timeline).overflowY,
    };
  });

  expect(layout.panelHeight).toBeGreaterThanOrEqual(520);
  expect(layout.panelHeight).toBeLessThanOrEqual(780);
  expect(layout.panelOverflow).toBe('hidden');
  expect(layout.timelineHeight).toBeGreaterThan(0);
  expect(layout.timelineOverflowY).toBe('scroll');
});

test('expanded Budget remains reachable without horizontal overflow', async ({ page }) => {
  await page.goto('/');
  await page.getByText('Advanced budget limits').click();
  await expect(page.getByLabel('Maximum turns')).toBeVisible();

  const hasOverflow = await page
    .locator('html')
    .evaluate((root) => root.scrollWidth > root.clientWidth);
  expect(hasOverflow).toBe(false);
});

test('connection controls remain inside the viewport at intermediate widths', async ({ page }) => {
  for (const width of [320, 561, 590, 620, 768, 1024]) {
    await page.setViewportSize({ width, height: 900 });
    await page.goto('/');
    const shell = page.locator('.console-shell');
    const shellBox = await shell.boundingBox();
    const shellClips = await shell.evaluate((element) => element.scrollWidth > element.clientWidth);
    expect(shellClips, `shell does not clip at ${width}px`).toBe(false);
    for (const name of ['Connect', 'Reconnect', 'Disconnect']) {
      const box = await page.getByRole('button', { name, exact: true }).boundingBox();
      expect(box, `${name} has a box at ${width}px`).not.toBeNull();
      expect(box?.x ?? -1).toBeGreaterThanOrEqual(shellBox?.x ?? 0);
      expect((box?.x ?? 0) + (box?.width ?? width + 1)).toBeLessThanOrEqual(
        (shellBox?.x ?? 0) + (shellBox?.width ?? width),
      );
    }
  }
});

test('required controls, disclosure, and keyboard focus remain accessible', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByLabel(/Workspace path/)).toHaveAttribute('required', '');
  await expect(page.getByLabel(/Prompt/)).toHaveAttribute('required', '');
  await expect(page.getByRole('button', { name: 'Start run' })).toHaveAttribute(
    'aria-describedby',
    'start-reason',
  );

  await page.getByLabel('API socket').focus();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('button', { name: 'Connect', exact: true })).toBeFocused();
  const outline = await page
    .getByRole('button', { name: 'Connect', exact: true })
    .evaluate((element) => getComputedStyle(element).outlineStyle);
  expect(outline).not.toBe('none');

  await page.getByText('Advanced budget limits').focus();
  await page.keyboard.press('Enter');
  await expect(page.getByLabel('Maximum turns')).toBeVisible();
  await expect(page.locator('[aria-live="polite"]')).not.toHaveCount(0);
});

test('initial console has no detectable accessibility violations', async ({ page }) => {
  await page.goto('/');

  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test('reduced motion disables smooth output scrolling', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');

  const scrollBehavior = await page
    .locator('.chat-timeline')
    .evaluate((element) => getComputedStyle(element).scrollBehavior);
  expect(scrollBehavior).toBe('auto');
});
