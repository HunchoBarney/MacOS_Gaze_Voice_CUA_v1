import { readFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from '@e2e-dev/desktop';
import { expect } from 'e2e';
import { CALCULATOR, JARVIS, command, count, openActivity, promptsSince, quit, sh, sleep } from '../support/jarvis.ts';

// #548 signs every executable with the hardened runtime. On that signed build:
// Jarvis launches and stays up, the wake word works (Jarvis dlopens its
// bundled libvosk), the eye tracker serves its API with no library-validation
// kill in its log, and the embedded cua-driver acts. Runs on the tracker
// target, so the eye tracker is on and uses Jarvis's own camera grant.

const trackerLog = path.join(os.homedir(), 'Library/Application Support/Jarvis/tracker.log');

test.afterEach(async () => {
  await quit(CALCULATOR);
});

test('hardened runtime: launch, wake word, eye tracker and a Cua action, with no new prompt', { timeout: 150_000 }, async ({ app, screen, desktop }) => {
  const started = new Date();
  const logStart = await stat(trackerLog).then((file) => file.size, () => 0);
  const signature = await sh('/bin/sh', ['-c', 'codesign --display --verbose=2 "$0" 2>&1', process.env.JARVIS_E2E_APP ?? '']);
  expect(signature, 'the app is not signed with the hardened runtime').toMatch(/flags=0x[0-9a-f]+\(runtime\)/);

  await app.open();
  await openActivity(desktop, screen);
  await sleep(5_000);
  expect(await count(JARVIS), 'Jarvis quit right after launch').toBe(1);

  const healthy = () => fetch('http://127.0.0.1:47892/health').then((response) => response.ok, () => false);
  await expect.poll(healthy, { timeout: 60_000, interval: 2_000 }).toBe(true);

  // The wake word only works when libvosk loaded; the action only lands when the daemon runs.
  await command('Open Calculator.');
  await expect.poll(() => count(CALCULATOR), { timeout: 30_000 }).toBe(1);

  const log = (await readFile(trackerLog).catch(() => Buffer.alloc(0))).subarray(logStart).toString('utf8');
  expect(log.split('\n').filter((line) => /library validation|code signature|crash|killed/i.test(line))).toEqual([]);
  expect(await promptsSince(started), 'macOS asked for a permission again').toEqual([]);
});
