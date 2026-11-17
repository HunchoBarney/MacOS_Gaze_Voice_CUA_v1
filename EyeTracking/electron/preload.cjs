const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("gazeBridge", {
  getConfig: () => ipcRenderer.invoke("get-config"),
  readCalibration: (path) => ipcRenderer.invoke("read-calibration", path),
  writeCalibration: (path, payload) => ipcRenderer.invoke("write-calibration", path, payload),
  writeReport: (path, payload) => ipcRenderer.invoke("write-report", path, payload),
  ready: () => ipcRenderer.send("renderer-ready"),
  setOverlayRegions: (regions) => ipcRenderer.send("overlay-regions", regions),
  setModalInteractive: (interactive) => ipcRenderer.send("modal-interactive", interactive),
  setPaused: (paused) => ipcRenderer.send("set-paused", paused),
  getSettings: () => ipcRenderer.invoke("get-settings"),
  setSettings: (patch) => ipcRenderer.send("set-settings", patch),
  reportState: (state) => ipcRenderer.send("report-state", state),
  publishBackendMessage: (payload) => ipcRenderer.send("publish-backend-message", payload),
  onBackendMessage: (callback) => {
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on("backend-message", listener);
    return () => ipcRenderer.removeListener("backend-message", listener);
  },
  onRecalibrate: (callback) => {
    const listener = () => callback();
    ipcRenderer.on("recalibrate", listener);
    return () => ipcRenderer.removeListener("recalibrate", listener);
  }
});
