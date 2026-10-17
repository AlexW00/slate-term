import assert from 'node:assert/strict';
import {createNotesPersistence} from '../../skills/slate-terminal/references/plugin-persistence.mjs';
const clone = value => JSON.parse(JSON.stringify(value));
const wait = () => new Promise(resolve => setTimeout(resolve, 40));
let panel = {panelId: 'panel', revision: 'initial', values: {}}, data = {id: 'notes', revision: 'data', values: {note: 'retained'}};
let listener, writes = [], dataWrites = 0, draws = [], errors = [], stopped = false;
const workspace = {
  call: async () => ({cursor: 'cursor-before-snapshot'}),
  pluginData: {get: async () => clone(data), patch: async () => { ++dataWrites; throw new Error('conflict'); }},
  panelState: {
    get: async () => clone(panel),
    patch: async (ops, guards) => {
      writes.push({ops, guards});
      assert.equal(guards.expectedStateRevision, panel.revision);
      panel = {...panel, revision: panel.revision + '-next', values: {selectedNoteId: ops[0].value}};
      return {workspacePersistence: 'saved'};
    }
  },
  subscribe: async (handler, options) => {
    assert.equal(options.after, 'cursor-before-snapshot'); listener = handler;
    return () => { stopped = true; };
  }
};
const controller = await createNotesPersistence({workspace, render: value => draws.push(value), onError: error => errors.push(error), delay: 10});
assert.equal(writes.length, 0, 'Initialization must not overwrite either store');
controller.select('queued-before-reset');
panel = {...panel, revision: 'reset', values: {}};
const reset = {topic: 'host.plugin.panel-state.changed', payload: {panelId: 'panel', reset: true, beforeRevision: 'initial', revision: 'reset'}};
await listener(reset);
await wait();
assert.equal(writes.length, 0, 'Reset cancels an obsolete debounced selection');
assert.equal(draws.at(-1).selectedNoteId, null);
// A delayed replay of an older reset must not cancel an intentional edit made after resnapshot.
panel = {...panel, revision: 'later', values: {selectedNoteId: 'later-snapshot'}};
await controller.refresh();
controller.select('intentional-after-reset');
await listener(reset);
assert.equal(draws.at(-1).selectedNoteId, 'intentional-after-reset');
await wait();
assert.equal(writes.length, 1);
assert.equal(panel.values.selectedNoteId, 'intentional-after-reset');
assert.deepEqual(data.values, {note: 'retained'});
await assert.rejects(controller.saveNote('note', 'local edit'), /conflict/);
assert.equal(errors.length, 1, 'Conflicts are visible, not retried');
controller.select('not-saved-after-stop');
controller.stop();
await wait();
assert.equal(writes.length, 1);
assert(stopped);
// A reset-triggered read racing a stale save must not discard its only invalidation.
const next = await createNotesPersistence({workspace, render: value => draws.push(value), onError: error => errors.push(error), delay: 10});
const readNormally = workspace.pluginData.get;
let releaseRead, deferred = true;
workspace.pluginData.get = async () => {
  if (!deferred) return readNormally();
  deferred = false;
  const snapshot = clone(data);
  return new Promise(resolve => { releaseRead = () => resolve(snapshot); });
};
data = {...data, revision: 'data-reset', values: {}};
const refreshing = listener({topic: 'host.plugin.data.changed', payload: {pluginId: 'notes', reset: true, revision: 'data-reset'}});
const rejected = assert.rejects(next.saveNote('note', 'stale edit'), /conflict/);
assert.equal(typeof releaseRead, 'function');
releaseRead();
await Promise.all([refreshing, rejected]);
assert.deepEqual(draws.at(-1).notes, {}, 'Racing conflict must not strand pre-reset cached notes');
assert.equal(writes.length, 1);
assert.equal(dataWrites, 2, 'Each explicit shared-data edit is attempted exactly once, never retried');
next.stop();
console.log('PASS persistence example: reset-safe debounce/replay, racing read/write conflict resnapshot, no mutation retries, cleanup');
