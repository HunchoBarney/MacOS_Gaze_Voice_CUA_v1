const LOST_RELEASE_MS = 500;
const DOUBLE_CLICK_EFFECT_MS = 500;

function createLipClickController({
  mouse,
  getDisplayBounds,
  logger = console,
  now = () => Date.now(),
  emitEffect = () => undefined
}) {
  let enabled = false;
  let calibrationActive = false;
  let mouthOpenActive = false;
  let invalidSince = null;
  let lastPressAt = null;
  let buttonDown = false;
  let pending = Promise.resolve();

  function setEnabled(value) {
    enabled = Boolean(value);
    if (!enabled) {
      releaseNow();
    }
  }

  function setCalibrationActive(value) {
    calibrationActive = Boolean(value);
    if (calibrationActive) {
      releaseNow();
    }
  }

  function update(payload) {
    if (!enabled || calibrationActive || !payload || payload.type !== "gaze") {
      if (mouthOpenActive && (calibrationActive || !enabled)) {
        releaseNow();
      }
      return;
    }
    const point = gazePoint(payload);
    if (!point) {
      markInvalid();
      return;
    }
    if (payload.mouth_detected !== true || typeof payload.mouth_open !== "boolean") {
      markInvalid();
      return;
    }
    invalidSince = null;
    if (payload.mouth_open) {
      const shouldClick = !mouthOpenActive;
      if (shouldClick) {
        mouthOpenActive = true;
        registerPressEffect(point);
        enqueue(async () => {
          // The click may have been queued before a calibration modal armed
          // the shield — re-check at execution so a stale press can't land
          // on the modal (e.g. its exit button).
          if (!enabled || calibrationActive) {
            return;
          }
          await mouse.move(point);
          // move() awaited — the shield may have armed in that millisecond
          // window. Re-check so a queued press can't land on the modal.
          if (!enabled || calibrationActive) {
            return;
          }
          buttonDown = true;
          try {
            await mouse.press();
          } finally {
            // release must pair with press even on a throw — skipping it
            // would leave the OS button physically held down.
            try {
              await mouse.release();
            } finally {
              buttonDown = false;
            }
          }
        });
      }
    } else if (mouthOpenActive) {
      mouthOpenActive = false;
    }
  }

  function releaseNow() {
    invalidSince = null;
    lastPressAt = null;
    mouthOpenActive = false;
  }

  // Physical OS-button state — true only inside the press/release pair of an
  // in-flight click. The stub always returned false, hiding a stuck button.
  function isPressed() {
    return buttonDown;
  }

  function registerPressEffect(point) {
    const current = now();
    if (lastPressAt !== null && current - lastPressAt <= DOUBLE_CLICK_EFFECT_MS) {
      lastPressAt = null;
      emitEffect({ type: "lip_click_effect", effect: "double", x: point.x, y: point.y });
      return;
    }
    lastPressAt = current;
    emitEffect({ type: "lip_click_effect", effect: "single", x: point.x, y: point.y });
  }

  function gazePoint(payload) {
    const xNorm = Number(payload.x_norm);
    const yNorm = Number(payload.y_norm);
    if (!Number.isFinite(xNorm) || !Number.isFinite(yNorm)) {
      return null;
    }
    const bounds = getDisplayBounds();
    if (!bounds || !Number.isFinite(bounds.x) || !Number.isFinite(bounds.y) || !Number.isFinite(bounds.width) || !Number.isFinite(bounds.height) || bounds.width <= 0 || bounds.height <= 0) {
      return null;
    }
    return {
      x: Math.min(bounds.x + bounds.width - 1, Math.round(bounds.x + Math.max(0, Math.min(1, xNorm)) * bounds.width)),
      y: Math.min(bounds.y + bounds.height - 1, Math.round(bounds.y + Math.max(0, Math.min(1, yNorm)) * bounds.height))
    };
  }

  function markInvalid() {
    if (!mouthOpenActive) {
      invalidSince = null;
      return;
    }
    const current = now();
    if (invalidSince === null) {
      invalidSince = current;
      return;
    }
    if (current - invalidSince >= LOST_RELEASE_MS) {
      releaseNow();
    }
  }

  function enqueue(action) {
    pending = pending.then(action, action).catch((error) => {
      logger.warn?.(`Lip motion mouse action failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  }

  return {
    setEnabled,
    setCalibrationActive,
    update,
    releaseNow,
    isPressed,
    idle: () => pending
  };
}

module.exports = { createLipClickController, DOUBLE_CLICK_EFFECT_MS, LOST_RELEASE_MS };
