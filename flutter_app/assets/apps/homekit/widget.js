// Home widget — demonstrates the jsr.fa.homekit bridge UX honestly.
// The bridge is a stub on the host today ("not available yet"); the app
// shows that status in a designed card, plus a demo device panel whose
// toggles work locally and persist via jsr.storage.
(function() {
  var t = jsr.theme;
  var loading = true;
  var bridgeError = null;

  // Demo devices — local-only state, never real accessories.
  var DEFAULT_DEVICES = [
    { id: 'living-light', name: 'Ceiling Light', room: 'Living Room',
      type: 'light', on: true },
    { id: 'bedroom-lamp', name: 'Bedside Lamp', room: 'Bedroom',
      type: 'light', on: false },
    { id: 'thermostat', name: 'Thermostat', room: 'Hallway',
      type: 'thermostat', temp: 21.5 },
    { id: 'front-lock', name: 'Front Door', room: 'Entry',
      type: 'lock', locked: true },
  ];

  var devices = null;

  function clone(list) {
    return list.map(function(d) {
      var copy = {};
      for (var k in d) copy[k] = d[k];
      return copy;
    });
  }

  function save() {
    jsr.storage.set('devices', devices);
  }

  function checkBridge() {
    loading = true;
    render();
    jsr.fa.homekit('listDevices', {}).then(function(result) {
      loading = false;
      bridgeError = result && result.__error ? String(result.__error) : null;
      render();
    }, function(e) {
      loading = false;
      bridgeError = String(e);
      render();
    });
  }

  function bridgeCard() {
    var children = [
      { type: 'icon', name: loading ? 'refresh' : 'info',
        color: loading ? t.muted : '#f59e0b', size: 26 },
      { type: 'sizedBox', width: 10 },
      { type: 'expanded', child: {
        type: 'column', crossAxisAlignment: 'start', children: [
          { type: 'text',
            data: loading ? 'Checking the HomeKit bridge…'
              : bridgeError ? 'HomeKit bridge not available yet'
              : 'HomeKit bridge connected',
            style: { color: t.text, fontSize: 13, fontWeight: 'w600' } },
          bridgeError
            ? { type: 'padding', padding: [0, 2, 0, 0], child: {
                type: 'text', data: bridgeError,
                style: { color: t.muted, fontSize: 10 } } }
            : { type: 'sizedBox', height: 0 },
        ] } },
    ];
    if (!loading && bridgeError) {
      children.push({ type: 'textButton', text: 'Retry', onTap: 'retry' });
    }
    return {
      type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'container',
        padding: [12, 12, 12, 12],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: loading ? t.border : '#f59e0b', width: 1 },
        },
        child: { type: 'row', crossAxisAlignment: 'center',
          children: children },
      },
    };
  }

  function deviceIcon(d) {
    if (d.type === 'light') {
      return { name: 'wb_sunny', color: d.on ? '#fbbf24' : t.muted };
    }
    if (d.type === 'thermostat') return { name: 'thermostat', color: '#0ea5e9' };
    return { name: 'lock', color: d.locked ? '#22c55e' : '#f43f5e' };
  }

  function statusText(d) {
    if (d.type === 'light') return d.on ? 'On' : 'Off';
    if (d.type === 'thermostat') return d.temp.toFixed(1) + '°C';
    return d.locked ? 'Locked' : 'Unlocked';
  }

  function statusColor(d) {
    if (d.type === 'light') return d.on ? '#fbbf24' : t.muted;
    if (d.type === 'thermostat') return '#0ea5e9';
    return d.locked ? '#22c55e' : '#f43f5e';
  }

  function deviceCard(d) {
    var icon = deviceIcon(d);
    var children = [
      { type: 'row', crossAxisAlignment: 'center', children: [
        { type: 'container',
          width: 34, height: 34, alignment: 'center',
          decoration: { color: t.bg, borderRadius: 17 },
          child: { type: 'icon', name: icon.name, color: icon.color,
            size: 18 } },
        { type: 'sizedBox', width: 8 },
        { type: 'expanded', child: {
          type: 'column', crossAxisAlignment: 'start', children: [
            { type: 'text', data: d.name,
              style: { color: t.text, fontSize: 13, fontWeight: 'w600' },
              maxLines: 1, overflow: 'ellipsis' },
            { type: 'text', data: d.room,
              style: { color: t.muted, fontSize: 10 } },
          ] } },
      ] },
      { type: 'sizedBox', height: 8 },
    ];
    if (d.type === 'thermostat') {
      children.push({
        type: 'row', mainAxisAlignment: 'spaceBetween',
        crossAxisAlignment: 'center', children: [
          { type: 'text', data: statusText(d),
            style: { color: statusColor(d), fontSize: 16,
              fontWeight: 'w700' } },
          { type: 'row', mainAxisSize: 'min', children: [
            tempButton('−', 'temp_down'),
            { type: 'sizedBox', width: 6 },
            tempButton('+', 'temp_up'),
          ] },
        ] });
    } else {
      children.push({
        type: 'row', mainAxisAlignment: 'spaceBetween',
        crossAxisAlignment: 'center', children: [
          { type: 'text', data: statusText(d),
            style: { color: statusColor(d), fontSize: 14,
              fontWeight: 'w700' } },
          { type: 'inkWell', onTap: 'toggle_' + d.id, borderRadius: 8,
            child: { type: 'container',
              padding: [10, 5, 10, 5],
              decoration: { color: t.bg, borderRadius: 8,
                border: { color: t.border, width: 1 } },
              child: { type: 'text',
                data: d.type === 'lock'
                  ? (d.locked ? 'Unlock' : 'Lock')
                  : (d.on ? 'Turn off' : 'Turn on'),
                style: { color: t.accent, fontSize: 11,
                  fontWeight: 'w600' } } } },
        ] });
    }
    return {
      type: 'container',
      padding: [12, 12, 12, 12],
      decoration: {
        color: t.surface, borderRadius: 12,
        border: { color: t.border, width: 1 },
      },
      child: { type: 'column', crossAxisAlignment: 'stretch',
        children: children },
    };
  }

  function tempButton(label, action) {
    return {
      type: 'inkWell', onTap: action, borderRadius: 8, child: {
        type: 'container',
        width: 28, height: 28, alignment: 'center',
        decoration: { color: t.bg, borderRadius: 8,
          border: { color: t.border, width: 1 } },
        child: { type: 'text', data: label,
          style: { color: t.text, fontSize: 14, fontWeight: 'w700' } } },
    };
  }

  function demoBanner() {
    return {
      type: 'padding', padding: [16, 10, 16, 6], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'expanded', child: {
            type: 'text', data: 'My devices',
            style: { color: t.text, fontSize: 13, fontWeight: 'w700' } } },
          { type: 'container',
            padding: [6, 3, 6, 3],
            decoration: { color: '#f59e0b22', borderRadius: 6,
              border: { color: '#f59e0b', width: 1 } },
            child: { type: 'text', data: 'DEMO — LOCAL STATE ONLY',
              style: { color: '#f59e0b', fontSize: 9, fontWeight: 'w700',
                letterSpacing: 1 } } },
        ] },
    };
  }

  function grid() {
    var rows = [];
    for (var i = 0; i < devices.length; i += 2) {
      rows.push({
        type: 'padding', padding: [16, 4, 16, 4], child: {
          type: 'row', crossAxisAlignment: 'start', children: [
            { type: 'expanded', child: deviceCard(devices[i]) },
            { type: 'sizedBox', width: 8 },
            { type: 'expanded', child: deviceCard(devices[i + 1]) },
          ] },
      });
    }
    return rows;
  }

  function render() {
    if (!devices) return;
    var children = [
      { type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'home', color: '#f59e0b', size: 20 },
          { type: 'sizedBox', width: 8 },
          { type: 'text', data: 'Home',
            style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
        ] } },
      bridgeCard(),
      demoBanner(),
    ];
    children = children.concat(grid());
    children.push({
      type: 'padding', padding: [16, 8, 16, 16], child: {
        type: 'text',
        data: 'Demo devices — toggles are stored locally in this app only. ' +
          'Once the host implements the HomeKit bridge, real accessories ' +
          'will appear here.',
        style: { color: t.muted, fontSize: 10, textAlign: 'center' } },
    });
    jsr.render({ type: 'column', crossAxisAlignment: 'stretch',
      children: children });
    jsr.exportState({
      loading: loading,
      bridgeAvailable: !loading && !bridgeError,
      bridgeError: bridgeError,
      demoData: true,
      devices: devices.map(function(d) {
        return { id: d.id, type: d.type, status: statusText(d) };
      }),
    });
  }

  function handleEvent(actionId) {
    if (actionId === 'retry') {
      checkBridge();
      return;
    }
    if (actionId === 'temp_up' || actionId === 'temp_down') {
      for (var i = 0; i < devices.length; i++) {
        if (devices[i].type === 'thermostat') {
          devices[i].temp += actionId === 'temp_up' ? 0.5 : -0.5;
          if (devices[i].temp < 10) devices[i].temp = 10;
          if (devices[i].temp > 30) devices[i].temp = 30;
        }
      }
      save();
      render();
      return;
    }
    if (actionId.indexOf('toggle_') === 0) {
      var id = actionId.slice(7);
      for (var j = 0; j < devices.length; j++) {
        var d = devices[j];
        if (d.id !== id) continue;
        if (d.type === 'light') d.on = !d.on;
        if (d.type === 'lock') d.locked = !d.locked;
      }
      save();
      render();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Home');

  jsr.storage.get('devices').then(function(saved) {
    devices = (saved && saved.length) ? saved : clone(DEFAULT_DEVICES);
    render();
    checkBridge();
  });
})();
