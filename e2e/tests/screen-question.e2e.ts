import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { BOARD, command, openActivity, openBoard, quit } from '../support/jarvis.ts';

// A question about the window in front: the board says "The code word is
// PELICAN." Jarvis reads the window as text and answers in Activity. One
// Realtime turn.

test.afterEach(async () => {
  await quit(BOARD);
});

test('"what is the code word in this window?" is answered from the window', { timeout: 90_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  const board = await openBoard('screen-question');

  await command('What is the code word in this window?');

  await expect(screen.getByText(/pelican/i)).toBeVisible({ timeout: 30_000 });
  expect(await board.presses()).toEqual([]);
});
