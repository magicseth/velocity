import {test} from 'node:test';
import assert from 'node:assert/strict';
import {duplicates,cleanupPlan,organizePlan,fingerprint} from '../planner.js';
import {closeReviewed,groupReviewed,undoOrganization} from '../engine.js';
const tab=(id,extra={})=>({id,windowId:1,index:id-1,url:'https://example.com/page',title:'Page',pinned:false,active:false,audible:false,status:'complete',groupId:-1,discarded:false,lastAccessed:1000,...extra});
function fake(initial){
 let tabs=structuredClone(initial),stored={},nextGroup=100;const calls=[];
 const reindex=()=>{const windows=new Set(tabs.map(t=>t.windowId));for(const w of windows)tabs.filter(t=>t.windowId===w).forEach((t,i)=>t.index=i);};
 const move=(ids,index)=>{const selected=tabs.filter(t=>ids.includes(t.id));tabs=tabs.filter(t=>!ids.includes(t.id));tabs.splice(index,0,...selected);reindex();};
 const api={calls,get all(){return tabs},get saved(){return stored},tabs:{
  async query(){return structuredClone(tabs)},async remove(id){calls.push(['remove',id]);tabs=tabs.filter(t=>t.id!==id);reindex();},
  async group({tabIds}){const id=nextGroup++;tabIds.forEach(tid=>tabs.find(t=>t.id===tid).groupId=id);move(tabIds,Math.min(...tabs.filter(t=>tabIds.includes(t.id)).map(t=>t.index)));return id;},
  async ungroup(ids){ids.forEach(id=>tabs.find(t=>t.id===id).groupId=-1);},
  async move(id,{index}){calls.push(['move',id,index]);move([id],index);}
 },tabGroups:{async update(){},async move(id,{index}){calls.push(['moveGroup',id,index]);move(tabs.filter(t=>t.groupId===id).map(t=>t.id),index);}},storage:{local:{async get(key){if(typeof key==='string')return structuredClone({[key]:stored[key]});return {...key,...structuredClone(stored)};},async set(data){Object.assign(stored,structuredClone(data));},async remove(key){delete stored[key]}}}};return api;
}
test('exact dedupe respects windows, query strings, fragments and protected tabs',()=>{
 const tabs=[tab(1,{active:true}),tab(2,{discarded:true}),tab(3,{url:'https://example.com/page?q=1'}),tab(4,{url:'https://example.com/page#section'}),tab(5,{windowId:2}),tab(6,{pinned:true}),tab(7,{audible:true}),tab(8,{groupId:4})];
 assert.deepEqual(duplicates(tabs).map(d=>d.tab.id),[2]);assert.equal(duplicates(tabs)[0].automatic,true);
});
test('loaded duplicates need review and never auto-close',async()=>{
 const api=fake([tab(1,{active:true}),tab(2)]);assert.equal(duplicates(api.all)[0].automatic,false);
 const result=await closeReviewed(api,duplicates(api.all),{automatic:true});assert.equal(result.closed,0);
});
test('unknown tab age is not stale; recently active and protected tabs stay',()=>{
 const now=100*86400000;
 const tabs=[tab(1,{url:'https://a.com',lastAccessed:undefined}),tab(2,{url:'https://b.com',lastAccessed:0}),tab(3,{url:'https://c.com',lastAccessed:now-86400000}),tab(4,{url:'https://d.com',lastAccessed:1}),tab(5,{url:'https://e.com',lastAccessed:1,pinned:true})];
 assert.deepEqual(cleanupPlan(tabs,30,now).map(c=>c.tab.id),[4]);
});
test('automatic cleanup keeps a copy and journals before removal',async()=>{
 const api=fake([tab(1),tab(2,{discarded:true}),tab(3,{discarded:true})]);
 const result=await closeReviewed(api,duplicates(api.all),{automatic:true});assert.equal(result.closed,2);assert.equal(api.all.length,1);assert.equal(api.saved.closedTabs.length,2);assert.ok(api.saved.closedTabs.every(r=>r.status==='closed'));
});
test('changed URLs, newly active tabs and lost keepers stop stale plans',async()=>{
 const original=[tab(1),tab(2,{discarded:true})],plan=duplicates(original);
 for(const modified of [[tab(1),tab(2,{discarded:true,url:'https://example.com/draft'})],[tab(1),tab(2,{discarded:true,active:true})],[tab(1),tab(2,{discarded:true,lastAccessed:2000})],[tab(2,{discarded:true})]]){
  const api=fake(modified);assert.equal((await closeReviewed(api,plan,{automatic:true})).closed,0);
 }
});
test('projects connect related sites without combining separate windows or existing groups',()=>{
 const tabs=[tab(1,{url:'https://github.com/team/velocity',title:'velocity'}),tab(2,{url:'https://docs.example.com/velocity/setup',title:'velocity setup'}),tab(3,{windowId:2}),tab(4,{groupId:7}),tab(5,{pinned:true})];
 const plan=organizePlan(tabs);assert.equal(plan.length,1);assert.deepEqual(plan[0].tabs.map(t=>t.id),[1,2]);assert.equal(plan[0].name,'team/velocity');
});
test('grouping and undo preserve original order and preexisting groups',async()=>{
 const original=[tab(1,{pinned:true}),tab(2,{url:'https://a.com'}),tab(3,{groupId:8}),tab(4,{groupId:8}),tab(5,{url:'https://a.com'})];
 const api=fake(original),plan=organizePlan(original);await groupReviewed(api,plan);assert.equal(api.all.filter(t=>t.groupId===8).length,2);
 await undoOrganization(api);assert.equal(fingerprint(api.all),fingerprint(original));assert.ok(api.calls.some(c=>c[0]==='moveGroup'&&c[1]===8));
});
test('undo refuses to overwrite newer tab changes',async()=>{
 const api=fake([tab(1),tab(2)]);await groupReviewed(api,organizePlan(api.all));api.all[0].url='https://example.com/new';await assert.rejects(undoOrganization(api),/changed since/);
});
test('navigation between preview and group skips the changed group',async()=>{
 const original=[tab(1),tab(2)],api=fake([tab(1),tab(2,{url:'https://elsewhere.com'})]);const result=await groupReviewed(api,organizePlan(original));assert.equal(result.grouped,0);assert.equal(api.all[0].groupId,-1);
});
