/* global Vision */
self.onmessage = async (event) => {
  const { bitmap, root, delegate, seconds, fps } = event.data;
  try {
    const pkg = `${root}/node_modules/@mediapipe/tasks-vision`;
    importScripts(`${pkg}/vision_bundle.js`);
    const createStart = performance.now();
    const model = new Uint8Array(await (await fetch(`${root}/public/models/face_landmarker.task`)).arrayBuffer());
    const landmarker = await Vision.FaceLandmarker.createFromOptions(
      { wasmLoaderPath: `${pkg}/wasm/vision_wasm_internal.js`, wasmBinaryPath: `${pkg}/wasm/vision_wasm_internal.wasm` },
      {
        baseOptions: { modelAssetBuffer: model, delegate: delegate === "gpu" ? "GPU" : "CPU" },
        runningMode: "VIDEO",
        numFaces: 1,
        outputFaceBlendshapes: true,
        outputFacialTransformationMatrixes: true
      }
    );
    const createMs = performance.now() - createStart;
    const canvas = new OffscreenCanvas(640, 480);
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    const scale = 480 / bitmap.height;
    const drawW = bitmap.width * scale;
    let frameNo = 0;
    let ts = 0;
    // One tracker frame: jittered draw → getImageData (the worker's decode)
    // → detectForVideo. Returns [decode ms, landmarker ms, face found].
    const step = () => {
      frameNo += 1;
      const dx = 3 * Math.sin(frameNo / 7);
      const dy = 2 * Math.cos(frameNo / 11);
      const t0 = performance.now();
      ctx.fillStyle = "#333";
      ctx.fillRect(0, 0, 640, 480);
      ctx.drawImage(bitmap, (640 - drawW) / 2 + dx, dy, drawW, 480);
      const frame = ctx.getImageData(0, 0, 640, 480);
      const t1 = performance.now();
      ts = Math.max(ts + 1, t1);
      const result = landmarker.detectForVideo(frame, ts);
      const t2 = performance.now();
      return [t1 - t0, t2 - t1, (result.faceLandmarks?.length ?? 0) > 0, result];
    };
    const first = step();
    const summarize = (values) => {
      const s = values.slice().sort((a, b) => a - b);
      const at = (q) => s[Math.min(s.length - 1, Math.floor(s.length * q))];
      return { n: s.length, p50: at(0.5), p95: at(0.95), mean: s.reduce((a, b) => a + b, 0) / s.length };
    };
    // Throughput: back-to-back for 5 s after a 1 s warmup.
    const warmEnd = performance.now() + 1000;
    while (performance.now() < warmEnd) step();
    const lat = [];
    const decode = [];
    let found = 0;
    const tpStart = performance.now();
    while (performance.now() - tpStart < 5000) {
      const [d, l, ok] = step();
      decode.push(d);
      lat.push(l);
      if (ok) found += 1;
    }
    const throughputFps = lat.length / ((performance.now() - tpStart) / 1000);
    // Paced: the tracker's default --gaze-max-fps cadence for CPU sampling.
    self.postMessage({ phase: "paced-start" });
    const paced = [];
    const period = 1000 / fps;
    const pacedStart = performance.now();
    let next = pacedStart;
    let pacedFound = 0;
    let frames = 0;
    while (performance.now() - pacedStart < seconds * 1000) {
      const [, l, ok] = step();
      paced.push(l);
      frames += 1;
      if (ok) pacedFound += 1;
      next += period;
      const wait = next - performance.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    }
    const achievedFps = frames / ((performance.now() - pacedStart) / 1000);
    const sample = first[3];
    self.postMessage({
      done: {
        create_ms: createMs,
        first_frame_face: first[2],
        landmarks: sample.faceLandmarks?.[0]?.length ?? 0,
        blendshapes: sample.faceBlendshapes?.[0]?.categories?.length ?? 0,
        matrix: sample.facialTransformationMatrixes?.[0]?.data?.slice?.(0, 16) ?? null,
        throughput: { fps: throughputFps, landmarker_ms: summarize(lat), decode_ms: summarize(decode), face_rate: found / lat.length },
        paced: { target_fps: fps, achieved_fps: achievedFps, landmarker_ms: summarize(paced), face_rate: pacedFound / frames, seconds }
      }
    });
  } catch (error) {
    self.postMessage({ error: String((error && error.stack) || error) });
  }
};
