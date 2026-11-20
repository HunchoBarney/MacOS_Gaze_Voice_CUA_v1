import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { BOARD, command, openActivity, openBoard, quit, sleep } from '../support/jarvis.ts';

// "show names" labels what can be clicked on the board, then "click Banana"
// presses it. The board records presses in a file, so the check is the
// fixture's own record, not Jarvis's. Two Realtime turns.

test.afterEach(async () => {
  await quit(BOARD);
});

test('"show names", then "click Banana": Banana is pressed exactly once', { timeout: 120_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  const board = await openBoard('show-names');

  await command('Show names.');
  await expect(screen.getByText(/Show(ed|ing) the names|showed \d+ names/i)).toBeVisible({ timeout: 30_000 });
  expect(await board.presses()).toEqual([]);

  await command('Click Banana.');
  // Without a standing grant Jarvis asks first; Activity's Run answers it.
  const confirm = screen.getByRole('button', { name: 'Run', disabled: false });
  await expect
    .poll(
      async () => {
        if ((await board.presses()).length > 0) return true;
        if (await confirm.isVisible()) await confirm.tap();
        return false;
      },
      { timeout: 30_000, interval: 500 },
    )
    .toBe(true);
  await sleep(3_000);
  expect(await board.presses()).toEqual(['Banana']);
});
