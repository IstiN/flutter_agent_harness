// Calendar widget — system calendar events via the jsr.fa.calendar bridge
// Day view with prev/next navigation, add/edit/delete forms,
// permission-aware error states.
(function() {
  var MONTHS = [
    'January','February','March','April','May','June','July',
    'August','September','October','November','December',
  ];
  var WEEKDAYS = [
    'Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday',
  ];

  var t = jsr.theme;
  var selected = startOfDay(new Date());
  var loading = true;
  var events = [];
  var error = null; // { kind: 'permission'|'error', message: string }
  // null, or { mode: 'add'|'edit', id, title, startHour, endHour } —
  // hour fields stay raw text until save.
  var form = null;
  var notice = null; // transient confirmation/error line

  function startOfDay(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate());
  }

  function iso(d) {
    var m = ('0' + (d.getMonth() + 1)).slice(-2);
    var day = ('0' + d.getDate()).slice(-2);
    return d.getFullYear() + '-' + m + '-' + day;
  }

  function fmtTime(ms) {
    var d = new Date(ms);
    var h = ('0' + d.getHours()).slice(-2);
    var m = ('0' + d.getMinutes()).slice(-2);
    return h + ':' + m;
  }

  function dayLabel(d) {
    var today = startOfDay(new Date());
    var diffDays = Math.round((d - today) / 86400000);
    var base = WEEKDAYS[d.getDay()] + ', ' +
      MONTHS[d.getMonth()].slice(0, 3) + ' ' + d.getDate();
    if (diffDays === 0) return 'Today — ' + base;
    if (diffDays === 1) return 'Tomorrow — ' + base;
    if (diffDays === -1) return 'Yesterday — ' + base;
    return base;
  }

  function fail(msg) {
    loading = false;
    events = [];
    error = {
      kind: msg.indexOf('permission') >= 0 ? 'permission' : 'error',
      message: msg,
    };
  }

  function load() {
    loading = true;
    error = null;
    render();
    jsr.fa.calendar({ date: iso(selected), days: 1 }).then(function(result) {
      if (result && result.__error) {
        fail(String(result.__error));
      } else {
        loading = false;
        events = (result && result.events) || [];
        events.sort(function(a, b) { return a.startMs - b.startMs; });
      }
      render();
    }, function(e) {
      fail(String(e));
      render();
    });
  }

  function navButton(icon, action) {
    return {
      type: 'inkWell', onTap: action, borderRadius: 8,
      child: {
        type: 'container',
        width: 36, height: 36, alignment: 'center',
        decoration: {
          color: t.surface, borderRadius: 8,
          border: { color: t.border, width: 1 },
        },
        child: { type: 'icon', name: icon, color: t.text, size: 18 },
      },
    };
  }

  function eventRow(ev, index) {
    var time = ev.allDay
      ? 'All day'
      : fmtTime(ev.startMs) + ' – ' + fmtTime(ev.endMs);
    var meta = [];
    if (ev.calendar) meta.push(ev.calendar);
    if (ev.location) meta.push(ev.location);
    return {
      type: 'inkWell', onTap: 'event_' + index, borderRadius: 12,
      child: {
        type: 'container',
        margin: [16, 0, 16, 8],
        padding: [12, 12, 12, 12],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: t.border, width: 1 },
        },
        child: { type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'container',
            width: 4, height: 40,
            margin: [0, 0, 10, 0],
            decoration: { color: t.accent, borderRadius: 2 },
          },
          { type: 'expanded', child: {
            type: 'column', crossAxisAlignment: 'start', children: [
              { type: 'text', data: time,
                style: { color: t.accent, fontSize: 12, fontWeight: 'w600' } },
              { type: 'sizedBox', height: 2 },
              { type: 'text', data: ev.title || '(no title)',
                style: { color: t.text, fontSize: 14, fontWeight: 'w600' } },
              meta.length
                ? { type: 'padding', padding: [0, 2, 0, 0], child: {
                    type: 'text', data: meta.join('  ·  '),
                    style: { color: t.muted, fontSize: 11 } } }
                : { type: 'sizedBox', height: 0 },
            ] } },
          { type: 'icon', name: 'edit', color: t.muted, size: 16 },
        ] },
      },
    };
  }

  function formField(hint, value, onChange) {
    return {
      type: 'textField', hint: hint, value: value, onChange: onChange,
    };
  }

  function formCard() {
    var isEdit = form.mode === 'edit';
    return {
      type: 'padding', padding: [16, 16, 16, 16], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: t.accent, width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'stretch', children: [
          { type: 'text', data: isEdit ? 'Edit event' : 'New event',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600' } },
          { type: 'sizedBox', height: 10 },
          formField('Title', form.title, 'form_title'),
          { type: 'sizedBox', height: 8 },
          { type: 'row', children: [
            { type: 'expanded', child:
              formField('Start hour (0-23)', form.startHour, 'form_start') },
            { type: 'sizedBox', width: 8 },
            { type: 'expanded', child:
              formField('End hour', form.endHour, 'form_end') },
          ] },
          { type: 'sizedBox', height: 12 },
          { type: 'row', mainAxisAlignment: 'end', children: [
            isEdit
              ? { type: 'textButton', text: 'Delete', onTap: 'form_delete' }
              : { type: 'sizedBox', width: 0 },
            { type: 'textButton', text: 'Cancel', onTap: 'form_cancel' },
            { type: 'sizedBox', width: 8 },
            { type: 'button', label: isEdit ? 'Save' : 'Add',
              onPressed: 'form_save', color: t.accent },
          ] },
        ] },
      },
    };
  }

  function emptyState() {
    return {
      type: 'padding', padding: [16, 40, 16, 24], child: {
        type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'calendar_today', color: t.muted, size: 40 },
          { type: 'sizedBox', height: 10 },
          { type: 'text', data: 'No events',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 4 },
          { type: 'text', data: 'Nothing scheduled for this day.',
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
            data: isPerm ? 'Calendar permission needed' : 'Could not load events',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 6 },
          { type: 'text',
            data: isPerm
              ? 'Grant the calendar permission: tap the shield icon in ' +
                'this app\'s header and enable "Calendar".'
              : error.message,
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
          { type: 'sizedBox', height: 12 },
          { type: 'button', label: 'Retry', onPressed: 'retry',
            color: t.accent },
        ] },
      },
    };
  }

  function body() {
    if (form) return formCard();
    if (loading) {
      return { type: 'padding', padding: [0, 48, 0, 48], child: {
        type: 'center', child: {
          type: 'circularProgressIndicator', size: 24 } } };
    }
    if (error) return errorCard();
    if (!events.length) return emptyState();
    return {
      type: 'column', crossAxisAlignment: 'stretch',
      children: events.map(eventRow),
    };
  }

  function noticeLine() {
    if (!notice) return { type: 'sizedBox', height: 0 };
    return { type: 'padding', padding: [16, 0, 16, 8], child: {
      type: 'text', data: notice,
      style: { color: t.muted, fontSize: 12 } } };
  }

  function render() {
    jsr.render({
      type: 'column', crossAxisAlignment: 'stretch', children: [
        // Date navigation header
        { type: 'padding', padding: [16, 12, 16, 12], child: {
          type: 'row', crossAxisAlignment: 'center', children: [
            navButton('arrow_back', 'prev_day'),
            { type: 'sizedBox', width: 10 },
            { type: 'expanded', child: {
              type: 'column', crossAxisAlignment: 'center', children: [
                { type: 'text', data: dayLabel(selected),
                  style: { color: t.text, fontSize: 16, fontWeight: 'w700',
                    textAlign: 'center' } },
                { type: 'text',
                  data: loading ? 'Loading…'
                    : error ? 'Unavailable'
                    : events.length + (events.length === 1 ? ' event' : ' events'),
                  style: { color: t.muted, fontSize: 11, textAlign: 'center' } },
              ] } },
            { type: 'sizedBox', width: 10 },
            navButton('arrow_forward', 'next_day'),
            { type: 'sizedBox', width: 10 },
            navButton('add', 'add_open'),
          ] } },
        { type: 'padding', padding: [16, 0, 16, 8], child: {
          type: 'row', mainAxisAlignment: 'end', children: [
            { type: 'textButton', text: 'Today', onTap: 'today' },
          ] } },
        { type: 'divider', color: t.border, height: 1 },
        noticeLine(),
        body(),
      ],
    });
    jsr.exportState({
      date: iso(selected),
      loading: loading,
      eventCount: events.length,
      events: events.map(function(ev) { return ev.title; }),
      error: error ? error.message : null,
      form: form ? form.mode : null,
      notice: notice,
    });
  }

  function openAdd() {
    form = { mode: 'add', id: null, title: '', startHour: '', endHour: '' };
    notice = null;
    render();
  }

  function openEdit(index) {
    var ev = events[index];
    if (!ev) return;
    var start = new Date(ev.startMs);
    var end = new Date(ev.endMs);
    form = {
      mode: 'edit',
      id: ev.id,
      title: ev.title || '',
      startHour: ev.allDay ? '' : String(start.getHours()),
      endHour: ev.allDay ? '' : String(end.getHours()),
    };
    notice = null;
    render();
  }

  function saveForm() {
    var title = (form.title || '').replace(/^\s+|\s+$/g, '');
    var startHour = parseInt(form.startHour, 10);
    var endHour = form.endHour === ''
      ? startHour + 1
      : parseInt(form.endHour, 10);
    if (!title) { notice = 'Title is required.'; render(); return; }
    if (isNaN(startHour) || startHour < 0 || startHour > 23 ||
        isNaN(endHour) || endHour <= startHour || endHour > 24) {
      notice = 'Hours must be 0-23, end after start.';
      render();
      return;
    }
    var args = {
      title: title,
      date: iso(selected),
      startHour: startHour,
      endHour: endHour,
    };
    var call = form.mode === 'edit'
      ? jsr.fa.calendar.update(argsWithId(args))
      : jsr.fa.calendar.create(args);
    call.then(function(result) {
      if (result && result.__error) {
        notice = String(result.__error);
        render();
      } else {
        notice = form.mode === 'edit' ? 'Event updated.' : 'Event added.';
        form = null;
        load();
      }
    }, function(e) {
      notice = String(e);
      render();
    });
  }

  function argsWithId(args) {
    args.id = form.id;
    return args;
  }

  function deleteFormEvent() {
    var id = form.id;
    jsr.fa.calendar.delete({ id: id }).then(function(result) {
      if (result && result.__error) {
        notice = String(result.__error);
        render();
      } else {
        notice = 'Event deleted.';
        form = null;
        load();
      }
    }, function(e) {
      notice = String(e);
      render();
    });
  }

  function handleEvent(actionId, payload) {
    if (actionId === 'prev_day') {
      selected = new Date(selected.getTime() - 86400000);
      form = null;
      load();
    } else if (actionId === 'next_day') {
      selected = new Date(selected.getTime() + 86400000);
      form = null;
      load();
    } else if (actionId === 'today') {
      selected = startOfDay(new Date());
      form = null;
      load();
    } else if (actionId === 'retry') {
      load();
    } else if (actionId === 'add_open') {
      openAdd();
    } else if (actionId.indexOf('event_') === 0) {
      openEdit(parseInt(actionId.slice(6), 10));
    } else if (actionId === 'form_title') {
      if (form) form.title = payload && payload.value;
    } else if (actionId === 'form_start') {
      if (form) form.startHour = payload && payload.value;
    } else if (actionId === 'form_end') {
      if (form) form.endHour = payload && payload.value;
    } else if (actionId === 'form_save') {
      if (form) saveForm();
    } else if (actionId === 'form_delete') {
      if (form && form.mode === 'edit') deleteFormEvent();
    } else if (actionId === 'form_cancel') {
      form = null;
      render();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Calendar');
  load();
})();
