import {cleanupPlan, duplicates, organizePlan, protectedReason, sameTab, fingerprint} from './planner.js';

export async function closeReviewed(api, proposed, {automatic = false} = {}) {
  let closed = 0, skipped = 0;
  for (const item of proposed) {
    const all = await api.tabs.query({windowType: 'normal'});
    const current = all.find(t => t.id === item.tab.id);
    if (!current || !sameTab(item.tab, current) || protectedReason(current) || (current.lastAccessed ?? 0) > (item.tab.lastAccessed ?? 0)) { skipped++; continue; }
    if (automatic) {
      const duplicate = duplicates(all).find(d => d.tab.id === current.id && d.automatic);
      if (!duplicate) { skipped++; continue; }
    }
    // Save the URL before closing. Reopening restores the URL, not unsaved page state.
    const {closedTabs = []} = await api.storage.local.get('closedTabs');
    const record = {id: crypto.randomUUID(), title: current.title, url: current.url, at: Date.now(), status: 'pending'};
    await api.storage.local.set({closedTabs: [record, ...closedTabs].slice(0, 200)});
    try {
      await api.tabs.remove(current.id);
      record.status = 'closed'; closed++;
    } catch { record.status = 'failed'; skipped++; }
    const latest = (await api.storage.local.get('closedTabs')).closedTabs ?? [];
    await api.storage.local.set({closedTabs: latest.map(r => r.id === record.id ? record : r)});
  }
  return {closed, skipped};
}
export async function groupReviewed(api, proposed) {
  const before = await api.tabs.query({windowType: 'normal'});
  const created = []; let grouped = 0, skipped = 0;
  // Retain each step immediately, so a partially failed action remains undoable.
  await api.storage.local.set({lastOrganization: {before, created, after: null}});
  try {
    for (const group of proposed) {
      const now = await api.tabs.query({windowType: 'normal'});
      const eligible = group.tabs.every(expected => {
        const tab = now.find(t => t.id === expected.id);
        return tab && sameTab(expected, tab) && !tab.incognito && !tab.pinned && tab.groupId === -1;
      });
      if (!eligible) { skipped += group.tabs.length; continue; }
      const id = await api.tabs.group({tabIds: group.tabs.map(t => t.id), createProperties: {windowId: group.windowId}});
      created.push(id);
      await api.storage.local.set({lastOrganization: {before, created, after: fingerprint(await api.tabs.query({windowType: 'normal'}))}});
      await api.tabGroups.update(id, {title: group.name.slice(0, 80), color: ['blue','cyan','green','purple'][created.length % 4], collapsed: false});
      grouped += group.tabs.length;
    }
  } finally {
    await api.storage.local.set({lastOrganization: {before, created, after: fingerprint(await api.tabs.query({windowType: 'normal'}))}});
  }
  return {grouped, skipped};
}
export async function undoOrganization(api) {
  const {lastOrganization: saved} = await api.storage.local.get('lastOrganization');
  if (!saved?.after) throw new Error('No organization to undo.');
  let current = await api.tabs.query({windowType: 'normal'});
  if (fingerprint(current) !== saved.after) throw new Error('Tabs changed since organization. Undo was stopped to preserve your newer changes.');
  const ids = current.filter(t => saved.created.includes(t.groupId)).map(t => t.id);
  if (ids.length) await api.tabs.ungroup(ids);
  const movedGroups = new Set();
  try {
    for (const tab of [...saved.before].sort((a,b) => a.windowId-b.windowId || a.index-b.index)) {
      if (tab.pinned) continue;
      if (tab.groupId !== -1) {
        if (!movedGroups.has(tab.groupId)) {
          await api.tabGroups.move(tab.groupId, {windowId: tab.windowId, index: tab.index});
          movedGroups.add(tab.groupId);
        }
      } else await api.tabs.move(tab.id, {windowId: tab.windowId, index: tab.index});
    }
    if (fingerprint(await api.tabs.query({windowType:'normal'})) !== fingerprint(saved.before)) throw new Error('Some tabs could not return to their original order. You can retry Undo.');
  } catch (error) {
    await api.storage.local.set({lastOrganization:{...saved,after:fingerprint(await api.tabs.query({windowType:'normal'}))}});
    throw error;
  }
  await api.storage.local.remove('lastOrganization');
  return {message: 'Original tab order restored.'};
}
export async function snapshot(api) {
  const tabs = await api.tabs.query({windowType: 'normal'});
  const settings = await api.storage.local.get({autoDuplicates: false, staleDays: 30, closedTabs: []});
  return {tabs, settings, cleanup: cleanupPlan(tabs, settings.staleDays), groups: organizePlan(tabs)};
}
