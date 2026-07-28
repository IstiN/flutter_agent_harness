// Reminders live tile — 1x1 launcher widget (~104px square canvas):
// the next 1-2 upcoming reminders from jsr.storage (the list widget.js
// maintains under the 'reminders' key). Display-only: any tap opens the
// full Reminders app. Re-reads storage on the host's 'tile.refresh' event.
// All colors come from jsr.theme (follows the host's light/dark mode).
(function() {
  var upcoming = []; // [{id, title, atMs}] — future only, soonest first

  function countdownLabel(atMs) {
    var seconds = Math.max(0, Math.round((atMs - Date.now()) / 1000));
    if (seconds < 60) return 'in ' + seconds + 's';
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return 'in ' + minutes + 'm';
    var hours = Math.floor(minutes / 60);
    return 'in ' + hours + 'h ' + (minutes % 60) + 'm';
  }

  function reminderRow(reminder) {
    var t = jsr.theme;
    return {
      type: 'row', crossAxisAlignment: 'center', children: [
        { type: 'icon', name: 'notifications', color: t.accent, size: 12 },
        { type: 'sizedBox', width: 5 },
        { type: 'expanded', child: {
          type: 'text', data: reminder.title,
          maxLines: 1, overflow: 'ellipsis',
          style: { color: t.text, fontSize: 11, fontWeight: 'w600' } } },
        { type: 'sizedBox', width: 4 },
        { type: 'text', data: countdownLabel(reminder.atMs),
          style: { color: t.muted, fontSize: 9 } },
      ] };
  }

  function render() {
    // Read jsr.theme fresh on every render — the object is replaced when
    // the host theme changes.
    var t = jsr.theme;
    var children = [
      { type: 'row', crossAxisAlignment: 'center', children: [
        { type: 'icon', name: 'notifications', color: t.accent, size: 14 },
        { type: 'sizedBox', width: 4 },
        { type: 'expanded', child: {
          type: 'text', data: 'Reminders',
          maxLines: 1, overflow: 'ellipsis',
          style: { color: t.muted, fontSize: 11 } } },
      ] },
      { type: 'sizedBox', height: 6 },
    ];
    if (!upcoming.length) {
      children.push({ type: 'expanded', child: {
        type: 'center', child: {
          type: 'text', data: 'No reminders',
          style: { color: t.muted, fontSize: 11, textAlign: 'center' } } } });
    } else {
      var shown = upcoming.slice(0, 2);
      for (var i = 0; i < shown.length; i++) {
        children.push(reminderRow(shown[i]));
        if (i < shown.length - 1) {
          children.push({ type: 'sizedBox', height: 5 });
        }
      }
      children.push({ type: 'expanded', child: { type: 'sizedBox' } });
    }
    jsr.render({
      type: 'container',
      padding: [10, 8, 10, 8],
      child: { type: 'column', crossAxisAlignment: 'stretch', children: children },
    });
  }

  function load() {
    jsr.storage.get('reminders').then(function(saved) {
      var now = Date.now();
      var list = Array.isArray(saved) ? saved : [];
      upcoming = list
        .filter(function(r) { return r && r.atMs > now; })
        .sort(function(a, b) { return a.atMs - b.atMs; });
      render();
    });
  }

  jsr.onEvent(function(actionId) {
    // Re-read storage when the host asks for a refresh.
    if (actionId === 'tile.refresh') load();
  });
  // Re-render with the new colors when the host flips light/dark mode.
  jsr._onThemeChange = function() { render(); };
  load();
  render();
})();
