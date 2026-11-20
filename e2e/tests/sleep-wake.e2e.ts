import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { CALCULATOR, OWNER_PRESENT, command, count, openActivity, ownerStep, quit, sleep, waitForWake } from '../support/jarvis.ts';

// #560 item 29: after the Mac sleeps and wakes, voice still drives the
// desktop without restarting Jarvis. Only the owner can put the Mac to sleep
// and wake it, so this runs with JARVIS_E2E_OWNER=1.

test.afterEach(async () => {
  await quit(CALCULATOR);
});

test(
  '29: after sleep and wake, "Hey Jarvis, open Calculator" still works',
  { timeout: 480_000, skip: OWNER_PRESENT ? false : 'needs the owner at the Mac: JARVIS_E2E_OWNER=1' },
  async ({ app, screen, desktop }) => {
    await app.open();
    await openActivity(desktop, screen);
    await command('Open Calculator.');
    await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);
    await quit(CALCULATOR);

    ownerStep('close the lid for a minute, then open it and unlock the Mac. The run waits up to 5 minutes.');
    await waitForWake(300_000);
    await sleep(15_000);

    await command('Open Calculator.');
    await expect.poll(() => count(CALCULATOR), { timeout: 45_000 }).toBe(1);
  },
);
