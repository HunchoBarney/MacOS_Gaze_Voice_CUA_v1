/**
 * What the flows share: the harness's environment, speaking to Jarvis the way
 * a person does (Fn held, or the wake phrase, through the speakers or a
 * virtual microphone), the Activity page, the fixture board, and checks that
 * read the Mac rather than Jarvis's own UI.
 */

import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { expect } from 'e2e';
import type { Desktop } from '@e2e-dev/desktop';
import type { Screen } from 'e2e';

const run = promisify(execFile);

export const CALCULATOR = 'com.apple.calculator';
export const BOARD = 'com.karanvirkang.jarvis.e2e-board';

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === '') throw new Error(name + ' is not set: run the flows through make e2e');
  return value;
}

/** How a turn starts in this run: hold Fn (Hold fn to talk), or say the wake phrase (Standby). */
export function trigger(): 'fn' | 'wake' {
  return process.env.JARVIS_E2E_TRIGGER === 'wake' ? 'wake' : 'fn';
}

async function helper(...args: string[]): Promise<string> {
  const { stdout } = await run(required('JARVIS_E2E_HELPER'), args);
  return stdout.trim();
}

export async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

/** Copies of an app running now, by bundle id. */
export async function count(bundleId: string): Promise<number> {
  return Number(await helper('count', bundleId));
}

/** Quits an app by bundle id, force-quitting what is left after the wait. */
export async function quit(bundleId: string): Promise<void> {
  await helper('quit', bundleId, '10').catch(() => undefined);
}

/** Says a line out loud with macOS's own voice, into the microphone Jarvis listens to. */
export async function say(line: string): Promise<void> {
  const device = process.env.JARVIS_E2E_SAY_DEVICE;
  await run('say', [...(device ? ['-a', device] : []), '-v', process.env.JARVIS_E2E_VOICE ?? 'Samantha', line]);
}

/** Holds Fn for the length of the line, as a person would. Fn always comes back up. */
export async function holdFnAndSay(line: string): Promise<void> {
  await helper('fn', 'down');
  try {
    await sleep(400);
    await say(line);
    await sleep(600);
  } finally {
    await helper('fn', 'up');
  }
}

/** One spoken command, started the way this run starts turns. */
export async function command(line: string): Promise<void> {
  if (trigger() === 'wake') await say('Hey Jarvis, ' + line);
  else await holdFnAndSay(line);
}

/** Reads one key of Jarvis's saved settings, as the defaults command prints it; undefined when unset. */
export async function savedSetting(key: string): Promise<string | undefined> {
  return run('defaults', ['read', 'com.karanvirkang.jarvis', key]).then(
    ({ stdout }) => stdout.trim(),
    () => undefined,
  );
}

/** Points screen at one of Jarvis's windows by title, once it is open. */
export async function useWindow(desktop: Desktop, title: string): Promise<void> {
  await expect
    .poll(async () => (await desktop.windows()).map((window) => window.title), { timeout: 20_000 })
    .toContain(title);
  const window = (await desktop.windows()).find((candidate) => candidate.title === title);
  if (window === undefined) throw new Error('the ' + title + ' window closed before the test could read it');
  await desktop.useWindow(window);
}

/**
 * Opens Settings → Activity, where Jarvis shows what it heard and what it
 * did, and waits until the voice lane has had a moment to get ready.
 */
export async function openActivity(desktop: Desktop, screen: Screen): Promise<void> {
  await useWindow(desktop, 'Jarvis');
  await screen.getByRole('button', 'Activity').tap();
  await expect(screen.getByText('What you asked and what Jarvis did.')).toBeVisible({ timeout: 10_000 });
  await sleep(3_000);
}

/** The fixture board, frontmost, and the presses it has recorded so far. */
export interface Board {
  presses(): Promise<string[]>;
}

/** Opens the board in front of everything, so Jarvis's "this window" is the board. */
export async function openBoard(name: string): Promise<Board> {
  const clicks = path.join(required('JARVIS_E2E_TMP'), name + '-presses.txt');
  await run('open', ['-n', required('JARVIS_E2E_BOARD'), '--args', clicks]);
  const board: Board = {
    presses: async () =>
      (await readFile(clicks, 'utf8').catch(() => ''))
        .split('\n')
        .filter((line) => line !== ''),
  };
  await expect.poll(() => readFile(clicks).then(() => true, () => false), { timeout: 15_000 }).toBe(true);
  await sleep(1_000);
  return board;
}
