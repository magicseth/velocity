import {duplicates} from './planner.js';
import {snapshot, closeReviewed, groupReviewed, undoOrganization} from './engine.js';
let busy = false;
async function exclusive(work) {
  if (busy) throw new Error('A tab operation is already running.');
  busy = true; try { return await work(); } finally { busy = false; }
}
async function openOrganizer() {
  const url = chrome.runtime.getURL('organizer.html');
  const existing = (await chrome.tabs.query({})).find(t => t.url === url);
  if (existing) { await chrome.tabs.update(existing.id,{active:true}); await chrome.windows.update(existing.windowId,{focused:true}); }
  else await chrome.tabs.create({url});
}
chrome.action.onClicked.addListener(openOrganizer);
chrome.runtime.onInstalled.addListener(async () => {
  await chrome.alarms.create('duplicates', {periodInMinutes: 5});
  await openOrganizer();
});
chrome.runtime.onStartup.addListener(() => chrome.alarms.create('duplicates',{periodInMinutes:5}));
chrome.alarms.onAlarm.addListener(async alarm => {
  if (alarm.name !== 'duplicates' || busy) return;
  if (!(await chrome.storage.local.get('autoDuplicates')).autoDuplicates) return;
  try {
    await exclusive(async () => {
      const plan = duplicates(await chrome.tabs.query({windowType:'normal'})).filter(d => d.automatic);
      const result = await closeReviewed(chrome, plan, {automatic:true});
      if (result.closed) await chrome.action.setBadgeText({text: String(result.closed)});
    });
  } catch { /* A transient failure retries on the next alarm, never force-closes. */ }
});
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('organizer.html')) return false;
  (async () => {
    if (message.type === 'snapshot') return snapshot(chrome);
    if (message.type === 'settings') {
      await chrome.storage.local.set({autoDuplicates: message.autoDuplicates === true, staleDays: [7,14,30,90].includes(message.staleDays) ? message.staleDays : 30});
      return snapshot(chrome);
    }
    return exclusive(async () => {
      const current = await snapshot(chrome);
      if (message.type === 'close') {
        const ids = new Set(message.ids);
        // Use a server-side fresh plan, plus the reviewed identity, not arbitrary IDs.
        const selected = current.cleanup.filter(c => ids.has(c.tab.id));
        const expected = new Map((message.expected ?? []).map(t => [t.id,t]));
        const eligible = selected.filter(c => JSON.stringify([c.tab.url,c.tab.title,c.tab.windowId]) === JSON.stringify([expected.get(c.tab.id)?.url,expected.get(c.tab.id)?.title,expected.get(c.tab.id)?.windowId]));
        const result = await closeReviewed(chrome, eligible);
        result.skipped += ids.size - eligible.length;
        return result;
      }
      if (message.type === 'group') {
        const choices = new Map((message.groups ?? []).map(g => [g.id,g]));
        const plan = current.groups.filter(g => choices.has(g.id) && JSON.stringify(g.tabs.map(t=>[t.id,t.url,t.title])) === JSON.stringify(choices.get(g.id).tabs.map(t=>[t.id,t.url,t.title])));
        const result = await groupReviewed(chrome,plan.map(g => ({...g,name:String(choices.get(g.id).name || g.name)})));
        result.skipped += [...choices.values()].filter(g => !plan.some(p => p.id === g.id)).reduce((sum,g)=>sum+g.tabs.length,0);
        return result;
      }
      if (message.type === 'undo') return undoOrganization(chrome);
      if (message.type === 'reopen') {
        const record = current.settings.closedTabs.find(r => r.id === message.id && r.status === 'closed');
        if (!record) throw new Error('That closed tab is no longer in the recovery list.');
        await chrome.tabs.create({url:record.url,active:false});
        await chrome.storage.local.set({closedTabs:current.settings.closedTabs.filter(r => r.id !== record.id)});
        return {message:'URL reopened in this profile.'};
      }
      throw new Error('Unknown tab operation.');
    });
  })().then(data => respond({data}), error => respond({error: error.message}));
  return true;
});
