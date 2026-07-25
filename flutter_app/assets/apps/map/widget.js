// Map widget — OpenStreetMap via the `map` node (js_widget_runtime).
// Preset landmarks of Grodno, Belarus; tap the map to drop your own pins.
//
// Note: the `map` node applies `center`/`zoom` only when the map widget is
// created. To move the camera from JS we flip the wrapper node type
// (`center` ↔ `padding`), which forces a fresh map widget. Adding/removing
// markers does NOT flip, so the user's pan/zoom survives list updates.
(function() {
  var t = jsr.theme;

  var PRESETS = [
    { id: 'old-castle', lat: 53.6772, lng: 23.8231, label: 'Old Castle',
      color: '#e53935', desc: '12th-century castle on the Neman river bank.' },
    { id: 'new-castle', lat: 53.6793, lng: 23.8273, label: 'New Castle',
      color: '#8b5cf6', desc: '18th-century royal palace across the river.' },
    { id: 'kalozha', lat: 53.6785, lng: 23.8190, label: 'Kalozha Church',
      color: '#0ea5e9', desc: 'St. Boris and Gleb church, c. 1180.' },
    { id: 'soviet-sq', lat: 53.6778, lng: 23.8303, label: 'Soviet Square',
      color: '#22c55e', desc: 'Central square with the Farny Church.' },
  ];

  var center = { lat: 53.6790, lng: 23.8255 };
  var zoom = 14;
  var userPins = [];
  var pinSeq = 1;
  var selectedId = null;
  var flip = false; // toggled to force a camera reset (see note above)

  function allMarkers() {
    return PRESETS.concat(userPins);
  }

  function findMarker(id) {
    var all = allMarkers();
    for (var i = 0; i < all.length; i++) {
      if (all[i].id === id) return all[i];
    }
    return null;
  }

  function mapNode() {
    var node = {
      type: 'map',
      height: 340,
      center: center,
      zoom: zoom,
      markers: allMarkers().map(function(m) {
        return {
          id: m.id, lat: m.lat, lng: m.lng,
          label: m.label, color: m.color,
        };
      }),
      onTap: 'map_tap',
      onMarkerTap: 'marker_tap',
    };
    // Flip the wrapper type to force map recreation on camera changes.
    return flip
      ? { type: 'center', child: node }
      : { type: 'padding', padding: [0, 0, 0, 0], child: node };
  }

  function zoomButton(label, action) {
    return {
      type: 'inkWell', onTap: action, borderRadius: 8,
      child: {
        type: 'container',
        width: 36, height: 36, alignment: 'center',
        decoration: {
          color: t.surface, borderRadius: 8,
          border: { color: t.border, width: 1 },
        },
        child: { type: 'text', data: label,
          style: { color: t.text, fontSize: 18, fontWeight: 'w700' } },
      },
    };
  }

  function detailCard(m) {
    return {
      type: 'container',
      margin: [16, 8, 16, 8],
      padding: [12, 12, 12, 12],
      decoration: {
        color: t.surface, borderRadius: 12,
        border: { color: m.color, width: 1 },
      },
      child: { type: 'row', crossAxisAlignment: 'center', children: [
        { type: 'container',
          width: 10, height: 10,
          margin: [0, 0, 10, 0],
          decoration: { color: m.color, borderRadius: 5 },
        },
        { type: 'expanded', child: {
          type: 'column', crossAxisAlignment: 'start', children: [
            { type: 'text', data: m.label,
              style: { color: t.text, fontSize: 14, fontWeight: 'w700' } },
            { type: 'sizedBox', height: 2 },
            { type: 'text',
              data: m.desc || 'Your pin',
              style: { color: t.muted, fontSize: 11 } },
            { type: 'text',
              data: m.lat.toFixed(4) + ', ' + m.lng.toFixed(4),
              style: { color: t.muted, fontSize: 10 } },
          ] } },
        { type: 'inkWell', onTap: 'deselect', borderRadius: 8, child: {
          type: 'padding', padding: [6, 6, 6, 6], child: {
            type: 'icon', name: 'close', color: t.muted, size: 16 } } },
      ] },
    };
  }

  function markerRow(m) {
    var children = [
      { type: 'container',
        width: 8, height: 8,
        margin: [0, 0, 8, 0],
        decoration: { color: m.color, borderRadius: 4 },
      },
      { type: 'expanded', child: {
        type: 'text', data: m.label,
        style: { color: t.text, fontSize: 13,
          fontWeight: m.id === selectedId ? 'w700' : 'w400' },
        maxLines: 1, overflow: 'ellipsis' } },
    ];
    if (m.user) {
      children.push({
        type: 'inkWell', onTap: 'remove_' + m.id, borderRadius: 6, child: {
          type: 'padding', padding: [4, 4, 4, 4], child: {
            type: 'icon', name: 'delete', color: t.muted, size: 14 } },
      });
    }
    return {
      type: 'inkWell', onTap: 'select_' + m.id, borderRadius: 8, child: {
        type: 'container',
        padding: [8, 7, 8, 7],
        decoration: m.id === selectedId
          ? { color: t.surface, borderRadius: 8,
              border: { color: t.accent, width: 1 } }
          : { borderRadius: 8 },
        child: { type: 'row', crossAxisAlignment: 'center',
          children: children },
      },
    };
  }

  function render() {
    var selected = selectedId ? findMarker(selectedId) : null;
    jsr.render({
      type: 'column', crossAxisAlignment: 'stretch', children: [
        // Header: title + zoom controls
        { type: 'padding', padding: [16, 10, 16, 10], child: {
          type: 'row', crossAxisAlignment: 'center', children: [
            { type: 'expanded', child: {
              type: 'column', crossAxisAlignment: 'start', children: [
                { type: 'text', data: 'Grodno, Belarus',
                  style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
                { type: 'text', data: 'Zoom ' + zoom + ' · ' +
                  allMarkers().length + ' markers',
                  style: { color: t.muted, fontSize: 11 } },
              ] } },
            zoomButton('−', 'zoom_out'),
            { type: 'sizedBox', width: 8 },
            zoomButton('+', 'zoom_in'),
          ] } },
        // The map
        { type: 'padding', padding: [12, 0, 12, 0], child: {
          type: 'container',
          decoration: { borderRadius: 12,
            border: { color: t.border, width: 1 } },
          child: { type: 'clipRRect', borderRadius: 12, child: mapNode() },
        } },
        { type: 'padding', padding: [16, 6, 16, 4], child: {
          type: 'text',
          data: 'Tap the map to drop a pin · tap a marker for details',
          style: { color: t.muted, fontSize: 11, textAlign: 'center' } } },
        selected ? detailCard(selected) : { type: 'sizedBox', height: 0 },
        // Marker list
        { type: 'padding', padding: [16, 4, 16, 12], child: {
          type: 'container',
          decoration: { color: t.surface, borderRadius: 12,
            border: { color: t.border, width: 1 } },
          padding: [6, 6, 6, 6],
          child: { type: 'column', crossAxisAlignment: 'stretch',
            children: allMarkers().map(markerRow) },
        } },
      ],
    });
    jsr.exportState({
      zoom: zoom,
      center: center,
      markerCount: allMarkers().length,
      userPins: userPins.length,
      selected: selectedId,
    });
  }

  function handleEvent(actionId, payload) {
    if (actionId === 'zoom_in' || actionId === 'zoom_out') {
      zoom += actionId === 'zoom_in' ? 1 : -1;
      if (zoom < 3) zoom = 3;
      if (zoom > 18) zoom = 18;
      flip = !flip;
      render();
    } else if (actionId === 'map_tap' && payload) {
      var pin = {
        id: 'pin-' + (pinSeq++),
        lat: Math.round(payload.lat * 10000) / 10000,
        lng: Math.round(payload.lng * 10000) / 10000,
        label: 'Pin ' + pinSeq,
        color: t.accent,
        user: true,
      };
      userPins.push(pin);
      selectedId = pin.id;
      render();
    } else if (actionId === 'marker_tap' && payload) {
      selectedId = payload.id;
      render();
    } else if (actionId === 'deselect') {
      selectedId = null;
      render();
    } else if (actionId.indexOf('select_') === 0) {
      var m = findMarker(actionId.slice(7));
      if (m) {
        selectedId = m.id;
        center = { lat: m.lat, lng: m.lng };
        flip = !flip;
        render();
      }
    } else if (actionId.indexOf('remove_') === 0) {
      var rid = actionId.slice(7);
      userPins = userPins.filter(function(p) { return p.id !== rid; });
      if (selectedId === rid) selectedId = null;
      render();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Map — Grodno');
  render();
})();
