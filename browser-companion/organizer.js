import {cleanupPlan, organizePlan} from './planner.js';
let data, busy = false;
const selected = new Set(), groupChoices = new Map();
const $ = id => document.getElementById(id);
const demo = !globalThis.chrome?.runtime?.id && new URLSearchParams(location.search).has('demo');
function element(tag, text, className) { const e=document.createElement(tag); if(text!==undefined)e.textContent=text;if(className)e.className=className;return e; }
async function send(message) {
  if (demo) {
    if (message.type !== 'snapshot') throw new Error('This is a visual preview. Install the companion to organize real tabs.');
    const topics = [['Velocity','https://github.com/magicseth/velocity','Velocity — GitHub'],['Velocity','https://github.com/magicseth/velocity/issues','Velocity — Issues'],['Convex','https://docs.convex.dev/functions','Functions · Convex Docs'],['Convex','https://docs.convex.dev/database','Database · Convex Docs'],['Weekend','https://example.com/trails','Trails to explore'],['Weekend','https://example.com/trails','Trails to explore']];
    const tabs=topics.map((t,i)=>({id:i+1,windowId:1,index:i,title:t[2],url:t[1],groupId:-1,active:false,pinned:false,status:'complete',discarded:i===5,lastAccessed:Date.now()-(i>3?45:2)*86400000}));
    return {tabs,settings:{autoDuplicates:false,staleDays:30,closedTabs:[]},cleanup:cleanupPlan(tabs),groups:organizePlan(tabs)};
  }
  const response = await chrome.runtime.sendMessage(message);
  if(response.error)throw new Error(response.error);return response.data;
}
function status(text){$('status').textContent=text;$('status').classList.add('visible');}
async function perform(work){if(busy)return;busy=true;document.querySelectorAll('button,input,select').forEach(e=>e.disabled=true);try{await work();}catch(e){status(e.message);}finally{busy=false;document.querySelectorAll('button,input,select').forEach(e=>e.disabled=false);updateButtons();}}
function row(tab, reason) {
  const e=element('div',undefined,'row'),url=new URL(tab.url);
  e.append(element('span',url.hostname.replace(/^www\./,'')[0]?.toUpperCase()??'↗','dot'));
  const details=element('div',undefined,'details');details.append(element('strong',tab.title||url.hostname),element('small',url.hostname+url.pathname));e.append(details);
  if(reason)e.append(element('span',reason,'reason'));return e;
}
function updateButtons(){ $('close').textContent=`Close ${selected.size} selected tabs`;$('close').disabled=busy||selected.size===0;$('group').disabled=busy||![...groupChoices.values()].some(g=>g.selected); }
function render(){
  selected.clear();groupChoices.clear();
  const windowIDs=[...new Set(data.tabs.map(t=>t.windowId))];
  $('total').textContent=`${data.tabs.length} tabs · ${windowIDs.length} ${windowIDs.length===1?'window':'windows'}`;
  $('cleanupCount').textContent=data.cleanup.length?`(${data.cleanup.length})`:'';
  $('days').value=data.settings.staleDays;$('auto').checked=data.settings.autoDuplicates;
  $('groupList').replaceChildren();
  for(const g of data.groups){
    groupChoices.set(g.id,{...g,selected:true});
    const card=element('div',undefined,'card'),head=element('div',undefined,'card-head'),check=element('input');check.type='checkbox';check.checked=true;check.setAttribute('aria-label',`Organize ${g.name}`);check.addEventListener('change',()=>{groupChoices.get(g.id).selected=check.checked;updateButtons();});
    const name=element('input');name.type='text';name.value=g.name;name.maxLength=80;name.setAttribute('aria-label','Group name');name.addEventListener('input',()=>groupChoices.get(g.id).name=name.value);
    head.append(check,name,element('span',`${g.tabs.length} tabs · Window ${windowIDs.indexOf(g.windowId)+1}`,'badge'));card.append(head);g.tabs.forEach(t=>card.append(row(t)));$('groupList').append(card);
  }
  if(!data.groups.length)$('groupList').append(element('div','No new groups to suggest. Existing groups and pinned tabs are kept in place.','empty'));
  $('cleanupList').replaceChildren();
  for(const c of data.cleanup){const e=row(c.tab,c.reason),check=element('input');check.type='checkbox';check.setAttribute('aria-label',`Close ${c.tab.title}`);check.addEventListener('change',()=>{check.checked?selected.add(c.tab.id):selected.delete(c.tab.id);updateButtons();});e.prepend(check);$('cleanupList').append(e);}
  if(!data.cleanup.length)$('cleanupList').append(element('div','Nothing to clean up under these rules. Unknown last-used times are never treated as old.','empty'));
  $('recoveryList').replaceChildren();
  for(const r of data.settings.closedTabs.filter(r=>r.status==='closed')){const e=row(r),button=element('button','Reopen URL');button.addEventListener('click',()=>perform(async()=>{await send({type:'reopen',id:r.id});await refresh();status('URL reopened.');}));e.append(button);$('recoveryList').append(e);}
  if(!$('recoveryList').children.length)$('recoveryList').append(element('div','Tabs closed by Velocity will appear here.','empty'));
  updateButtons();
}
async function refresh(){data=await send({type:'snapshot'});render();}
$('refresh').addEventListener('click',()=>perform(refresh));
$('group').addEventListener('click',()=>perform(async()=>{const result=await send({type:'group',groups:[...groupChoices.values()].filter(g=>g.selected)});await refresh();status(`Grouped ${result.grouped} tabs. Skipped ${result.skipped} changed tabs.`);}));
$('close').addEventListener('click',()=>perform(async()=>{const result=await send({type:'close',ids:[...selected],expected:data.cleanup.filter(c=>selected.has(c.tab.id)).map(c=>c.tab)});await refresh();status(`Closed ${result.closed} tabs. Skipped ${result.skipped}. Reopen URLs in Recently closed.`);}));
$('undo').addEventListener('click',()=>perform(async()=>{const result=await send({type:'undo'});await refresh();status(result.message);}));
for(const id of ['auto','days'])$(id).addEventListener('change',()=>perform(async()=>{data=await send({type:'settings',autoDuplicates:$('auto').checked,staleDays:Number($('days').value)});render();}));
for(const button of document.querySelectorAll('[data-view]'))button.addEventListener('click',()=>{for(const id of ['groups','cleanup','recovery'])$(id).hidden=id!==button.dataset.view;document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b===button));});
$('demo').hidden=!demo;perform(refresh);
