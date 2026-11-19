const http = require("http");
const { WebSocketServer } = require("ws");
const { SCHEMA_VERSION } = require("./externalStore.cjs");

const SNAPSHOT_SLICES = new Set([
  "gaze",
  "display",
  "camera",
  "calibration",
  "runtime",
  "models",
  "status",
  "paused",
  "calibration_status",
  "settings"
]);

const CONTROL_ACTIONS = new Set([
  "pause_toggle",
  // Deterministic pause for host-driven transitions (screen lock/unlock) —
  // a toggle can't express "pause only if not already paused", so the host
  // posts the target state instead.
  "set_paused",
  "recalibrate",
  // Settings → "Check eye-tracking accuracy": full calibration, then the
  // protocol v1 accuracy grid and hit test; the report lands beside the
  // calibration file.
  "accuracy_check",
  "dot_scale",
  // Gaze-cursor visibility — Vision Pro default is off; the element-level
  // highlight carries the pointing cue instead of a drawn dot.
  "gaze_dot",
  "dwell_lock",
  "preview_toggle",
  "status_toggle",
  "inference_time_toggle",
  "show_marker",
  // Commit-time implicit calibration label — value must be a normalized
  // screen point, validated below before dispatch (it's the one action
  // whose value is load-bearing).
  "implicit_sample",
  // Process lifecycle, handled API-side via the injected onQuit callback —
  // never forwarded through onControl to the renderer.
  "quit"
]);

// The implicit_sample value feeds a calibration label — a malformed point
// must be rejected here rather than clamped into a bogus label downstream.
function isNormalizedPoint(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    Number.isFinite(value.x_norm) &&
    Number.isFinite(value.y_norm) &&
    value.x_norm >= 0 &&
    value.x_norm <= 1 &&
    value.y_norm >= 0 &&
    value.y_norm <= 1 &&
    (value.kind === undefined || IMPLICIT_LABEL_KINDS.has(value.kind))
  );
}

// Label sources the tracker knows how to weigh (core.ts IMPLICIT_LABEL_KINDS).
const IMPLICIT_LABEL_KINDS = new Set(["cursor_rest", "click", "voice", "caret", "gaze_pick"]);

// A gaze frame inside this window counts as "actively producing" for /ready.
const READY_GAZE_WINDOW_MS = 3000;

function sendJson(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body)
  });
  response.end(body);
}

function readRequestBody(request, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        // Reject without destroying — the caller writes the 413 first, then
        // drops the socket, so clients see a JSON error not ECONNRESET.
        reject(Object.assign(new Error("body_too_large"), { code: "body_too_large" }));
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

// Readiness is stronger than /health liveness: the process is serving AND
// the pipeline is producing — models reported loaded, no error status, and
// either a gaze frame in the last few seconds or an intentional pause (a
// paused tracker stops the stream on purpose; that is not a wedge).
function checkReadiness(snapshot) {
  if (snapshot.status?.level === "error") {
    return { ready: false, reason: "status_error" };
  }
  if (!snapshot.runtime?.name) {
    return { ready: false, reason: "runtime_not_started" };
  }
  if (!snapshot.models?.detector || !snapshot.models?.gaze) {
    return { ready: false, reason: "models_not_loaded" };
  }
  if (snapshot.paused === true) {
    return { ready: true };
  }
  const gazeAt = snapshot.gaze?.updated_at ? Date.parse(snapshot.gaze.updated_at) : NaN;
  if (Number.isFinite(gazeAt) && Date.now() - gazeAt <= READY_GAZE_WINDOW_MS) {
    return { ready: true };
  }
  return { ready: false, reason: "no_recent_gaze" };
}

function handleControlRequest(request, response, onControl, onQuit) {
  if (request.method !== "POST") {
    sendJson(response, 405, { error: "method_not_allowed" });
    return;
  }
  // Same originless-clients-only rule as the WS upgrade below — otherwise a
  // browser page on any origin could drive pause/recalibrate.
  if (request.headers.origin !== undefined) {
    sendJson(response, 403, { error: "forbidden" });
    return;
  }
  if (typeof onControl !== "function") {
    sendJson(response, 503, { error: "control_unavailable" });
    return;
  }
  readRequestBody(request)
    .then((text) => {
      let body;
      try {
        body = text ? JSON.parse(text) : {};
      } catch {
        sendJson(response, 400, { error: "invalid_json" });
        return;
      }
      const action = body && typeof body === "object" ? body.action : undefined;
      if (typeof action !== "string" || !CONTROL_ACTIONS.has(action)) {
        sendJson(response, 400, { error: "unknown_action" });
        return;
      }
      if (action === "implicit_sample" && !isNormalizedPoint(body.value)) {
        sendJson(response, 400, { error: "invalid_value" });
        return;
      }
      if (action === "set_paused" && typeof body.value !== "boolean") {
        sendJson(response, 400, { error: "invalid_value" });
        return;
      }
      if (action === "quit") {
        // Quit is a process-lifecycle action, not a renderer menu action:
        // acknowledge first, then fire onQuit on the next tick so the 202
        // reaches the wire before app teardown kills this socket.
        if (typeof onQuit !== "function") {
          sendJson(response, 503, { error: "control_unavailable" });
          return;
        }
        sendJson(response, 202, { ok: true });
        setImmediate(() => {
          try {
            onQuit();
          } catch {
            // The app is going down either way — nothing left to report to.
          }
        });
        return;
      }
      let result;
      try {
        result = onControl(action, body.value);
      } catch {
        sendJson(response, 500, { error: "control_failed" });
        return;
      }
      // A handler may decline with an HTTP-shaped {status, error} result —
      // implicit_sample uses it to answer 409 when no live inference
      // session can consume the label.
      if (
        result &&
        typeof result === "object" &&
        Number.isInteger(result.status) &&
        result.status >= 400 &&
        result.status <= 599
      ) {
        sendJson(response, result.status, {
          error: typeof result.error === "string" ? result.error : "control_rejected"
        });
        return;
      }
      sendJson(response, 200, { ok: true });
    })
    .catch((error) => {
      const tooLarge = error && error.code === "body_too_large";
      if (!response.headersSent && !response.destroyed) {
        try {
          sendJson(response, tooLarge ? 413 : 400, { error: tooLarge ? "payload_too_large" : "invalid_body" });
        } catch {
          // Socket already gone — the destroy below still applies.
        }
      }
      // Flush before dropping: a same-tick request.destroy() can discard the
      // error body just written, so the client sees ECONNRESET, not the 4xx.
      const drop = () => request.destroy();
      if (response.writableFinished || response.destroyed) {
        drop();
      } else {
        response.once("finish", drop);
        response.once("close", drop);
      }
    });
}

// `options.onQuit` (optional): invoked after `POST /control {"action":"quit"}`
// is acknowledged. The main process wires `() => app.quit()` here; without it
// the action answers 503 like an unwired onControl.
function createRequestHandler(store, onControl, options = {}) {
  const { onQuit, logger = console } = options;
  return (request, response) => {
    // An 'error' event with no listener throws out of the emit and lands in
    // the app's uncaughtException handler — a dropped client socket must
    // never take the tracker process down with it.
    request.on("error", (error) => logger.error(`External API request error: ${error.message}`));
    response.on("error", (error) => logger.error(`External API response error: ${error.message}`));
    let url;
    try {
      url = new URL(request.url || "/", "http://127.0.0.1");
    } catch {
      // Absolute-form targets ("GET http://[::1") arrive here unparseable —
      // a throw inside the request listener kills the app, so answer 400.
      sendJson(response, 400, { error: "bad_request" });
      return;
    }
    if (url.pathname === "/control") {
      handleControlRequest(request, response, onControl, onQuit);
      return;
    }
    if (request.method !== "GET") {
      sendJson(response, 405, { error: "method_not_allowed" });
      return;
    }

    if (url.pathname === "/health") {
      const snapshot = store.getSnapshot();
      sendJson(response, 200, {
        ok: true,
        schema_version: SCHEMA_VERSION,
        started_at: snapshot.started_at
      });
      return;
    }

    if (url.pathname === "/ready") {
      const readiness = checkReadiness(store.getSnapshot());
      sendJson(
        response,
        readiness.ready ? 200 : 503,
        readiness.ready ? { ready: true } : { ready: false, reason: readiness.reason }
      );
      return;
    }

    if (url.pathname === "/snapshot") {
      sendJson(response, 200, store.getSnapshot());
      return;
    }

    const sliceMatch = url.pathname.match(/^\/snapshot\/([a-z_]+)$/u);
    if (sliceMatch && SNAPSHOT_SLICES.has(sliceMatch[1])) {
      sendJson(response, 200, store.getSlice(sliceMatch[1]));
      return;
    }

    sendJson(response, 404, { error: "not_found" });
  };
}

function sendSocketJson(socket, payload) {
  if (socket.readyState !== socket.OPEN) {
    return;
  }
  try {
    socket.send(JSON.stringify(payload));
  } catch {
    // A throwing send propagates through store.notify into whatever IPC
    // handler triggered the update — a dead socket must not kill the app.
    socket.terminate();
  }
}

// Options beyond store/host/port:
//   onControl(action, value) — non-lifecycle control actions (main.cjs:
//     handleControlAction).
//   onQuit() — fired after POST /control {"action":"quit"} is acknowledged;
//     main.cjs's maybeStartExternalApi wires `() => app.quit()` here.
//     Optional: without it the action answers 503.
function startExternalApiServer({ store, host, port, logger = console, onControl, onQuit }) {
  const server = http.createServer(createRequestHandler(store, onControl, { onQuit, logger }));
  const wss = new WebSocketServer({ noServer: true });

  wss.on("connection", (socket) => {
    sendSocketJson(socket, {
      type: "snapshot",
      snapshot: store.getSnapshot()
    });
    const unsubscribe = store.subscribe((event) => sendSocketJson(socket, event));
    socket.on("close", unsubscribe);
    socket.on("error", unsubscribe);
  });

  server.on("upgrade", (request, socket, head) => {
    // Same rule as the request handler: an 'error' with no listener throws
    // into uncaughtException — keep a listener on every socket we touch.
    socket.on("error", () => socket.destroy());
    let url;
    try {
      url = new URL(request.url || "/", `http://${host}`);
    } catch {
      socket.destroy();
      return;
    }
    if (url.pathname !== "/events") {
      socket.destroy();
      return;
    }
    // Browsers always attach Origin to WebSocket handshakes. Reject those
    // requests so an arbitrary page cannot read this unauthenticated API;
    // native local clients, which omit Origin, remain supported.
    if (request.headers.origin !== undefined) {
      socket.end("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit("connection", ws, request);
    });
  });

  server.on("error", (error) => {
    logger.error(`External API failed: ${error.message}`);
  });

  server.listen(port, host, () => {
    const address = server.address();
    const actualPort = typeof address === "object" && address ? address.port : port;
    logger.log(`External API listening on http://${host}:${actualPort}`);
  });

  return {
    server,
    wss,
    close: () => {
      wss.close();
      server.close();
    }
  };
}

module.exports = {
  SNAPSHOT_SLICES,
  CONTROL_ACTIONS,
  createRequestHandler,
  startExternalApiServer
};
