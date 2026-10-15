/*
 * Keeps a plugin page in sync with the Slate Terminal palette.
 * Load it in <head> before slate.css so the light or dark default paints first.
 * The terminal palette follows a moment later, once the host answers:
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
    listeners.forEach(listener => listener(theme));
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

  // Avoid a flash of the fallback appearance while the first read is in flight.
  if (matchMedia("(prefers-color-scheme: light)").matches) root.dataset.appearance = "light";

  const read = () => workspace.call("appearance.get").then(apply);
  // Subscribe before the first read so a change between them is not lost.
  // Events are notifications, so each one triggers a fresh authoritative read.
  // The subscription stops after an error, so re-read and subscribe again with a growing delay.
  let retryDelay = 1000;
  function follow() {
    // onError and a rejected promise can both report one failure; retry once per attempt.
    let failed = false;
    const fail = () => { if (!failed) { failed = true; retry(); } };
    try {
      Promise.resolve(workspace.subscribe(() => { retryDelay = 1000; read().catch(() => {}); }, {
        topics: ["host.appearance.changed"],
        onError: fail,
      })).catch(fail);
    } catch {
      fail();
    }
  }
  function retry() {
    read().catch(() => {});
    setTimeout(follow, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 30000);
  }
  follow();
  read().catch(followSystem);
})();
