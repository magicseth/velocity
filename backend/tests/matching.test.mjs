import { test } from 'node:test';
import assert from 'node:assert/strict';
import { matchRequest, validateMatches } from '../lib/matching.ts';
const input={query:'touchscreen terminal',windows:[{id:'0',app:'Terminal',title:'Waveshare'}]};
test('matching only returns unique existing IDs, with bounded input and output',()=>{
 assert.deepEqual(validateMatches(input,{ids:['0']}),{ids:['0']});
 assert.throws(()=>validateMatches(input,{ids:['1']}));
 assert.throws(()=>validateMatches(input,{ids:['0','0']}));
 assert.throws(()=>validateMatches(input,{ids:[],script:'arbitrary action'}));
 assert.throws(()=>matchRequest.parse({...input,query:'a'}));
});
