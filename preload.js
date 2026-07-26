const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("mouseTrac", {
  getState: () => ipcRenderer.invoke("get-state"),
  saveNow: () => ipcRenderer.invoke("save-now"),
  restoreNow: () => ipcRenderer.invoke("restore-now"),
  updateSettings: (settings) => ipcRenderer.invoke("update-settings", settings),
  requestAccessibility: () => ipcRenderer.invoke("request-accessibility"),
  onState: (callback) => ipcRenderer.on("state", (_event, state) => callback(state))
});