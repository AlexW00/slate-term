// Copyable, nonvisual example: shared notes + one panel's selection.
// No automatic mutation retry, no unload saving, and no initialization writes.
// Render lists/selection here; preserve any unsaved editor draft in your own UI.
export async function createNotesPersistence({workspace, render, onError, delay = 150}) {
  let data, panel, stopSubscription, timer, pending, running;
  let closed = false, again = false, readVersion = 0, intent = 0;
  const controller = new AbortController();
  const options = {signal: controller.signal};
  const ensureOpen = () => { if (closed) throw new Error('Persistence controller is closed'); };
  function draw() {
    if (!closed && data && panel) render({notes: data.values,
      selectedNoteId: pending ? pending.value : panel.values.selectedNoteId ?? null});
  }
  function refresh() {
    if (closed) return Promise.resolve();
    ++readVersion; again = true;
    if (running) return running;
    running = (async () => {
      while (again && !closed) {
        again = false;
        const version = readVersion;
        const [nextData, nextPanel] = await Promise.all([
          workspace.pluginData.get(options), workspace.panelState.get(options)
        ]);
        if (closed) return;
        if (version !== readVersion) { again = true; continue; }
        data = nextData; panel = nextPanel; draw();
      }
    })().finally(() => { running = null; });
    return running;
  }
  function cancelSelection() {
    clearTimeout(timer); timer = undefined; pending = undefined; ++intent;
  }
  const {cursor} = await workspace.call('events.head');
  await refresh();
  stopSubscription = await workspace.subscribe(async event => {
    const p = event.payload;
    if (event.topic === 'host.plugin.data.changed' && p.pluginId !== data.id) return;
    const reset = event.topic === 'host.plugin.panel-state.changed' && p.reset;
    if (event.topic === 'host.plugin.panel-state.changed' && p.panelId !== panel.panelId) return;
    await refresh();
    // Revisions are opaque: a replayed reset can predate our snapshot. Cancel only an edit
    // whose captured revision is now stale, never a newer edit against the current snapshot.
    if (reset && pending && pending.revision !== panel.revision) { cancelSelection(); draw(); }
  }, {after: cursor, topics: ['host.plugin.data.changed', 'host.plugin.panel-state.changed'], onError});
  return {
    // Call for an explicit user edit. On conflict show an error and let the user decide;
    // blindly rebasing could recreate data the user intentionally deleted/reset elsewhere.
    async saveNote(key, value) {
      ensureOpen(); ++readVersion;
      try {
        await workspace.pluginData.patch([{op: 'set', key, value}], data.revision);
        await refresh();
      } catch (error) {
        onError(error);
        // Resnapshot after a conflict/unknown outcome, but never retry the mutation.
        try { await refresh(); } catch (readError) { onError(readError); }
        throw error;
      }
    },
    select(noteId) {
      ensureOpen(); clearTimeout(timer); ++readVersion;
      const edit = ++intent;
      const captured = {panelId: panel.panelId, revision: panel.revision};
      pending = {...captured, value: noteId}; draw();
      timer = setTimeout(async () => {
        timer = undefined;
        try {
          const result = await workspace.panelState.patch([{op: 'set', key: 'selectedNoteId', value: noteId}],
            {expectedPanelId: captured.panelId, expectedStateRevision: captured.revision});
          if (closed) return;
          if (result.workspacePersistence !== 'saved') onError(new Error(`View state is live but not saved: ${result.workspacePersistence}`));
        } catch (error) { if (!closed) onError(error); }
        finally {
          if (!closed) {
            if (edit === intent) pending = undefined;
            try { await refresh(); } catch (error) { onError(error); }
          }
        }
      }, delay);
    },
    refresh,
    stop() { closed = true; ++readVersion; cancelSelection(); controller.abort(); stopSubscription?.(); }
  };
}
