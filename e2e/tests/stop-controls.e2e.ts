import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import {
  BOARD, CALCULATOR, OWNER_PRESENT, count, expectStopped, holdFn, menuItems, openActivity, openList, ownerStep,
  postEscape, pressMenuItem, quit, say, sleep, startScrolling,
} from '../support/jarvis.ts';

// #583 deletes Fn and keeps two ways to stop: Escape, which answers only a
// hardware key, and a Stop item in the menu-bar menu that shows only while
// something can be stopped. The running task is the ongoing scroll from
// stop-scroll, decided on the Mac with no model call.

test.afterEach(async () => {
  await quit(CALCULATOR);
  await quit(BOARD);
});

test('Fn does nothing: holding it while speaking opens nothing', { timeout: 90_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  expect(await count(CALCULATOR), 'Calculator was already open').toBe(0);
  // Fn used to be read through an event tap, which sees this posted Fn the
  // same way it saw the key. Without "Hey Jarvis" nothing may happen.
  const holding = holdFn(6);
  await sleep(500);
  await say('Open Calculator.');
  await holding;
  await sleep(6_000);
  expect(await count(CALCULATOR), 'a held Fn still opened a turn').toBe(0);
});

test('the menu-bar Stop item shows only while a task runs, and stops it', { timeout: 150_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  expect(await menuItems(), 'Stop shows while nothing runs').not.toContain('Stop');
  const list = await openList('menu-stop');
  await startScrolling(list);
  await pressMenuItem('Stop');
  await expectStopped(list, 15_000);
  expect(await menuItems(), 'Stop still shows after the task ended').not.toContain('Stop');
});

test('an Escape a program posts does not stop the task, so a task can press Escape itself', { timeout: 150_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  const list = await openList('posted-escape');
  await startScrolling(list);
  await postEscape();
  const after = await list.offset();
  await sleep(3_000);
  expect(await list.offset(), 'a posted Escape stopped the task').toBeGreaterThan(after);
  await pressMenuItem('Stop');
  await expectStopped(list, 15_000);
});

test(
  'Escape on the keyboard stops a running task',
  { timeout: 180_000, skip: OWNER_PRESENT ? false : 'needs the owner to press Escape: JARVIS_E2E_OWNER=1' },
  async ({ app, screen, desktop }) => {
    await app.open();
    await openActivity(desktop, screen);
    const list = await openList('escape');
    await startScrolling(list);
    ownerStep('press Escape once now. The list in front should stop scrolling.');
    await expectStopped(list, 60_000);
  },
);
