import test from 'node:test';
import assert from 'node:assert/strict';
import {matchWithJev} from '../lib/jev.ts';
const windows=Array.from({length:401},(_,i)=>({id:String(i),app:'Browser',title:`Tab ${i}`}));
const response=answers=>new Response(JSON.stringify({answers}));
test('Jev covers all candidates with bounded concurrency and preserves multiple matches',async()=>{
 const seen=new Set();let active=0,peak=0;
 const fetcher=async(url,options)=>{
  assert.equal(url,'https://api.typesafe.ai/v1/systemone');assert.equal(options.redirect,'error');
  const body=JSON.parse(options.body);assert.equal(body.model,'jev-latest');
  active++;peak=Math.max(peak,active);
  await new Promise(r=>setTimeout(r,1));active--;
  return response(Object.fromEntries(Object.keys(body.questions).map(id=>{
   assert.ok(!seen.has(id));seen.add(id);return [id,{type:'noul',noul:id==='400'?.98:id==='200'?.85:.01}];
  })));
 };
 assert.deepEqual(await matchWithJev({query:'Gmail',windows},'test',fetcher),{ids:['400','200']});
 assert.equal(seen.size,401);assert.ok(peak<=4);
});
test('Jev rejects incomplete, invented, invalid, and wrong-type answers',async()=>{
 const input={query:'Gmail',windows:windows.slice(0,1)};
 for(const answers of [{},{other:{type:'noul',noul:1}},{0:{type:'noul',noul:2}},{0:{type:'choice',noul:1}},{0:{type:'noul',noul:1},extra:{type:'noul',noul:1}}]){
  await assert.rejects(matchWithJev(input,'test',async()=>response(answers)));
 }
 await assert.rejects(matchWithJev(input,'test',async()=>new Response('',{status:429})));
 await assert.rejects(matchWithJev({...input,windows:[windows[0],windows[0]]},'test',()=>{throw Error('must not call provider')}));
});
test('Jev returns no matches and caps results in stable order',async()=>{
 for(const score of [0.1,.9]){
  const result=await matchWithJev({query:'search',windows:windows.slice(0,20)},'test',async(_,options)=>response(Object.fromEntries(Object.keys(JSON.parse(options.body).questions).map(id=>[id,{type:'noul',noul:score}]))));
  assert.deepEqual(result.ids,score<.6?[]:windows.slice(0,12).map(w=>w.id));
 }
});
test('one failed batch cancels siblings and never returns partial results',async()=>{
 let signal;
 await assert.rejects(matchWithJev({query:'search',windows:windows.slice(0,128)},'test',async(_,options)=>{
  signal=options.signal;
  const ids=Object.keys(JSON.parse(options.body).questions);
  if(ids.includes('64')) return new Response('',{status:503});
  return response(Object.fromEntries(ids.map(id=>[id,{type:'noul',noul:1}])));
 }));
 assert.equal(signal.aborted,true);
});
test('a tied yes/no score is not considered a match',async()=>{
 assert.deepEqual(await matchWithJev({query:'search',windows:windows.slice(0,1)},'test',async()=>response({0:{type:'noul',noul:.5}})),{ids:[]});
});
