export function webURL(tab) {
  try { const u = new URL(tab.url); return ['http:', 'https:'].includes(u.protocol) && !u.username && !u.password ? u : null; }
  catch { return null; }
}
export function protectedReason(tab) {
  if (tab.incognito) return 'Private tab';
  if (tab.pinned) return 'Pinned';
  if (tab.active) return 'Active in its window';
  if (tab.audible || tab.mutedInfo?.muted) return 'Audio or muted media';
  if (tab.status === 'loading') return 'Loading';
  if (tab.groupId !== undefined && tab.groupId !== -1) return 'Already grouped';
  return null;
}
export function sameTab(expected, actual) {
  return expected.id === actual.id && expected.windowId === actual.windowId && expected.url === actual.url && expected.title === actual.title;
}
export function duplicates(tabs) {
  const buckets = new Map();
  for (const tab of tabs) {
    if (!webURL(tab) || tab.incognito) continue;
    // Exact URL, including query and fragment. A separate window may be a separate task.
    const key = JSON.stringify([tab.windowId, tab.url]);
    const list = buckets.get(key) ?? []; list.push(tab); buckets.set(key, list);
  }
  const result = [];
  for (const list of buckets.values()) {
    list.sort((a, b) => Number(!!protectedReason(b)) - Number(!!protectedReason(a)) ||
      Number(a.discarded) - Number(b.discarded) || (b.lastAccessed ?? 0) - (a.lastAccessed ?? 0) || a.index - b.index);
    const keeper = list[0];
    for (const tab of list.slice(1)) if (!protectedReason(tab)) {
      result.push({tab, keeper, reason: 'Exact duplicate in the same window', automatic: tab.discarded === true});
    }
  }
  return result;
}
export function cleanupPlan(tabs, days = 30, now = Date.now()) {
  const dupes = duplicates(tabs), duplicateIDs = new Set(dupes.map(d => d.tab.id));
  const stale = tabs.filter(t => webURL(t) && !protectedReason(t) && !duplicateIDs.has(t.id) &&
    Number.isFinite(t.lastAccessed) && t.lastAccessed > 0 && now - t.lastAccessed >= days * 86400000)
    .map(tab => ({tab, reason: `Not active for ${Math.floor((now - tab.lastAccessed) / 86400000)} days`, automatic: false}));
  return [...dupes, ...stale];
}
export function organizePlan(tabs) {
  const repositories = tabs.flatMap(tab => {
    const u = webURL(tab), path = u?.pathname.split('/').filter(Boolean) ?? [];
    return u && ['github.com', 'gitlab.com', 'bitbucket.org'].includes(u.hostname) && path.length >= 2 ?
      [{name: path[1], label: `${path[0]}/${path[1]}`}] : [];
  });
  const buckets = new Map();
  for (const tab of tabs) {
    const u = webURL(tab);
    if (!u || tab.incognito || tab.pinned || tab.groupId !== -1) continue;
    const text = `${tab.title ?? ''} ${u.pathname}`.toLowerCase();
    const projects = [...new Set(repositories.filter(p => p.name.length >= 4 &&
      text.split(/[^\p{L}\p{N}_-]+/u).includes(p.name.toLowerCase())).map(p => p.label))];
    const topic = projects.length === 1 ? projects[0] : u.hostname.replace(/^www\./, '');
    const key = JSON.stringify([tab.windowId, topic]);
    const group = buckets.get(key) ?? {id: key, windowId: tab.windowId, name: topic, tabs: []};
    group.tabs.push(tab); buckets.set(key, group);
  }
  return [...buckets.values()].filter(g => g.tabs.length >= 2).map(g => ({...g, tabs: g.tabs.sort((a,b) => a.index-b.index)}));
}
export function fingerprint(tabs) {
  return JSON.stringify(tabs.map(t => [t.windowId,t.id,t.index,t.groupId,t.pinned,t.url]).sort((a,b) => a[0]-b[0] || a[2]-b[2]));
}
