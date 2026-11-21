import { describe, it } from "vitest";
import { expectSmootherBeatsLegacy } from "./temporalMeasure";

// The full 16-seed × 2 glitch-length corpus: ~115k synchronous smoother
// updates of pure CPU replay. It runs in the slow project; temporal.test.ts
// keeps a few-seed gate of the same assertion in the unit project.
describe("temporal estimate smoother — measured", () => {
  it("median-window + coherent snap beats the legacy EMA on dwell error without added lag", () => {
    expectSmootherBeatsLegacy(16);
  });
});
