const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("bench", {
  phase: (name) => ipcRenderer.send("phase", name),
  done: (result) => ipcRenderer.send("done", result),
  fail: (message) => ipcRenderer.send("fail", message)
});
