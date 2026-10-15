/*
 * Keeps a plugin page in sync with the Slate Terminal palette.
 * Load it in <head> before slate.css. Inside Slate Terminal the host has already
 * injected the palette variables; elsewhere the light or dark default paints first:
 *   <script src="slate-theme.js"></script>
 *
 * It writes the --st-* palette variables and data-appearance on <html>.
 * slate.css derives every semantic token from those variables.
 *
 * Read the current theme from script (e.g. for canvas or charts):
 *   SlateTheme.current            // last applied theme, or null
 *   SlateTheme.onChange(theme => redraw())   // returns an unsubscribe function
 *
 * It reads the host method appearance.get and re-reads it on each
 * host.appearance.changed event. On hosts without that method, the page
 * follows prefers-color-scheme with the defaults in slate.css.
 */
(function () {
  "use strict";

  const root = document.documentElement;
  const listeners = new Set();
  const api = window.SlateTheme = {
    current: null,
    onChange(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };

  function apply(theme) {
    if (api.current && theme.revision !== undefined && theme.revision === api.current.revision) return;
    const { palette, font } = theme;
    const vars = {
      "--st-bg": palette.background,
      "--st-fg": palette.foreground,
      "--st-cursor": palette.cursor,
      "--st-selection-bg": palette.selectionBackground,
      "--st-selection-fg": palette.selectionForeground,
    };
    palette.ansi.slice(0, 16).forEach((color, index) => { vars[`--st-ansi-${index}`] = color; });
    if (font) {
      vars["--st-font-mono"] = `"${font.family.replace(/"/g, "")}", ui-monospace, Menlo, monospace`;
      // Plugin UIs read best one point below the terminal size.
      vars["--st-font-mono-size"] = `${Math.max(10, Math.min(16, font.size - 1))}px`;
    }
    for (const [name, value] of Object.entries(vars)) {
      if (value) root.style.setProperty(name, value);
    }
    root.dataset.appearance = theme.tone;
    root.style.colorScheme = theme.tone;
    api.current = theme;
    listeners.forEach(listener => {
      try { listener(theme); }
      catch (error) { console.error("SlateTheme listener failed", error); }
    });
  }

  // Outside the host, or before appearance.get exists: follow the system.
  function followSystem() {
    const query = matchMedia("(prefers-color-scheme: light)");
    const update = () => { root.dataset.appearance = query.matches ? "light" : "dark"; };
    update();
    query.addEventListener("change", update);
  }

  const workspace = window.workspace;
  const hasThemeAPI = workspace && Array.isArray(workspace.methods) && workspace.methods.includes("appearance.get");
  if (!hasThemeAPI) {
    followSystem();
    return;
  }

  // The host injects the palette before page scripts run. Without injection,
  // guess from the system to avoid a flash while the first read is in flight.
  if (!root.dataset.appearance && matchMedia("(prefers-color-scheme: light)").matches) root.dataset.appearance = "light";

  let active = true;
  let generation = 0;
  let reading = null;
  let readAgain = false;
  let stopSubscription = null;
  let retryTimer = 0;
  let retryDelay = 1000;
  function read() {
    if (!active) return Promise.resolve();
    if (reading) { readAgain = true; return reading; }
    const started = generation;
    reading = Promise.resolve().then(() => {
      if (active && generation === started) return workspace.call("appearance.get");
    }).then(theme => {
      if (active && generation === started && !readAgain && theme) apply(theme);
    }).finally(() => {
      if (generation !== started) return;
      reading = null;
      if (readAgain) {
        readAgain = false;
        read().catch(() => {});
      }
    });
    return reading;
  }
  // Subscribe before reading; merge invalidations without applying superseded results.
  function follow() {
    if (!active) return;
    const started = generation;
    let failed = false;
    // onError and a rejected promise can both report one failure.
    const fail = () => {
      if (!failed && active && generation === started) {
        failed = true;
        stopSubscription?.();
        stopSubscription = null;
        retry();
      }
    };
    try {
      Promise.resolve(workspace.subscribe(() => {
        if (!active || generation !== started) return;
        retryDelay = 1000;
        read().catch(() => {});
      }, { topics: ["host.appearance.changed"], onError: fail })).then(stop => {
        if (!active || generation !== started || failed) stop();
        else stopSubscription = stop;
      }).catch(fail);
    } catch {
      fail();
    }
  }
  function retry() {
    if (!active) return;
    read().catch(() => {});
    clearTimeout(retryTimer);
    retryTimer = setTimeout(start, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 30000);
  }
  function start() {
    follow();
    read().catch(() => {}); // Retain the host-injected palette on transient read failure.
  }
  window.addEventListener("pagehide", () => {
    active = false;
    generation++;
    reading = null;
    readAgain = false;
    clearTimeout(retryTimer);
    stopSubscription?.();
    stopSubscription = null;
  });
  window.addEventListener("pageshow", event => {
    if (!event.persisted || active) return;
    active = true;
    retryDelay = 1000;
    start();
  });
  start();
})();
