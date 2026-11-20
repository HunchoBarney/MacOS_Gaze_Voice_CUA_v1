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

/** Quiet: no spoken replies, no cue tones, no agent cursor. Each target says whether the eye tracker runs. */
const quiet = [
  '-ttsEnabled', '<false/>',
  '-soundsEnabled', '<false/>',
  '-agentCursorEnabled', '<false/>',
  '-handsFreePaused', '<false/>',
  '-assistantName', 'Jarvis',
  '-microphoneUID', process.env.JARVIS_E2E_MICROPHONE ?? '',
];

/** Set up, with Settings open, waiting for "Hey Jarvis". */
const standby = ['--settings', '-firstRunCompleted', '<true/>', '-listeningMode', 'standby'];

export default {
  projectId: 'jarvis-e2e',
  tests: 'tests/**/*.e2e.ts',
  targets: [
    { name: 'first-run', engine, app: { appPath, launchArguments: ['--first-run', '-gazeTracking', '<false/>', ...quiet] } },
    { name: 'jarvis', engine, app: { appPath, launchArguments: [...standby, '-gazeTracking', '<false/>', ...quiet] } },
    /** The eye tracker on: it needs Jarvis's own camera grant. */
    { name: 'tracker', engine, app: { appPath, launchArguments: [...standby, '-gazeTracking', '<true/>', ...quiet] } },
    /** GPT-Live work behind the voice.live flag, such as writing by instruction (L7). */
    {
      name: 'live',
      engine,
      app: { appPath, launchArguments: [...standby, '-voice.live', '<true/>', '-gazeTracking', '<false/>', ...quiet] },
    },
  ],
  workers: 1,
  retries: 0,
  timeout: 120_000,
  launchTimeout: 60_000,
  maxDuration: 900_000,
  output: '.e2e',
} satisfies E2EConfig;
