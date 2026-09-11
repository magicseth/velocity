import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requestSchema, validateSuggestions, prepareSuggestions } from '../lib/grouping.ts';
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

test('keeps valid proposals while leaving cross-group overlaps unassigned', () => {
 const output = prepareSuggestions({groups:[
  {...group, memberIds:['a','b','shared']},
  {...group, name:'Docs', memberIds:['c','d','shared']},
  {...group, name:'Independent', memberIds:['e','f']},
 ]}, ['a','b','c','d','e','f','shared']);
 assert.deepEqual(output.groups.map(g => g.memberIds), [['a','b'],['c','d'],['e','f']]);
 assert.deepEqual(output.groups.map(g => g.confidence), ['low','low','high']);
});
test('drops undersized groups and invented IDs, deduplicates within a group', () => {
 const output = prepareSuggestions({groups:[
  {...group, memberIds:['a','a','b','invented']},
  {...group, memberIds:['c','unknown']},
 ]}, ['a','b','c']);
 assert.deepEqual(output.groups.map(g => g.memberIds), [['a','b']]);
 assert.throws(() => prepareSuggestions({groups:[{...group, memberIds:'bad'}]}, ['a','b']));
 assert.throws(() => prepareSuggestions({groups:[]}, ['a','a']));
});
