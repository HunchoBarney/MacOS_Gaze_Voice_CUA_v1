import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { PAID, TEXTEDIT, command, count, discard, goAheadIfAsked, openActivity, quit, sh, windows } from '../support/jarvis.ts';

// #562 with #560, item 24: an agent's computer use goes through Jarvis's
// private socket. "Have an agent open a new blank document in TextEdit" must
// open an Untitled TextEdit window. One Codex turn and one Jev call, so this
// runs only with JARVIS_E2E_PAID=1, and only when TextEdit isn't already
// open, because cleanup closes TextEdit's windows without saving.

let ours = false;

test.afterEach(async () => {
  if (!ours) return;
  await discard(TEXTEDIT);
  await quit(TEXTEDIT);
});

test(
  '24: an agent opens a blank TextEdit document through Jarvis',
  { timeout: 300_000, skip: PAID ? false : 'a paid Codex turn: JARVIS_E2E_PAID=1' },
  async ({ app, screen, desktop }) => {
    test.skip((await count(TEXTEDIT)) > 0, 'TextEdit is open; close it and rerun');
    ours = true;
    const file = path.join(process.env.JARVIS_E2E_TMP ?? '/tmp', 'agent-check.txt');
    await writeFile(file, 'agent check');
    await sh('open', ['-a', 'TextEdit', file]);
    await expect.poll(async () => (await windows(TEXTEDIT)).map((window) => window.title), { timeout: 15_000 }).toContain('agent-check.txt');

    await app.open();
    await openActivity(desktop, screen);
    await command('Have an agent open a new blank document in TextEdit.');
    await expect
      .poll(
        async () => {
          await goAheadIfAsked(screen);
          return (await windows(TEXTEDIT)).some((window) => /^Untitled/.test(window.title));
        },
        { timeout: 180_000, interval: 2_000 },
      )
      .toBe(true);
  },
);
