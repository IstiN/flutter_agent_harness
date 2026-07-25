// Calendar widget — system calendar events via the jsr.fa.calendar bridge
// Day view with prev/next navigation, permission-aware error states.
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

  function eventRow(ev) {
    var time = ev.allDay
      ? 'All day'
      : fmtTime(ev.startMs) + ' – ' + fmtTime(ev.endMs);
    var meta = [];
    if (ev.calendar) meta.push(ev.calendar);
    if (ev.location) meta.push(ev.location);
    return {
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
      ] },
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
          ] } },
        { type: 'padding', padding: [16, 0, 16, 8], child: {
          type: 'row', mainAxisAlignment: 'end', children: [
            { type: 'textButton', text: 'Today', onTap: 'today' },
          ] } },
        { type: 'divider', color: t.border, height: 1 },
        body(),
      ],
    });
    jsr.exportState({
      date: iso(selected),
      loading: loading,
      eventCount: events.length,
      events: events.map(function(ev) { return ev.title; }),
      error: error ? error.message : null,
    });
  }

  function handleEvent(actionId) {
    if (actionId === 'prev_day') {
      selected = new Date(selected.getTime() - 86400000);
      load();
    } else if (actionId === 'next_day') {
      selected = new Date(selected.getTime() + 86400000);
      load();
    } else if (actionId === 'today') {
      selected = startOfDay(new Date());
      load();
    } else if (actionId === 'retry') {
      load();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Calendar');
  load();
})();
