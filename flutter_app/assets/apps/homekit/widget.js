// Home widget — controls real HomeKit accessories through jsr.fa.home
// (iOS). When the bridge is unavailable (other platforms, permission off,
// access denied) the app says so honestly and shows a clearly-labeled demo
// device panel whose toggles work locally and persist via jsr.storage.
(function() {
  var t = jsr.theme;
  var loading = true;
  var bridgeError = null;
  var accessories = null; // real accessories from the bridge
  var notice = null;

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

  var devices = null; // demo panel state (fallback mode only)

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
    jsr.fa.home.list().then(function(result) {
      loading = false;
      if (result && result.__error) {
        bridgeError = String(result.__error);
        accessories = null;
      } else {
        bridgeError = null;
        accessories = (result && result.accessories) || [];
      }
      render();
    }, function(e) {
      loading = false;
      bridgeError = String(e);
      accessories = null;
      render();
    });
  }

  function findAccessory(id) {
    for (var i = 0; i < (accessories || []).length; i++) {
      if (accessories[i].id === id) return accessories[i];
    }
    return null;
  }

  // Runs a bridge write; on success applies patch() to the local accessory
  // copy, on failure shows the bridge error as a notice.
  function write(call, patch) {
    notice = null;
    call.then(function(result) {
      if (result && result.__error) {
        notice = String(result.__error);
      } else if (patch) {
        patch();
      }
      render();
    }, function(e) {
      notice = String(e);
      render();
    });
  }

  function bridgeCard(connected) {
    var children = [
      { type: 'icon',
        name: loading ? 'refresh' : connected ? 'check_circle' : 'info',
        color: loading ? t.muted : connected ? '#22c55e' : '#f59e0b',
        size: 26 },
      { type: 'sizedBox', width: 10 },
      { type: 'expanded', child: {
        type: 'column', crossAxisAlignment: 'start', children: [
          { type: 'text',
            data: loading ? 'Checking the HomeKit bridge…'
              : connected ? 'HomeKit connected'
              : 'HomeKit bridge not available',
            style: { color: t.text, fontSize: 13, fontWeight: 'w600' } },
          bridgeError
            ? { type: 'padding', padding: [0, 2, 0, 0], child: {
                type: 'text', data: bridgeError,
                style: { color: t.muted, fontSize: 10 } } }
            : { type: 'sizedBox', height: 0 },
        ] } },
    ];
    if (!loading) {
      children.push({
        type: 'textButton', text: connected ? 'Refresh' : 'Retry',
        onTap: 'retry' });
    }
    return {
      type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'container',
        padding: [12, 12, 12, 12],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: {
            color: loading ? t.border : connected ? '#22c55e' : '#f59e0b',
            width: 1 },
        },
        child: { type: 'row', crossAxisAlignment: 'center',
          children: children },
      },
    };
  }

  function noticeCard() {
    if (!notice) return null;
    return {
      type: 'padding', padding: [16, 4, 16, 4], child: {
        type: 'container',
        padding: [10, 8, 10, 8],
        decoration: { color: '#f43f5e11', borderRadius: 10,
          border: { color: '#f43f5e', width: 1 } },
        child: { type: 'text', data: notice,
          style: { color: '#f43f5e', fontSize: 11 } },
      },
    };
  }

  // --- real accessories ----------------------------------------------------

  function accessoryIcon(a) {
    if (a.category === 'lightbulb') {
      return { name: 'wb_sunny', color: a.isOn ? '#fbbf24' : t.muted };
    }
    if (a.category === 'thermostat') return { name: 'thermostat', color: '#0ea5e9' };
    if (a.category === 'lock') {
      return { name: 'lock', color: a.isOn ? '#22c55e' : '#f43f5e' };
    }
    // switch / outlet / anything else
    return { name: 'power_settings_new', color: a.isOn ? '#22c55e' : t.muted };
  }

  function accessoryStatus(a) {
    var parts = [];
    if (!a.reachable) parts.push('Unreachable');
    if (a.isOn === true) parts.push('On');
    if (a.isOn === false) parts.push('Off');
    if (typeof a.brightness === 'number') parts.push(a.brightness + '%');
    if (typeof a.targetTemperature === 'number') {
      parts.push(a.targetTemperature.toFixed(1) + '°C');
    }
    return parts.length ? parts.join(' · ') : a.category;
  }

  function stepButton(label, action, enabled) {
    return {
      type: 'inkWell', onTap: enabled ? action : null, borderRadius: 8,
      child: { type: 'container',
        width: 28, height: 28, alignment: 'center',
        decoration: { color: t.bg, borderRadius: 8,
          border: { color: t.border, width: 1 } },
        child: { type: 'text', data: label,
          style: { color: enabled ? t.text : t.muted, fontSize: 14,
            fontWeight: 'w700' } } },
    };
  }

  function accessoryCard(a) {
    var icon = accessoryIcon(a);
    var enabled = !!a.reachable;
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
            { type: 'text', data: a.name,
              style: { color: t.text, fontSize: 13, fontWeight: 'w600' },
              maxLines: 1, overflow: 'ellipsis' },
            { type: 'text', data: accessoryStatus(a),
              style: { color: a.reachable ? t.muted : '#f43f5e',
                fontSize: 10 } },
          ] } },
      ] },
    ];
    var controls = [];
    if (a.isOn !== null && a.isOn !== undefined) {
      controls.push({
        type: 'inkWell', onTap: enabled ? 'power_' + a.id : null,
        borderRadius: 8,
        child: { type: 'container',
          padding: [10, 5, 10, 5],
          decoration: { color: t.bg, borderRadius: 8,
            border: { color: t.border, width: 1 } },
          child: { type: 'text', data: a.isOn ? 'Turn off' : 'Turn on',
            style: { color: enabled ? t.accent : t.muted, fontSize: 11,
              fontWeight: 'w600' } } } });
    }
    if (typeof a.brightness === 'number') {
      if (controls.length) controls.push({ type: 'sizedBox', width: 6 });
      controls.push(stepButton('−', 'brightdown_' + a.id, enabled));
      controls.push({ type: 'sizedBox', width: 6 });
      controls.push(stepButton('+', 'brightup_' + a.id, enabled));
    }
    if (typeof a.targetTemperature === 'number') {
      if (controls.length) controls.push({ type: 'sizedBox', width: 6 });
      controls.push(stepButton('−', 'tempdown_' + a.id, enabled));
      controls.push({ type: 'sizedBox', width: 6 });
      controls.push(stepButton('+', 'tempup_' + a.id, enabled));
    }
    if (controls.length) {
      children.push({ type: 'sizedBox', height: 8 });
      children.push({ type: 'row', mainAxisAlignment: 'end',
        crossAxisAlignment: 'center', children: controls });
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

  function roomSection(homeName, room, items, live) {
    var rows = [
      { type: 'padding', padding: [16, 10, 16, 6], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'expanded', child: {
            type: 'text',
            data: room + (homeName ? ' · ' + homeName : ''),
            style: { color: t.text, fontSize: 13, fontWeight: 'w700' } } },
          live ? { type: 'container',
            padding: [6, 3, 6, 3],
            decoration: { color: '#22c55e22', borderRadius: 6,
              border: { color: '#22c55e', width: 1 } },
            child: { type: 'text', data: 'LIVE',
              style: { color: '#22c55e', fontSize: 9, fontWeight: 'w700',
                letterSpacing: 1 } } }
          : { type: 'sizedBox', height: 0 },
        ] } },
    ];
    for (var i = 0; i < items.length; i += 2) {
      var rowChildren = [
        { type: 'expanded', child: accessoryCard(items[i]) },
        { type: 'sizedBox', width: 8 },
      ];
      rowChildren.push(items[i + 1]
        ? { type: 'expanded', child: accessoryCard(items[i + 1]) }
        : { type: 'expanded', child: { type: 'sizedBox', height: 1 } });
      rows.push({
        type: 'padding', padding: [16, 4, 16, 4], child: {
          type: 'row', crossAxisAlignment: 'start', children: rowChildren },
      });
    }
    return rows;
  }

  // Groups accessories by home → room, preserving the bridge order.
  function realSections() {
    var order = [];
    var byKey = {};
    for (var i = 0; i < accessories.length; i++) {
      var a = accessories[i];
      var key = (a.homeName || '') + '' + (a.room || '');
      if (!byKey[key]) {
        byKey[key] = { homeName: a.homeName, room: a.room, items: [] };
        order.push(key);
      }
      byKey[key].items.push(a);
    }
    var out = [];
    for (var j = 0; j < order.length; j++) {
      var section = byKey[order[j]];
      out = out.concat(
        roomSection(section.homeName, section.room || 'Room', section.items,
          j === 0));
    }
    return out;
  }

  // --- demo panel (fallback) -------------------------------------------------

  function deviceIcon(d) {
    if (d.type === 'light') {
      return { name: 'wb_sunny', color: d.on ? '#fbbf24' : t.muted };
    }
    if (d.type === 'thermostat') return { name: 'thermostat', color: '#0ea5e9' };
    return { name: 'lock', color: d.locked ? '#22c55e' : '#f43f5e' };
  }

  function demoStatusText(d) {
    if (d.type === 'light') return d.on ? 'On' : 'Off';
    if (d.type === 'thermostat') return d.temp.toFixed(1) + '°C';
    return d.locked ? 'Locked' : 'Unlocked';
  }

  function demoStatusColor(d) {
    if (d.type === 'light') return d.on ? '#fbbf24' : t.muted;
    if (d.type === 'thermostat') return '#0ea5e9';
    return d.locked ? '#22c55e' : '#f43f5e';
  }

  function demoDeviceCard(d) {
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
          { type: 'text', data: demoStatusText(d),
            style: { color: demoStatusColor(d), fontSize: 16,
              fontWeight: 'w700' } },
          { type: 'row', mainAxisSize: 'min', children: [
            stepButton('−', 'temp_down', true),
            { type: 'sizedBox', width: 6 },
            stepButton('+', 'temp_up', true),
          ] },
        ] });
    } else {
      children.push({
        type: 'row', mainAxisAlignment: 'spaceBetween',
        crossAxisAlignment: 'center', children: [
          { type: 'text', data: demoStatusText(d),
            style: { color: demoStatusColor(d), fontSize: 14,
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

  function demoGrid() {
    var rows = [];
    for (var i = 0; i < devices.length; i += 2) {
      rows.push({
        type: 'padding', padding: [16, 4, 16, 4], child: {
          type: 'row', crossAxisAlignment: 'start', children: [
            { type: 'expanded', child: demoDeviceCard(devices[i]) },
            { type: 'sizedBox', width: 8 },
            { type: 'expanded', child: demoDeviceCard(devices[i + 1]) },
          ] },
      });
    }
    return rows;
  }

  // --- render + events ---------------------------------------------------------

  function render() {
    if (!devices) return;
    var real = !loading && !bridgeError && !!accessories;
    var children = [
      { type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'home', color: '#f59e0b', size: 20 },
          { type: 'sizedBox', width: 8 },
          { type: 'text', data: 'Home',
            style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
        ] } },
      bridgeCard(real),
    ];
    var note = noticeCard();
    if (note) children.push(note);
    if (real) {
      if (accessories.length) {
        children = children.concat(realSections());
      } else {
        children.push({
          type: 'padding', padding: [16, 10, 16, 6], child: {
            type: 'container',
            padding: [16, 14, 16, 14],
            decoration: { color: t.surface, borderRadius: 12,
              border: { color: t.border, width: 1 } },
            child: { type: 'text',
              data: 'No accessories found in your home.',
              style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
          },
        });
      }
    } else if (!loading) {
      // Honest fallback: the bridge is unavailable, so show the demo panel
      // with clearly-labeled local-only devices.
      children.push(demoBanner());
      children = children.concat(demoGrid());
      children.push({
        type: 'padding', padding: [16, 8, 16, 16], child: {
          type: 'text',
          data: 'Demo devices — toggles are stored locally in this app only. ' +
            'On iOS with home access granted, your real HomeKit accessories ' +
            'appear here instead.',
          style: { color: t.muted, fontSize: 10, textAlign: 'center' } },
      });
    }
    jsr.render({ type: 'column', crossAxisAlignment: 'stretch',
      children: children });
    jsr.exportState({
      loading: loading,
      bridgeAvailable: real,
      bridgeError: bridgeError,
      demoData: !loading && !real,
      notice: notice,
      accessoryCount: real ? accessories.length : 0,
      accessories: real ? accessories.map(function(a) {
        return { id: a.id, name: a.name, room: a.room,
          category: a.category, status: accessoryStatus(a) };
      }) : null,
      devices: !real && devices ? devices.map(function(d) {
        return { id: d.id, type: d.type, status: demoStatusText(d) };
      }) : null,
    });
  }

  function handleRealEvent(actionId) {
    var id = actionId.slice(actionId.indexOf('_') + 1);
    var a = findAccessory(id);
    if (!a || !a.reachable) return;
    if (actionId.indexOf('power_') === 0) {
      write(jsr.fa.home.setPower({ id: id, on: !a.isOn }), function() {
        a.isOn = !a.isOn;
      });
      return;
    }
    if (actionId.indexOf('brightup_') === 0 || actionId.indexOf('brightdown_') === 0) {
      var delta = actionId.indexOf('brightup_') === 0 ? 10 : -10;
      var value = Math.min(100, Math.max(0, (a.brightness || 0) + delta));
      write(jsr.fa.home.setBrightness({ id: id, value: value }), function() {
        a.brightness = value;
      });
      return;
    }
    if (actionId.indexOf('tempup_') === 0 || actionId.indexOf('tempdown_') === 0) {
      var step = actionId.indexOf('tempup_') === 0 ? 0.5 : -0.5;
      var celsius = Math.round(((a.targetTemperature || 20) + step) * 10) / 10;
      write(jsr.fa.home.setTemperature({ id: id, celsius: celsius }), function() {
        a.targetTemperature = celsius;
      });
    }
  }

  function handleDemoEvent(actionId) {
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

  jsr.onEvent(function(actionId) {
    if (actionId === 'retry') {
      checkBridge();
      return;
    }
    if (!loading && !bridgeError && accessories) {
      handleRealEvent(actionId);
    } else {
      handleDemoEvent(actionId);
    }
  });
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Home');

  jsr.storage.get('devices').then(function(saved) {
    devices = (saved && saved.length) ? saved : clone(DEFAULT_DEVICES);
    render();
    checkBridge();
  });
})();
