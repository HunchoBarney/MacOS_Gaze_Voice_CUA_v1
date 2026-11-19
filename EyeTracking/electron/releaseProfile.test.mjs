import { expect, it } from "vitest";
import profile from "./releaseProfile.cjs";

it("keeps development opt-in separate from portable model and input authority", () => {
  const release = (args) => profile.retinafaceRelease("retinaface-v1", args);
  for (const accelerator of ["auto", "webgpu", "wasm"]) {
    expect(release(["--no-tray", "--detector=retinaface", "--web-accelerator", accelerator])).toBe(true);
  }
  for (const args of [["--detector=yolo"], ["--detector", "retinaface", "--detector", "yolo"],
    ["--enable-lip-motion"], ["--appearance-model=alternate"], ["--gaze-model", "checkout"],
    ["--detector-model=alternate"], ["--retinaface-model", "other"], ["--lip-motion-model=alternate"],
    ["--yolo-model=alternate"], ["--web-accelerator", "other"], ["--inspect"], ["--no-tray=true"]]) {
    expect(() => release(args)).toThrow();
    expect(profile.retinafaceRelease(undefined, args)).toBe(false);
  }
  expect(() => profile.retinafaceRelease("unknown", [])).toThrow();
});
