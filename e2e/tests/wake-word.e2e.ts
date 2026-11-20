import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { CALCULATOR, count, openActivity, quit, say, sleep } from '../support/jarvis.ts';

// Jarvis waits for "Hey Jarvis", as on every flow that speaks. A command
// without the name must do nothing (nothing leaves the Mac); the same command
// after the name opens Calculator. One Realtime turn.

test.afterEach(async () => {
  await quit(CALCULATOR);
});

test('Standby ignores a command without "Hey Jarvis" and runs it after', { timeout: 90_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  expect(await count(CALCULATOR), 'Calculator was already open').toBe(0);

  await say('Open Calculator.');
  await sleep(6_000);
  expect(await count(CALCULATOR), 'Jarvis acted without its wake phrase').toBe(0);

  await say('Hey Jarvis, open Calculator.');
  await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);
});
