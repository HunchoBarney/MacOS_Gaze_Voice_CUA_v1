import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { BOARD, LIST_END, command, openActivity, openList, quit, sleep } from '../support/jarvis.ts';

// "Keep scrolling" starts a scroll that repeats until something stops it, and
// "stop" said mid-scroll has to end it with nothing landing afterwards. Scroll
// down, keep scrolling and stop are all decided on the Mac, with no model
// call, so the one live part is hearing the lines. The list records its own
// scroll offset, so the check is the fixture's record, not Jarvis's.

test.afterEach(async () => {
  await quit(BOARD);
});

test('"keep scrolling", then "stop" mid-scroll: the list stops and nothing moves it later', { timeout: 120_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  const list = await openList('stop-scroll');

  await command('Scroll down.');
  await expect.poll(() => list.offset(), { timeout: 30_000 }).toBeGreaterThan(0);
  await sleep(2_000);

  const before = await list.offset();
  await command('Keep scrolling.');
  await expect.poll(() => list.offset(), { timeout: 30_000 }).toBeGreaterThan(before);
  // Still moving with nobody speaking: the scroll is under way when "stop" comes.
  const moving = await list.offset();
  await sleep(2_000);
  expect(await list.offset()).toBeGreaterThan(moving);

  await command('Stop.');
  let last = -1;
  await expect
    .poll(
      async () => {
        const now = await list.offset();
        const still = now === last;
        last = now;
        return still;
      },
      { timeout: 15_000, interval: 1_500 },
    )
    .toBe(true);
  // Ended by "stop", not by reaching the end of the list.
  expect(last).toBeLessThan(LIST_END);
  await sleep(5_000);
  expect(await list.offset()).toBe(last);
});
