import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { savedSetting, useWindow } from '../support/jarvis.ts';

// Runs on the first-run target: Jarvis opens with --first-run on a Mac where
// it already has the microphone and Accessibility. No voice, no model.

test('first run: pick Hold fn, the granted permissions step past, Try it, Skip', { timeout: 60_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await useWindow(desktop, 'Set up Jarvis');
  await expect(screen.getByText('How should Jarvis listen?')).toBeVisible({ timeout: 15_000 });
  await screen.getByRole('button', /^Hold fn to talk/).tap();
  await screen.getByRole('button', 'Continue').tap();

  // With a wake-word engine in the build, an intro to Standby comes next.
  const intro = screen.getByText(/^Jarvis listens for/);
  const tryIt = screen.getByText('Try it');
  await expect(intro.or(tryIt).or(screen.getByText('Let Jarvis hear you'))).toBeVisible({ timeout: 10_000 });
  if (await intro.isVisible()) await screen.getByRole('button', 'Continue').tap();

  // Microphone and Accessibility are granted, so both steps move on by themselves.
  await expect(tryIt, 'Jarvis is missing the microphone or Accessibility: grant them once by hand').toBeVisible({ timeout: 10_000 });
  await expect(screen.getByText('Step 4 of 4')).toBeVisible();
  await expect(screen.getByText('Hold fn and say “Open Calculator”, then let go.')).toBeVisible();

  await screen.getByRole('button', 'Skip').tap();
  await expect.poll(async () => (await desktop.windows()).map((window) => window.title)).not.toContain('Set up Jarvis');
  await expect.poll(() => savedSetting('firstRunCompleted')).toBe('1');
  await expect.poll(() => savedSetting('listeningMode')).toBe('pushToTalk');
});
