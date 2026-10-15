const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('skills/slate-terminal/references/ui/slate-theme.js', 'utf8');
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

function fixture() {
  let handler, subscriptionFailure, active = 0, maximumActive = 0, writes = 0, stops = 0;
  const requests = [], changes = [], errors = [], listeners = new Map(), timers = new Map();
  let timerSequence = 0;
  const root = { dataset: { appearance: 'dark' }, style: { setProperty() { writes++; } } };
  const sandbox = {
    console: { error(...args) { errors.push(args); } },
    document: { documentElement: root }, window: {
      addEventListener(name, callback) { listeners.set(name, callback); },
    },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    setTimeout(callback) { timers.set(++timerSequence, callback); return timerSequence; },
    clearTimeout(id) { timers.delete(id); },
  };
  sandbox.window.workspace = {
    methods: ['appearance.get'],
    subscribe: async (callback, options) => { handler = callback; subscriptionFailure = options.onError; return () => { stops++; }; },
    call() {
      active++; maximumActive = Math.max(maximumActive, active);
      return new Promise((resolve, reject) => requests.push({
        resolve(value) { active--; resolve(value); }, reject(error) { active--; reject(error); },
      }));
    },
  };
  vm.createContext(sandbox); vm.runInContext(source, sandbox);
  sandbox.window.SlateTheme.onChange(theme => changes.push(theme.revision));
  return { requests, changes, errors, event: () => handler({ topic: 'host.appearance.changed' }),
    listen: callback => sandbox.window.SlateTheme.onChange(callback),
    fireRetry() { for (const [id, callback] of [...timers]) { timers.delete(id); callback(); } },
    lifecycle: name => listeners.get(name)?.({ persisted: true }),
    failSubscription: () => subscriptionFailure(new Error('Subscription unavailable')),
    get stops() { return stops; }, get timers() { return timers.size; },
    get maximumActive() { return maximumActive; }, get writes() { return writes; },
    get theme() { return sandbox.window.SlateTheme.current; } };
}
const theme = revision => ({ revision, tone: 'dark', palette: { background: '#000000', foreground: '#ffffff', ansi: [] } });
(async () => {
  const f = fixture(); await settle();
  for (let i = 0; i < 10; i++) f.event();
  assert.equal(f.requests.length, 1, 'invalidations must not overlap the startup read');
  f.requests[0].resolve(theme('old')); await settle();
  assert.equal(f.requests.length, 2, 'a burst during a read needs exactly one trailing read');
  assert.equal(f.writes, 0, 'an invalidated response must not overwrite host-injected CSS');
  assert.deepEqual(f.changes, [], 'an invalidated response must not notify render listeners');
  f.requests[1].resolve(theme('new')); await settle();
  assert.equal(f.theme.revision, 'new');
  assert.equal(f.maximumActive, 1);
  const before = f.writes;
  f.event(); await settle(); f.requests[2].resolve(theme('new')); await settle();
  assert.equal(f.writes, before, 'equal revisions must not rewrite CSS');
  f.event(); await settle(); f.event();
  f.requests[3].reject(new Error('temporary failure')); await settle();
  assert.equal(f.requests.length, 5, 'a failed read must not lose its trailing invalidation');
  f.requests[4].resolve(theme('recovered')); await settle();
  assert.equal(f.theme.revision, 'recovered');
  assert.equal(f.maximumActive, 1);
  const page = fixture(); await settle();
  page.lifecycle('pagehide');
  assert.equal(page.stops, 1, 'pagehide must stop the old subscription');
  page.event();
  assert.equal(page.requests.length, 1, 'hidden pages must not schedule reads');
  page.lifecycle('pageshow'); await settle();
  assert.equal(page.requests.length, 2, 'restored pages must take a fresh snapshot');
  page.requests[0].resolve(theme('retired')); await settle();
  assert.equal(page.writes, 0, 'retired-page completion must not touch the restored page');
  page.requests[1].resolve(theme('restored')); await settle();
  assert.deepEqual(page.changes, ['restored']);
  assert.equal(page.timers, 0);
  const immediate = fixture(); immediate.lifecycle('pagehide'); await settle();
  assert.equal(immediate.requests.length, 0, 'retirement before startup microtasks must avoid native work');
  assert.equal(immediate.stops, 1, 'late subscription acquisition must be retired');
  const retry = fixture(); await settle(); retry.requests[0].resolve(theme('initial')); await settle();
  retry.failSubscription(); retry.failSubscription(); await settle();
  assert.equal(retry.requests.length, 2);
  assert.equal(retry.timers, 1, 'duplicate failure reports must share one retry');
  retry.lifecycle('pagehide');
  assert.equal(retry.timers, 0, 'pagehide must cancel its retry timer');
  retry.requests[1].resolve(theme('retired retry')); await settle();
  assert.deepEqual(retry.changes, ['initial']);
  const reconnect = fixture(); await settle(); reconnect.requests[0].resolve(theme('initial')); await settle();
  reconnect.failSubscription(); await settle(); reconnect.requests[1].resolve(theme('initial')); await settle();
  reconnect.fireRetry(); await settle();
  assert.equal(reconnect.requests.length, 3, 'resubscription must snapshot changes made during backoff');
  reconnect.requests[2].resolve(theme('changed during backoff')); await settle();
  assert.deepEqual(reconnect.changes, ['initial', 'changed during backoff']);
  const callbacks = fixture();
  let notified = 0;
  callbacks.listen(() => { throw new Error('Broken listener'); });
  callbacks.listen(() => { notified++; });
  await settle(); callbacks.requests[0].resolve(theme('one')); await settle();
  assert.equal(notified, 1, 'one failed listener must not prevent other listeners updating');
  assert.equal(callbacks.errors.length, 1, 'listener failures must be reported');
  const cancelled = fixture(); await settle(); cancelled.lifecycle('pagehide');
  cancelled.requests[0].reject(new Error('Document retired')); await settle();
  assert.equal(cancelled.requests.length, 1);
  assert.equal(cancelled.timers, 0, 'document retirement must not start retry work');
  console.log('PASS appearance refresh: single-flight, stale-result rejection, trailing invalidation, equality, failure and page lifetime');
})().catch(error => { console.error(error); process.exitCode = 1; });
