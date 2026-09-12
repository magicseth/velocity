import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classificationRequest, validateClassification } from '../lib/classification.ts';
const overview = Array.from({length: 400}, (_, i) => ({id:`w${i}`,app:'App',title:'Project',folder:'Projects'}));
const input = {overview, candidates: overview.slice(0,40).map(w => ({...w,tabs:Array(30).fill('Tab title')})), objectives:[{id:'g1',name:'Checkout',reason:'Shared project'}]};
const group = {objectiveID:'g1',name:'Checkout',reason:'Shared project',confidence:'high',memberIds:['w0']};
test('batches retain a complete overview and all tab context', () => {
 const parsed = classificationRequest.parse(input);
 assert.equal(parsed.overview.length,400);
 assert.equal(parsed.candidates[0].tabs.length,30);
 assert.throws(() => classificationRequest.parse({...input,candidates:Array(41).fill(input.candidates[0])}));
});
test('singleton proposals can attach to objectives from earlier batches', () => {
 assert.deepEqual(validateClassification(input,{groups:[group]}).groups[0].memberIds,['w0']);
 assert.equal(validateClassification(input,{groups:[{...group,objectiveID:null}]}).groups.length,1);
});
test('rejects invented objectives, overview-only windows, duplicates, and malformed output', () => {
 assert.throws(() => validateClassification(input,{groups:[{...group,objectiveID:'invented'}]}));
 assert.throws(() => validateClassification(input,{groups:[{...group,memberIds:['w399']}]}));
 assert.throws(() => validateClassification(input,{groups:[group,group]}));
 assert.throws(() => validateClassification(input,{groups:[{...group,memberIds:[]}]}));
});
