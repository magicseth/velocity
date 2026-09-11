import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requestSchema, validateSuggestions } from '../lib/grouping.ts';
const group = { name: 'Checkout', reason: 'Same project', confidence: 'high', memberIds: ['a','b'] };
test('rejects invented IDs and duplicate/overlapping membership', () => {
 assert.throws(() => validateSuggestions({groups:[group]}, ['a','c']));
 assert.throws(() => validateSuggestions({groups:[group,group]}, ['a','b']));
 assert.throws(() => validateSuggestions({groups:[{...group,memberIds:['a','a']}]}, ['a','b']));
});
test('allows unrelated windows to remain unassigned', () => {
 assert.equal(validateSuggestions({groups:[group]}, ['a','b','c']).groups.length,1);
 assert.deepEqual(validateSuggestions({groups:[]}, ['a','b']),{groups:[]});
});
test('bounds metadata and rejects unexpected contents', () => {
 const candidate = {id:'a',app:'Terminal',title:'checkout',folder:'project',tabs:[]};
 assert.throws(() => requestSchema.parse({candidates:[candidate]}));
 assert.throws(() => requestSchema.parse({candidates:[candidate,{...candidate,id:'b',terminalContents:'private'}]}));
});
