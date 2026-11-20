import path from 'node:path';
import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import {
  BOARD, CALCULATOR, SAFARI, attempt, closeFront, command, count, goAheadIfAsked, openActivity, openField,
  pressMenu, promptsSince, quit, sh, sleep, webURL, windows,
} from '../support/jarvis.ts';

// #560: the Cua daemon admits only Jarvis. Items 25 to 28 of the owner's
// checklist: voice still drives the desktop, a browser action, window and
// menu actions, and any other process is refused at the daemon's socket.
// Item 24 is agent-handoff and item 29 is sleep-wake.

test.afterEach(async () => {
  await quit(CALCULATOR);
  await quit(BOARD);
});

test('25: voice opens Calculator and types into a field, with no new prompt', { timeout: 150_000 }, async ({ app, screen, desktop }) => {
  const started = new Date();
  await app.open();
  await openActivity(desktop, screen);
  await command('Open Calculator.');
  await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);
  await quit(CALCULATOR);

  const field = await openField('type-sum');
  await command('Type 2 plus 2.');
  await expect
    .poll(
      async () => {
        await goAheadIfAsked(screen);
        return field.value();
      },
      { timeout: 30_000, interval: 1_000 },
    )
    .toMatch(/2\s*(\+|plus)\s*2/i);
  expect(await promptsSince(started), 'macOS asked for a permission again').toEqual([]);
});

test('26–27: a new tab on apple.com, a bigger window, then File > New Window in Safari', { timeout: 240_000 }, async ({ app, screen, desktop }) => {
  const safariWasOpen = (await count(SAFARI)) > 0;
  let made = 0;
  try {
    await sh('open', ['-a', 'Safari']);
    await sleep(3_000);
    const before = (await windows(SAFARI)).length;
    // A window of the flow's own, in front, so nothing touches the owner's tabs.
    await pressMenu(SAFARI, 'File', 'New Window');
    made = 1;
    await expect.poll(async () => (await windows(SAFARI)).length, { timeout: 10_000 }).toBe(before + 1);

    await app.open();
    await openActivity(desktop, screen);
    await sh('open', ['-a', 'Safari']);
    await command('Open a new tab and go to apple.com.');
    await expect
      .poll(
        async () => {
          await goAheadIfAsked(screen);
          return (await webURL(SAFARI)) ?? '';
        },
        { timeout: 45_000, interval: 1_000 },
      )
      .toMatch(/^https:\/\/(www\.)?apple\.com/);

    const [front] = await windows(SAFARI);
    const area = (front?.width ?? 0) * (front?.height ?? 0);
    await command('Make this window bigger.');
    await expect
      .poll(
        async () => {
          await goAheadIfAsked(screen);
          const [now] = await windows(SAFARI);
          return (now?.width ?? 0) * (now?.height ?? 0);
        },
        { timeout: 30_000, interval: 1_000 },
      )
      .toBeGreaterThan(area);

    await command('File, New Window.');
    await expect
      .poll(
        async () => {
          await goAheadIfAsked(screen);
          return (await windows(SAFARI)).length;
        },
        { timeout: 30_000, interval: 1_000 },
      )
      .toBe(before + 2);
    made = 2;
  } finally {
    if (safariWasOpen) await closeFront(SAFARI, made);
    else await quit(SAFARI);
  }
});

test('28: a process that is not Jarvis is refused at the daemon socket, and Jarvis keeps working', { timeout: 150_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  await command('Open Calculator.');
  await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);
  await quit(CALCULATOR);

  const sockets = await sh('/bin/sh', ['-c', 'ls "${TMPDIR:-/tmp}"/jarvis-cua-*/d-*.sock 2>/dev/null || true']);
  const socket = sockets.split('\n')[0] ?? '';
  expect(socket, 'Jarvis has no daemon socket').not.toBe('');
  const driver = path.join(process.env.JARVIS_E2E_APP ?? '', 'Contents/Resources/cua-driver');
  const outcome = await attempt(driver, ['list-tools', '--socket', socket], 15_000);
  expect(outcome.ok, 'the daemon answered a process that is not Jarvis: ' + outcome.output.slice(0, 200)).toBe(false);
  expect(outcome.output).not.toMatch(/screenshot|list_apps|click/i);

  await command('Open Calculator.');
  await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);
});
