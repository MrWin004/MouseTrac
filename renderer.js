const els = {
  permissionBadge: document.getElementById("permissionBadge"),
  positionText: document.getElementById("positionText"),
  positionTime: document.getElementById("positionTime"),
  saveNow: document.getElementById("saveNow"),
  restoreNow: document.getElementById("restoreNow"),
  autoMode: document.getElementById("autoMode"),
  manualMode: document.getElementById("manualMode"),
  intervalSlider: document.getElementById("intervalSlider"),
  intervalBox: document.getElementById("intervalBox"),
  saveHotkey: document.getElementById("saveHotkey"),
  restoreHotkey: document.getElementById("restoreHotkey"),
  notifyOnSave: document.getElementById("notifyOnSave"),
  notifyOnRestore: document.getElementById("notifyOnRestore"),
  hotkeyStatus: document.getElementById("hotkeyStatus"),
  permissionButton: document.getElementById("permissionButton")
};

let state = null;

function render(nextState) {
  state = nextState;
  const settings = state.settings;

  els.permissionBadge.textContent = state.trusted ? "Permission ready" : "Permission needed";
  els.permissionBadge.className = state.trusted ? "badge good" : "badge warn";

  if (state.savedPosition) {
    els.positionText.textContent = `x: ${state.savedPosition.x}, y: ${state.savedPosition.y}, display: ${state.savedPosition.displayId}`;
    els.positionTime.textContent = `Saved at ${state.savedPosition.savedAt}`;
  } else {
    els.positionText.textContent = "No position saved yet";
    els.positionTime.textContent = "";
  }

  els.autoMode.checked = settings.autoMode;
  els.manualMode.checked = settings.manualMode;
  els.intervalSlider.value = settings.intervalMs;
  els.intervalBox.value = settings.intervalMs;
  els.saveHotkey.value = settings.saveHotkey;
  els.restoreHotkey.value = settings.restoreHotkey;
  els.notifyOnSave.checked = settings.notifyOnSave;
  els.notifyOnRestore.checked = settings.notifyOnRestore;
  els.hotkeyStatus.textContent = state.hotkeyStatus || "";
}

async function updateSettings(patch) {
  const nextState = await window.mouseTrac.updateSettings(patch);
  render(nextState);
}

function eventToAccelerator(event) {
  event.preventDefault();

  const parts = [];

  if (event.metaKey) parts.push("CommandOrControl");
  if (event.ctrlKey && !event.metaKey) parts.push("Control");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");

  const keyMap = {
    " ": "Space",
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    Escape: "Esc",
    Delete: "Delete",
    Backspace: "Backspace",
    Enter: "Enter",
    Tab: "Tab"
  };

  let key = keyMap[event.key] || event.key.toUpperCase();

  if (["META", "CONTROL", "ALT", "SHIFT"].includes(key)) {
    return null;
  }

  if (key.length === 1 || keyMap[event.key]) {
    parts.push(key);
  }

  if (parts.length < 2) {
    return null;
  }

  return parts.join("+");
}

function bindHotkeyInput(input, settingName) {
  input.addEventListener("keydown", async (event) => {
    const accelerator = eventToAccelerator(event);

    if (!accelerator) {
      input.value = "Use at least one modifier";
      return;
    }

    await updateSettings({ [settingName]: accelerator });
  });
}

els.saveNow.addEventListener("click", () => window.mouseTrac.saveNow());
els.restoreNow.addEventListener("click", () => window.mouseTrac.restoreNow());

els.autoMode.addEventListener("change", () => updateSettings({ autoMode: els.autoMode.checked }));
els.manualMode.addEventListener("change", () => updateSettings({ manualMode: els.manualMode.checked }));
els.notifyOnSave.addEventListener("change", () => updateSettings({ notifyOnSave: els.notifyOnSave.checked }));
els.notifyOnRestore.addEventListener("change", () => updateSettings({ notifyOnRestore: els.notifyOnRestore.checked }));

els.intervalSlider.addEventListener("input", () => {
  els.intervalBox.value = els.intervalSlider.value;
});

els.intervalSlider.addEventListener("change", () => {
  updateSettings({ intervalMs: Number(els.intervalSlider.value) });
});

els.intervalBox.addEventListener("change", () => {
  const value = Math.max(100, Math.min(10000, Number(els.intervalBox.value || 1000)));
  updateSettings({ intervalMs: value });
});

els.permissionButton.addEventListener("click", () => {
  window.mouseTrac.requestAccessibility();
});

bindHotkeyInput(els.saveHotkey, "saveHotkey");
bindHotkeyInput(els.restoreHotkey, "restoreHotkey");

window.mouseTrac.onState(render);
window.mouseTrac.getState().then(render);