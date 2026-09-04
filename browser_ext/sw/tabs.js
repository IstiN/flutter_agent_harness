// Task tab groups: track only tabs the SW opened, label them `fa — <task>`,
// close them on task_end / bridge disconnect. Never touches untracked tabs (AC17).
const TITLE_PREFIX = 'fa — ';
const QKEY = 'faTask';

const session = chrome.storage.session ?? memSession();
let taskId = null;
let groupId = null;
const tracked = new Set();
let note = '';

function memSession() {
  const m = new Map();
  return {
    async get(k) { return { [k]: m.get(k) }; },
    async set(o) { for (const [k, v] of Object.entries(o)) m.set(k, v); },
  };
}

const persist = () => session.set({ [QKEY]: { taskId, groupId, tabIds: [...tracked] } }).catch(() => {});

/** New bridge session: label for this task's tab group. */
export async function beginTask(id) {
  taskId = id ?? crypto.randomUUID();
  note = '';
  await persist();
}

/** Track a tab the SW itself created and pull it into the task group. */
export async function trackCreated(tab) {
  if (!tab?.id || taskId === null) return;
  tracked.add(tab.id);
  await ensureGroup(tab.id);
}

async function ensureGroup(tabId) {
  if (groupId !== null) {
    try {
      await chrome.tabs.group({ tabIds: tabId, groupId });
      await persist();
      return;
    } catch {
      groupId = null; // group vanished (user ungrouped); recreate below
    }
  }
  try {
    groupId = await chrome.tabs.group({ tabIds: [tabId] });
    await chrome.tabGroups.update(groupId, { title: TITLE_PREFIX + taskId });
  } catch (e) {
    note = `grouping failed: ${e.message}`;
    groupId = null;
  }
  await persist();
}

/** tabs.onCreated: adopt only descendants of tabs we opened. */
export function onTabCreated(tab) {
  if (tab.openerTabId && tracked.has(tab.openerTabId)) trackCreated(tab);
}

/** tabs.onRemoved: prune tracking; a user-closed group is a note, not a crash. */
export function onTabRemoved(tabId) {
  if (!tracked.delete(tabId)) return;
  if (tracked.size === 0 && taskId !== null) note = 'task tabs closed';
  persist();
}
/** Close ONLY tracked tabs; reset state. Returns how many were closed. */
export async function taskEnd() {
  const ids = [...tracked];
  tracked.clear();
  groupId = null;
  taskId = null;
  note = '';
  await persist();
  let cleaned = 0;
  for (const id of ids) {
    try { await chrome.tabs.remove(id); cleaned++; } catch { /* already gone */ }
  }
  return cleaned;
}

/** E24: on SW wake, adopt the labelled group by title, else clean close. */
export async function init() {
  const o = await session.get(QKEY);
  const saved = o?.[QKEY];
  if (!saved?.taskId) return;
  taskId = saved.taskId;
  let adopted = null;
  try {
    [adopted] = await chrome.tabGroups.query({ title: TITLE_PREFIX + taskId });
  } catch { adopted = null; }
  if (adopted) {
    groupId = adopted.id;
    tracked.clear();
    for (const t of await chrome.tabs.query({ groupId: adopted.id })) tracked.add(t.id);
  } else {
    // Group gone: close any still-alive tracked tabs so no half-labelled orphans remain.
    for (const id of saved.tabIds ?? []) {
      try { await chrome.tabs.get(id); await chrome.tabs.remove(id); } catch { /* gone */ }
    }
    tracked.clear();
    groupId = null;
  }
  await persist();
}

/** Status snapshot for the panel / browserReq results. */
export function status() {
  return { taskId, tracked: tracked.size, groupId, ...(note ? { note } : {}) };
}
