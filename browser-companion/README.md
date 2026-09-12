# Velocity · Tidy tabs

A local Chrome companion for Velocity. Open **Tidy tabs** in Velocity for setup, or load this directory as an unpacked extension at `chrome://extensions` (Developer mode → Load unpacked). Click its toolbar icon to open the organizer. Install it separately in each profile.

- **Organize:** proposes groups by repository, title evidence, or site. Review and rename groups, then place their tabs together using Chrome's native groups. Windows and profiles stay separate; existing groups and pinned tabs are preserved.
- **Clean up:** shows exact-URL duplicates and tabs whose Chrome `lastAccessed` exceeds 7/14/30/90 days. Missing timestamps are not treated as old. Nothing is preselected for closure. “Unnecessary” remains your decision.
- **Automatic duplicates:** optional, off by default. Every five minutes, close only discarded (unloaded) duplicates in the same window. Preserve a copy and exclude pinned, active, audible/muted, loading, and already-grouped tabs. URL query strings and fragments must match exactly. Loaded duplicates require review.
- **Recovery:** keeps up to 200 closure records locally. Reopen their URLs in this profile; unsaved page state is not restored.
- **Undo organization:** restores the prior order and removes only the groups created by that operation. Refuses to overwrite subsequent tab changes.

Permissions: `tabs` (titles/URLs and last-used metadata), `tabGroups`, `storage`, `alarms`. No host permissions, content scripts, history database, server, or AI calls. Incognito is disabled. Safari organization is not supported in this version.

`node --test browser-companion/tests/*.test.js` tests planning, changed-tab rejection, duplicate safety, grouping and undo with an in-memory Chrome API fixture. `organizer.html?demo=1` outside the extension renders fictional tabs for visual review and cannot operate real tabs.

The manifest public key fixes the unpacked extension ID across releases. It is not a secret or an authentication credential. A loaded copy placed by Velocity lives in `~/Library/Application Support/Velocity/TidyTabs`; refresh that copy and reload it from Chrome's extensions page when upgrading the companion.
