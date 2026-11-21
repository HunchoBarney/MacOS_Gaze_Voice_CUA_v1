/**
 * What the flows share: the harness's environment, speaking to Jarvis the way
 * a person does (the wake phrase, through the speakers or a virtual
 * microphone), the Activity page, the fixture board, and checks that read the
 * Mac rather than Jarvis's own UI.
 */

import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { promisify } from 'node:util';
import { expect } from 'e2e';
import type { Desktop } from '@e2e-dev/desktop';
import type { Screen } from 'e2e';

const run = promisify(execFile);

export const JARVIS = 'com.karanvirkang.jarvis';
export const CALCULATOR = 'com.apple.calculator';
export const TEXTEDIT = 'com.apple.TextEdit';
export const SAFARI = 'com.apple.Safari';
export const BOARD = 'com.karanvirkang.jarvis.e2e-board';

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === '') throw new Error(name + ' is not set: run the flows through make e2e');
  return value;
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

/** Runs a program and returns what it printed; rejects on a non-zero exit or after the timeout. */
export async function sh(file: string, args: string[], timeoutMs = 30_000): Promise<string> {
  const { stdout } = await run(file, args, { timeout: timeoutMs });
  return stdout.trim();
}

/** Another app's windows, read through Accessibility. */
export async function windows(bundleId: string): Promise<{ width: number; height: number; title: string }[]> {
  if ((await count(bundleId)) === 0) return [];
  return (await helper('windows', bundleId))
    .split('\n')
    .filter((line) => line !== '')
    .map((line) => {
      const [size = '', ...title] = line.split(' ');
      const [width = 0, height = 0] = size.split('x').map(Number);
      return { width, height, title: title.join(' ') };
    });
}

/** The URL of the page in an app's focused window; undefined when there is none. */
export async function webURL(bundleId: string): Promise<string | undefined> {
  return helper('web-url', bundleId).catch(() => undefined);
}

/** The items in Jarvis's menu-bar menu, read without pressing any of them. */
export async function menuItems(): Promise<string[]> {
  return (await helper('extra', JARVIS)).split('\n').filter((line) => line !== '');
}

/** Presses one item in Jarvis's menu-bar menu. */
export async function pressMenuItem(title: string): Promise<void> {
  await helper('extra', JARVIS, title);
}

/** Focuses another app's text field by its placeholder, the way a click into it would. */
export async function focusField(bundleId: string, placeholder: string): Promise<void> {
  await helper('focus', bundleId, placeholder);
}

/** Presses an item in another app's menu bar, such as Safari's File > New Window. */
export async function pressMenu(bundleId: string, menu: string, item: string): Promise<void> {
  await helper('menu', bundleId, menu, item);
}

/** Closes an app's frontmost windows. */
export async function closeFront(bundleId: string, windowCount: number): Promise<void> {
  if (windowCount > 0 && (await count(bundleId)) > 0) await helper('close-front', bundleId, String(windowCount)).catch(() => undefined);
}

/**
 * Connects to a Unix socket from this process, which is not Jarvis, sends one
 * line and reports what came back and whether the other end closed the
 * connection before the timeout. Rejects when nothing listens there.
 */
export function knock(socketPath: string, line: string, timeoutMs: number): Promise<{ reply: string; closedByPeer: boolean }> {
  return new Promise((resolve, reject) => {
    let reply = '';
    let connected = false;
    const socket = net.createConnection(socketPath);
    socket.setTimeout(timeoutMs, () => {
      socket.destroy();
      resolve({ reply, closedByPeer: false });
    });
    socket.on('connect', () => {
      connected = true;
      socket.write(line + '\n');
    });
    socket.on('data', (chunk) => {
      reply += chunk.toString('utf8');
    });
    socket.on('close', () => resolve({ reply, closedByPeer: true }));
    socket.on('error', (error) => (connected ? resolve({ reply, closedByPeer: true }) : reject(error)));
  });
}

/** Set when the owner sits at the Mac for the steps only a person can do. */
export const OWNER_PRESENT = process.env.JARVIS_E2E_OWNER === '1';
/** Set when the owner allows the flows that make a paid model call beyond Realtime. */
export const PAID = process.env.JARVIS_E2E_PAID === '1';

/** Tells the owner, in the terminal running make e2e, the one thing to do now. */
export function ownerStep(instruction: string): void {
  console.log('\n>>> e2e needs you: ' + instruction + '\n');
}

/** Closes every window of an app without saving anything. */
export async function discard(bundleId: string): Promise<void> {
  if ((await count(bundleId)) > 0) await helper('discard', bundleId).catch(() => undefined);
}

/** Holds Fn for a while, posted by a program: every event tap sees it, as it saw a held Fn. */
export async function holdFn(seconds: number): Promise<void> {
  await helper('post', 'fn-hold', String(seconds));
}

/** Presses Escape as a program. Jarvis's emergency stop answers only a hardware Escape. */
export async function postEscape(): Promise<void> {
  await helper('post', 'escape');
}

/** Waits until the Mac has slept and woken again, however that happened. */
export async function waitForWake(timeoutMs: number): Promise<void> {
  const before = await sh('sysctl', ['-n', 'kern.waketime']);
  await expect.poll(() => sh('sysctl', ['-n', 'kern.waketime']), { timeout: timeoutMs, interval: 2_000 }).not.toBe(before);
}

/**
 * Permission and Keychain prompts macOS showed for Jarvis since a moment,
 * as the system log records them. A best-effort witness: a prompt also blocks
 * the action it guards, which the flow's own check catches.
 */
export async function promptsSince(since: Date): Promise<string[]> {
  const start = new Date(since.getTime() - since.getTimezoneOffset() * 60_000).toISOString().replace('T', ' ').slice(0, 19);
  const predicate =
    '(subsystem == "com.apple.TCC" AND eventMessage CONTAINS "AUTHREQ_PROMPTING") OR ' +
    '(process == "securityd" AND eventMessage CONTAINS "displaying keychain prompt")';
  const lines = await sh('log', ['show', '--start', start, '--style', 'compact', '--predicate', predicate], 60_000);
  return lines.split('\n').filter((line) => /jarvis/i.test(line));
}

/** Says a line out loud with macOS's own voice, into the microphone Jarvis listens to. */
export async function say(line: string): Promise<void> {
  const device = process.env.JARVIS_E2E_SAY_DEVICE;
  await run('say', [...(device ? ['-a', device] : []), '-v', process.env.JARVIS_E2E_VOICE ?? 'Samantha', line]);
}

/** One spoken command, opened with the wake phrase. */
export async function command(line: string): Promise<void> {
  await say('Hey Jarvis, ' + line);
}

/** Reads one key of Jarvis's saved settings, as the defaults command prints it; undefined when unset. */
export async function savedSetting(key: string): Promise<string | undefined> {
  return run('defaults', ['read', 'com.karanvirkang.jarvis', key]).then(
    ({ stdout }) => stdout.trim(),
    () => undefined,
  );
}

/** Removes one key from Jarvis's saved settings, so a later read proves this run wrote it. */
export async function clearSetting(key: string): Promise<void> {
  await run('defaults', ['delete', 'com.karanvirkang.jarvis', key]).catch(() => undefined);
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

/**
 * Taps Jarvis's own "go ahead" when Activity shows it: Go ahead answers a
 * task's question and Run a single action's (the typed-command Run beside it
 * stays disabled while its field is empty). Returns whether it tapped.
 */
export async function goAheadIfAsked(screen: Screen): Promise<boolean> {
  const confirm = screen.getByRole('button', 'Go ahead').or(screen.getByRole('button', { name: 'Run', disabled: false }));
  if (!(await confirm.isVisible())) return false;
  await confirm.tap();
  return true;
}

/** Opens the fixture board in front of everything, recording into one file, and returns that file's lines. */
async function launchBoard(name: string, ...args: string[]): Promise<() => Promise<string[]>> {
  const record = path.join(required('JARVIS_E2E_TMP'), name);
  await run('open', ['-n', required('JARVIS_E2E_BOARD'), '--args', record, ...args]);
  await expect.poll(() => readFile(record).then(() => true, () => false), { timeout: 15_000 }).toBe(true);
  await sleep(1_000);
  return async () =>
    (await readFile(record, 'utf8').catch(() => ''))
      .split('\n')
      .filter((line) => line !== '');
}

/** The fixture board, frontmost, and the presses it has recorded so far. */
export interface Board {
  presses(): Promise<string[]>;
}

/** Opens the board in front of everything, so Jarvis's "this window" is the board. */
export async function openBoard(name: string): Promise<Board> {
  return { presses: await launchBoard(name + '-presses.txt') };
}

/** How far the fixture list can scroll: 4,000 rows of 28 points (Rows in fixtures/Board.swift), less one window. */
export const LIST_END = 4_000 * 28 - 360;

/** The fixture list, frontmost, and its scroll offset in points, 0 at the top. */
export interface List {
  offset(): Promise<number>;
}

/** Opens the board's long list in front of everything, so Jarvis's "this window" is the list. */
export async function openList(name: string): Promise<List> {
  const lines = await launchBoard(name + '-offsets.txt', '--list');
  return { offset: async () => Number((await lines()).at(-1) ?? 0) };
}

function lastValue(lines: string[]): string {
  const line = lines.filter((entry) => entry.startsWith('value ')).at(-1);
  return line === undefined ? '' : line.slice('value '.length).replaceAll('\\n', '\n');
}

/** Starts an ongoing scroll in the fixture list: "scroll down", then "keep scrolling", and checks that it keeps going on its own. */
export async function startScrolling(list: List): Promise<void> {
  await command('Scroll down.');
  await expect.poll(() => list.offset(), { timeout: 30_000 }).toBeGreaterThan(0);
  await sleep(2_000);
  const before = await list.offset();
  await command('Keep scrolling.');
  await expect.poll(() => list.offset(), { timeout: 30_000 }).toBeGreaterThan(before);
  const moving = await list.offset();
  await sleep(2_000);
  expect(await list.offset(), 'the scroll stopped by itself').toBeGreaterThan(moving);
}

/** Waits until the list holds still within the deadline, then checks that nothing moves it for 5 s more. */
export async function expectStopped(list: List, deadlineMs: number): Promise<void> {
  let last = -1;
  await expect
    .poll(
      async () => {
        const now = await list.offset();
        const still = now === last;
        last = now;
        return still;
      },
      { timeout: deadlineMs, interval: 1_500 },
    )
    .toBe(true);
  expect(last, 'the list reached its end instead of being stopped').toBeLessThan(LIST_END);
  await sleep(5_000);
  expect(await list.offset(), 'the list moved after it was stopped').toBe(last);
}

/** The fixture's one empty text field, frontmost and focused, and what it holds now. */
export interface Field {
  value(): Promise<string>;
}

/** Opens the board's text field in front of everything, focused, so Jarvis types into it. */
export async function openField(name: string): Promise<Field> {
  const lines = await launchBoard(name + '-field.txt', '--field');
  return { value: async () => lastValue(await lines()) };
}

/** The fixture's received message, selected, with its Reply field and Send button. */
export interface MessageWindow {
  reply(): Promise<string>;
  sent(): Promise<boolean>;
}

/** Opens the board's message in front of everything, with the message selected, so it is Jarvis's "this". */
export async function openMessage(name: string): Promise<MessageWindow> {
  const lines = await launchBoard(name + '-message.txt', '--message');
  return {
    reply: async () => lastValue(await lines()),
    sent: async () => (await lines()).includes('Send'),
  };
}
