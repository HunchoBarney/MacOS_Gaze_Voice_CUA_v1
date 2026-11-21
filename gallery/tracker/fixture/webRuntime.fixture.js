// Gallery-only stand-in for EyeTracking/web/src/inference/webRuntime.ts.
// render.mjs aliases the app's import to this file at build time, so the
// fixture renderer never loads a model, starts a worker or opens a camera.
// The controller itself lives in fixture/bootstrap.js (window.__fx).
export function startWebRuntime(config, onMessage) {
  return window.__fx.startRuntime(config, onMessage);
}
