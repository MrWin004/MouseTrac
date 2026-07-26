const { app, BrowserWindow, ipcMain, globalShortcut, screen, Notification, systemPreferences, shell } = require("electron");
const path = require("path");
const fs = require("fs");

let mainWindow;
let mouse;
let Point;

const defaultSettings = {
  autoMode: true,
  manualMode: true,
  intervalMs: 1000,
  saveHotkey: "CommandOrControl+Shift+K",
  restoreHotkey: "CommandOrControl+Shift+J",
  notifyOnSave: false,
  notifyOnRestore: false
};

let settings = { ...defaultSettings };
let savedPosition = null;
let lastPosition = null;
let wasStill = false;
let autoTimer = null;
let hotkeyStatus = "";

function settingsPath() {
  return path.join(app.getPath("userData"), "settings.json");
}

function loadSettings() {
  try {
    const raw = fs.readFileSync(settingsPath(), "utf8");
    settings = { ...defaultSettings, ...JSON.parse(raw) };
  } catch {
    settings = { ...defaultSettings };
  }
}

function saveSettings() {
  fs.mkdirSync(app.getPath("userData"), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 760,
    height: 560,
    minWidth: 680,
    minHeight: 500,
    title: "MouseTrac",
    backgroundColor: "#f7f4ef",
    webPreferences: {
      preload: path.join(__dirname, "preload.js")
    }
  });

  mainWindow.loadFile(path.join(__dirname, "index.html"));
}

function sendState() {
  if (!mainWindow) return;

  mainWindow.webContents.send("state", {
    settings,
    savedPosition,
    hotkeyStatus,
    trusted: hasAccessibilityPermission()
  });
}

function hasAccessibilityPermission() {
  return systemPreferences.isTrustedAccessibilityClient(false);
}

function requestAccessibilityPermission() {
  systemPreferences.isTrustedAccessibilityClient(true);
  shell.openExternal("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
}

function notify(title, body) {
  if (Notification.isSupported()) {
    new Notification({ title, body }).show();
  }
}

function samePoint(a, b) {
  return a && b && Math.round(a.x) === Math.round(b.x) && Math.round(a.y) === Math.round(b.y);
}

function pointInsideRect(point, rect) {
  return (
    point.x >= rect.x &&
    point.y >= rect.y &&
    point.x < rect.x + rect.width &&
    point.y < rect.y + rect.height
  );
}

function pointIsOnConnectedDisplay(point) {
  return screen.getAllDisplays().some((display) => pointInsideRect(point, display.bounds));
}

function currentMousePosition() {
  const point = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(point);

  return {
    x: Math.round(point.x),
    y: Math.round(point.y),
    displayId: display.id,
    savedAt: new Date().toLocaleTimeString()
  };
}

function saveCurrentPosition(source) {
  savedPosition = currentMousePosition();

  if (source === "manual" && settings.notifyOnSave) {
    notify("MouseTrac", `Saved position ${savedPosition.x}, ${savedPosition.y}`);
  }

  if (source === "auto" && settings.notifyOnSave) {
    notify("MouseTrac", `Auto-saved position ${savedPosition.x}, ${savedPosition.y}`);
  }

  sendState();
}

async function restoreSavedPosition() {
  if (!savedPosition) {
    notify("MouseTrac", "No mouse position has been saved yet.");
    return;
  }

  if (!pointIsOnConnectedDisplay(savedPosition)) {
    notify("MouseTrac", "Saved position is on a display that is not connected.");
    return;
  }

  try {
    await mouse.setPosition(new Point(savedPosition.x, savedPosition.y));

    if (settings.notifyOnRestore) {
      notify("MouseTrac", `Restored to ${savedPosition.x}, ${savedPosition.y}`);
    }

    sendState();
  } catch (error) {
    notify("MouseTrac", "MouseTrac needs Accessibility permission to move the cursor.");
  }
}

function startAutoTimer() {
  if (autoTimer) {
    clearInterval(autoTimer);
  }

  lastPosition = null;
  wasStill = false;

  autoTimer = setInterval(() => {
    if (!settings.autoMode) return;

    const position = currentMousePosition();

    if (samePoint(position, lastPosition)) {
      if (!wasStill) {
        saveCurrentPosition("auto");
        wasStill = true;
      }
    } else {
      wasStill = false;
      lastPosition = position;
    }
  }, settings.intervalMs);
}

function registerHotkeys() {
  globalShortcut.unregisterAll();

  const results = [];

  if (settings.manualMode) {
    const saveRegistered = globalShortcut.register(settings.saveHotkey, () => {
      saveCurrentPosition("manual");
    });

    results.push(saveRegistered ? "Save hotkey active" : "Save hotkey failed");
  }

  const restoreRegistered = globalShortcut.register(settings.restoreHotkey, () => {
    restoreSavedPosition();
  });

  results.push(restoreRegistered ? "Restore hotkey active" : "Restore hotkey failed");
  hotkeyStatus = results.join(". ");
}

async function loadMouseControl() {
  const nut = await import("@nut-tree-fork/nut-js");
  mouse = nut.mouse;
  Point = nut.Point;
  mouse.config.mouseSpeed = 0;
}

app.whenReady().then(async () => {
  loadSettings();
  await loadMouseControl();
  createWindow();
  registerHotkeys();
  startAutoTimer();
  sendState();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
      sendState();
    }
  });
});

app.on("will-quit", () => {
  globalShortcut.unregisterAll();

  if (autoTimer) {
    clearInterval(autoTimer);
  }
});

app.on("window-all-closed", () => {
  app.quit();
});

ipcMain.handle("get-state", () => ({
  settings,
  savedPosition,
  hotkeyStatus,
  trusted: hasAccessibilityPermission()
}));

ipcMain.handle("save-now", () => {
  saveCurrentPosition("manual");
});

ipcMain.handle("restore-now", async () => {
  await restoreSavedPosition();
});

ipcMain.handle("request-accessibility", () => {
  requestAccessibilityPermission();
});

ipcMain.handle("update-settings", (_event, nextSettings) => {
  settings = {
    ...settings,
    ...nextSettings,
    intervalMs: Math.max(100, Math.min(10000, Number(nextSettings.intervalMs || settings.intervalMs)))
  };

  saveSettings();
  registerHotkeys();
  startAutoTimer();
  sendState();

  return {
    settings,
    savedPosition,
    hotkeyStatus,
    trusted: hasAccessibilityPermission()
  };
});