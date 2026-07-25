// Reminders widget — local notification reminders via the jsr.fa.notify
// bridge. Schedule a reminder in N minutes, keep a persistent list (in-
// memory + jsr.storage), cancel per row.
(function() {
  var MAX_MINUTES = 10080; // one week

  var t = jsr.theme;
  var loading = true;
  var reminders = []; // [{id, title, atMs}]
  var error = null; // { kind: 'permission'|'error', message: string }
  var notice = null; // transient confirmation/error line
  var titleField = '';
  var minutesField = '';

  function persist() {
    jsr.storage.set('reminders', reminders);
  }

  function sortReminders() {
    reminders.sort(function(a, b) { return a.atMs - b.atMs; });
  }

  function fail(msg) {
    loading = false;
    error = {
      kind: msg.indexOf('permission') >= 0 ? 'permission' : 'error',
      message: msg,
    };
  }

  function load() {
    loading = true;
    error = null;
    render();
    jsr.storage.get('reminders').then(function(saved) {
      reminders = Array.isArray(saved) ? saved : [];
      // Reminders whose time already passed fired (or expired) — drop them.
      var now = Date.now();
      reminders = reminders.filter(function(r) { return r && r.atMs > now; });
      sortReminders();
      persist();
      loading = false;
      render();
    });
  }

  function countdownLabel(atMs) {
    var seconds = Math.max(0, Math.round((atMs - Date.now()) / 1000));
    if (seconds < 60) return 'in ' + seconds + 's';
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return 'in ' + minutes + 'm';
    var hours = Math.floor(minutes / 60);
    return 'in ' + hours + 'h ' + (minutes % 60) + 'm';
  }

  function scheduleReminder() {
    var title = (titleField || '').replace(/^\s+|\s+$/g, '');
    var minutes = parseInt(minutesField, 10);
    if (!title) { notice = 'Title is required.'; render(); return; }
    if (isNaN(minutes) || minutes < 1 || minutes > MAX_MINUTES) {
      notice = 'Minutes must be 1–' + MAX_MINUTES + '.';
      render();
      return;
    }
    notice = null;
    render();
    jsr.fa.notify.schedule({
      title: title,
      body: 'Reminder from the Reminders app',
      delaySeconds: minutes * 60,
    }).then(function(result) {
      if (result && result.__error) {
        var msg = String(result.__error);
        if (msg.indexOf('permission') >= 0) { fail(msg); }
        else { notice = msg; }
        render();
        return;
      }
      reminders.push({
        id: result.id,
        title: title,
        atMs: Date.now() + minutes * 60000,
      });
      sortReminders();
      persist();
      titleField = '';
      notice = 'Reminder scheduled.';
      render();
    }, function(e) {
      fail(String(e));
      render();
    });
  }

  function cancelReminder(index) {
    var reminder = reminders[index];
    if (!reminder) return;
    notice = null;
    render();
    jsr.fa.notify.cancel({ id: reminder.id }).then(function(result) {
      if (result && result.__error) {
        notice = String(result.__error);
      } else {
        reminders.splice(index, 1);
        persist();
        notice = 'Reminder cancelled.';
      }
      render();
    }, function(e) {
      notice = String(e);
      render();
    });
  }

  function formCard() {
    return {
      type: 'padding', padding: [16, 16, 16, 16], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: t.border, width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'stretch', children: [
          { type: 'text', data: 'New reminder',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600' } },
          { type: 'sizedBox', height: 10 },
          { type: 'textField', hint: 'Title', value: titleField,
            onChange: 'remind_title' },
          { type: 'sizedBox', height: 8 },
          { type: 'row', crossAxisAlignment: 'center', children: [
            { type: 'expanded', child: {
              type: 'textField', hint: 'In minutes (1-' + MAX_MINUTES + ')',
              value: minutesField, onChange: 'remind_minutes' } },
            { type: 'sizedBox', width: 8 },
            { type: 'button', label: 'Schedule', onPressed: 'remind_add',
              color: t.accent },
          ] },
        ] },
      },
    };
  }

  function reminderRow(reminder, index) {
    return {
      type: 'container',
      margin: [16, 0, 16, 8],
      padding: [12, 12, 12, 12],
      decoration: {
        color: t.surface, borderRadius: 12,
        border: { color: t.border, width: 1 },
      },
      child: { type: 'row', crossAxisAlignment: 'center', children: [
        { type: 'icon', name: 'notifications', color: t.accent, size: 20 },
        { type: 'sizedBox', width: 10 },
        { type: 'expanded', child: {
          type: 'column', crossAxisAlignment: 'start', children: [
            { type: 'text', data: reminder.title,
              style: { color: t.text, fontSize: 14, fontWeight: 'w600' } },
            { type: 'sizedBox', height: 2 },
            { type: 'text', data: countdownLabel(reminder.atMs),
              style: { color: t.muted, fontSize: 11 } },
          ] } },
        { type: 'inkWell', onTap: 'cancel_' + index, borderRadius: 8,
          child: {
            type: 'container',
            width: 32, height: 32, alignment: 'center',
            decoration: {
              color: t.surface, borderRadius: 8,
              border: { color: t.border, width: 1 },
            },
            child: { type: 'icon', name: 'close', color: t.muted, size: 16 },
          } },
      ] },
    };
  }

  function emptyState() {
    return {
      type: 'padding', padding: [16, 40, 16, 24], child: {
        type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'notifications', color: t.muted, size: 40 },
          { type: 'sizedBox', height: 10 },
          { type: 'text', data: 'No reminders',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 4 },
          { type: 'text',
            data: 'Schedule one above — it fires even when Fa is in ' +
              'the background.',
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
        ] },
    };
  }

  function errorCard() {
    var isPerm = error.kind === 'permission';
    return {
      type: 'padding', padding: [16, 16, 16, 16], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: isPerm ? t.accent : '#ef4444', width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: isPerm ? 'lock' : 'warning',
            color: isPerm ? t.accent : '#ef4444', size: 32 },
          { type: 'sizedBox', height: 10 },
          { type: 'text',
            data: isPerm
              ? 'Notifications permission needed'
              : 'Could not schedule the reminder',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 6 },
          { type: 'text',
            data: isPerm
              ? 'Grant the notifications permission: tap the shield icon ' +
                'in this app\'s header and enable "Notifications".'
              : error.message,
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
          { type: 'sizedBox', height: 12 },
          { type: 'button', label: 'Retry', onPressed: 'retry',
            color: t.accent },
        ] },
      },
    };
  }

  function noticeLine() {
    if (!notice) return { type: 'sizedBox', height: 0 };
    return { type: 'padding', padding: [16, 0, 16, 8], child: {
      type: 'text', data: notice,
      style: { color: t.muted, fontSize: 12 } } };
  }

  function body() {
    if (error) return errorCard();
    var children = [formCard(), noticeLine()];
    if (loading) {
      children.push({ type: 'padding', padding: [0, 32, 0, 32], child: {
        type: 'center', child: {
          type: 'circularProgressIndicator', size: 24 } } });
    } else if (!reminders.length) {
      children.push(emptyState());
    } else {
      for (var i = 0; i < reminders.length; i++) {
        children.push(reminderRow(reminders[i], i));
      }
    }
    return { type: 'column', crossAxisAlignment: 'stretch', children: children };
  }

  function render() {
    jsr.render({
      type: 'column', crossAxisAlignment: 'stretch', children: [
        { type: 'padding', padding: [16, 12, 16, 12], child: {
          type: 'row', crossAxisAlignment: 'center', children: [
            { type: 'icon', name: 'notifications', color: t.accent, size: 22 },
            { type: 'sizedBox', width: 10 },
            { type: 'expanded', child: {
              type: 'column', crossAxisAlignment: 'start', children: [
                { type: 'text', data: 'Reminders',
                  style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
                { type: 'text',
                  data: loading ? 'Loading…'
                    : reminders.length +
                      (reminders.length === 1 ? ' scheduled' : ' scheduled'),
                  style: { color: t.muted, fontSize: 11 } },
              ] } },
          ] } },
        { type: 'divider', color: t.border, height: 1 },
        body(),
      ],
    });
    jsr.exportState({
      loading: loading,
      reminderCount: reminders.length,
      reminders: reminders.map(function(r) {
        return { id: r.id, title: r.title, atMs: r.atMs };
      }),
      error: error ? error.message : null,
      notice: notice,
      form: { title: titleField, minutes: minutesField },
    });
  }

  function handleEvent(actionId, payload) {
    if (actionId === 'remind_title') {
      titleField = payload && payload.value;
    } else if (actionId === 'remind_minutes') {
      minutesField = payload && payload.value;
    } else if (actionId === 'remind_add') {
      scheduleReminder();
    } else if (actionId === 'retry') {
      load();
    } else if (actionId.indexOf('cancel_') === 0) {
      cancelReminder(parseInt(actionId.slice(7), 10));
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Reminders');
  load();
})();
