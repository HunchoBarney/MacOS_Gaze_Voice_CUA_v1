import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { CALCULATOR, count, holdFnAndSay, openActivity, quit, sleep } from '../support/jarvis.ts';

// Hold fn to talk. The oracle is the Mac, not Jarvis: one Calculator process.
// One OpenAI Realtime turn on the owner's key.

test.afterEach(async () => {
  await quit(CALCULATOR);
});

test('hold Fn and say "open Calculator": Calculator opens, once', { timeout: 90_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  expect(await count(CALCULATOR), 'Calculator was already open').toBe(0);

  await holdFnAndSay('Open Calculator.');

  await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);
  await sleep(3_000);
  expect(await count(CALCULATOR)).toBe(1);
});
