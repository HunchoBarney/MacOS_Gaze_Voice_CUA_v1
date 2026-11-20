import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { BOARD, PAID, command, focusField, openActivity, openField, openMessage, quit, sleep } from '../support/jarvis.ts';

// Writing by instruction (L7, #595), behind voice.live, so this runs on the
// live target. "Type this" must put exactly the words in the focused field,
// and a reply draft must land in the reply field unsent: only "send it" sends.

test.afterEach(async () => {
  await quit(BOARD);
});

test('"type this": the exact words land in the focused field', { timeout: 120_000 }, async ({ app, screen, desktop }) => {
  await app.open();
  await openActivity(desktop, screen);
  const field = await openField('type-this');
  await command('Type this: meet Dana at 5:45.');
  // Jarvis types at once when on-device recognition agrees. Without that
  // permission, or when the two readings differ, it shows "Type this?" and
  // waits for "type it".
  await sleep(10_000);
  if ((await field.value()) === '') await command('Type it.');
  await expect.poll(() => field.value(), { timeout: 30_000 }).toMatch(/^meet Dana at (5:45|five forty-?five)$/i);
});

test(
  '"come up with a reply for this": the draft goes into Reply and is not sent',
  { timeout: 240_000, skip: PAID ? false : 'a paid draft call: JARVIS_E2E_PAID=1' },
  async ({ app, screen, desktop }) => {
    await app.open();
    await openActivity(desktop, screen);
    const message = await openMessage('reply');
    await command('Come up with a reply for this.');
    // The selected message isn't a field, so Jarvis holds the draft until a
    // reply field has focus and it hears "type it".
    await sleep(20_000);
    await focusField(BOARD, 'Reply');
    for (let tries = 0; tries < 3 && (await message.reply()) === ''; tries++) {
      await command('Type it.');
      await sleep(15_000);
    }
    expect((await message.reply()).length, 'no draft reached the Reply field').toBeGreaterThan(20);
    await sleep(5_000);
    expect(await message.sent(), 'the draft was sent without "send it"').toBe(false);
  },
);
