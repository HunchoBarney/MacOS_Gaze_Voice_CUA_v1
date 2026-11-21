import { configDefaults, defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config";

// Three projects, so a CPU benchmark or a spawned process tree can't starve
// the fast gate. `pnpm test` runs all three; `vitest run --project unit` is
// the quick deterministic check.
//
// - unit: in-process and deterministic, the default gate.
// - slow: CPU-heavy simulation and benchmark corpora (*.slow.test.ts).
// - integration: tests that spawn processes or open real sockets. They run
//   one file at a time after the other projects, so port-0 servers and
//   subprocess trees never compete with each other or the CPU-bound files.
const slow = ["web/src/**/*.slow.test.ts"];
const integration = [
  "electron/dev.test.mjs",
  "electron/externalFlow.test.mjs",
  "electron/externalStore.test.mjs",
  "electron/hostWatchdog.test.mjs",
  "electron/storeContract.test.mjs"
];

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      // Half the cores: other worktrees test on the same Mac, and vitest's
      // default of every core but one oversubscribed it.
      maxWorkers: "50%",
      projects: [
        {
          extends: true,
          test: {
            name: "unit",
            include: ["electron/**/*.test.mjs", "web/src/**/*.test.ts"],
            exclude: [...configDefaults.exclude, ...slow, ...integration]
          }
        },
        {
          extends: true,
          test: {
            name: "slow",
            include: slow,
            testTimeout: 30_000
          }
        },
        {
          extends: true,
          test: {
            name: "integration",
            include: integration,
            fileParallelism: false
          }
        }
      ]
    }
  })
);
