// Offline producer check, not browser acceptance. Execute the exact candidate
// JavaScript against a small DOM test double; never copy the function here.
// Usage: node ThirdParty/Cua/scroll-readback-candidate.test.mjs <pointer.rs>
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(process.argv[2], 'utf8');
const script = source.match(/const DOM_SCROLL_FUNCTION: &str = r#"([\s\S]*?)"#;/)?.[1];
assert.ok(script, 'candidate scroll producer must exist');
const scroll = vm.runInNewContext(`(${script})`, {
  Event: class { constructor(type) { this.type = type; } },
  WheelEvent: class { constructor(type, values) { this.type = type; Object.assign(this, values); } },
});

function probe({ before = 0, wheel = () => {}, onScroll = () => {}, nested = false, expectedCalls = 1 } = {}) {
  let calls = 0;
  const doc = { defaultView: { getComputedStyle: node => ({ overflow: node.overflow ?? 'visible', overflowX: '', overflowY: '' }) } };
  const target = {
    ownerDocument: doc, isConnected: true, overflow: 'auto',
    scrollLeft: 0, scrollTop: before, scrollWidth: 120, clientWidth: 120,
    scrollHeight: 1100, clientHeight: 100,
    scrollBy(dx, dy) { calls++; this.scrollLeft = Math.max(0, Math.min(0, this.scrollLeft + dx)); this.scrollTop = Math.max(0, Math.min(1000, this.scrollTop + dy)); },
    contains(node) { return node === this || node.parentElement === this; },
    dispatchEvent(event) { if (event.type === 'wheel') wheel(target, origin); else if (event.type === 'scroll') onScroll(target, origin); return true; },
  };
  doc.documentElement = { ownerDocument: doc, isConnected: true };
  doc.scrollingElement = target;
  const origin = nested ? {
    ownerDocument: doc, isConnected: true, parentElement: target,
    dispatchEvent: event => target.dispatchEvent(event),
  } : target;
  const value = scroll.call(origin, 0, 500);
  assert.equal(calls, expectedCalls, 'no stale-target actuator call or retry');
  return value;
}

const first = probe();
assert.equal(first.before_y, 0); assert.equal(first.after_y, 500);
assert.equal(first.max_y, 1000); assert.equal(first.connected, true);
const second = probe({ before: first.after_y, nested: true });
assert.equal(second.before_y, 500); assert.equal(second.after_y, 1000);
assert.equal(probe({ before: 900 }).after_y, 1000);
assert.equal(probe({ before: 1000 }).after_y, 1000);
const handlerMovement = probe({ wheel: target => { target.scrollTop += 100; } });
assert.equal(handlerMovement.before_y, 0, 'capture before wheel listeners');
assert.equal(handlerMovement.after_y, 600, 'unexpected handler movement stays visible to classification');
assert.equal(probe({ onScroll: target => { target.isConnected = false; } }).connected, false);
assert.equal(probe({ onScroll: target => { target.scrollHeight += 50; } }).connected, false);
assert.equal(probe({ onScroll: target => { target.ownerDocument = {}; } }).connected, false);
assert.equal(probe({ nested: true, expectedCalls: 0, wheel: (_, origin) => { origin.ownerDocument = {}; } }).connected, false);
assert.equal(probe({ nested: true, expectedCalls: 0, wheel: (_, origin) => { origin.parentElement = {}; } }).connected, false);
assert.equal(probe({ nested: true, onScroll: (_, origin) => { origin.parentElement = {}; } }).connected, false);
console.log('11 offline scroll producer scenarios passed; no live browser claim.');
