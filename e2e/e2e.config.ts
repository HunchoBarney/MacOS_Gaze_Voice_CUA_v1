import type { E2EConfig } from 'e2e';
import { desktop } from '@e2e-dev/desktop';

/**
 * Jarvis's end-to-end flows on a signed build. Run them with make e2e, which
 * holds the desktop lock, quits any running Jarvis, and puts the Mac back
 * afterwards (scripts/run.sh). Every setting below reaches Jarvis as a launch
 * argument, so it applies to that launch only and is never saved.
 */

const appPath = process.env.JARVIS_E2E_APP ?? (process.env.HOME ?? '') + '/jarvis-local/Jarvis.app';
const engine = desktop({ binary: process.env.AGENT_DESKTOP_BINARY });

/** Quiet and camera-free: no eye tracker, no spoken replies, no cue tones, no agent cursor. */
const quiet = [
  '-gazeTracking', '<false/>',
  '-ttsEnabled', '<false/>',
  '-soundsEnabled', '<false/>',
  '-agentCursorEnabled', '<false/>',
  '-handsFreePaused', '<false/>',
  '-assistantName', 'Jarvis',
  '-microphoneUID', process.env.JARVIS_E2E_MICROPHONE ?? '',
];

export default {
  projectId: 'jarvis-e2e',
  tests: 'tests/**/*.e2e.ts',
  targets: [
    { name: 'first-run', engine, app: { appPath, launchArguments: ['--first-run', ...quiet] } },
    {
      name: 'jarvis',
      engine,
      app: { appPath, launchArguments: ['--settings', '-firstRunCompleted', '<true/>', '-listeningMode', 'standby', ...quiet] },
    },
  ],
  workers: 1,
  retries: 0,
  timeout: 120_000,
  launchTimeout: 60_000,
  maxDuration: 360_000,
  output: '.e2e',
} satisfies E2EConfig;
