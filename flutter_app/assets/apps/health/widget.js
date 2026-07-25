// Health widget — demonstrates the jsr.fa.health bridge UX honestly.
// The bridge is a stub on the host today ("not available yet"); the app
// shows that status in a designed card, plus a clearly-labeled demo
// dashboard of the metrics it WILL display once the bridge lands.
(function() {
  var t = jsr.theme;
  var loading = true;
  var bridgeError = null;

  // Sample data shown as a preview of the real dashboard (never real data).
  var DEMO = [
    { id: 'steps', icon: 'trending_up', label: 'Steps', value: '8,432',
      unit: 'of 10,000 goal', color: '#22c55e',
      chart: [3.2, 5.1, 4.0, 6.8, 5.5, 7.9, 8.4] },
    { id: 'heart', icon: 'favorite', label: 'Heart rate', value: '62',
      unit: 'bpm resting', color: '#f43f5e',
      chart: [68, 71, 66, 64, 70, 63, 62] },
    { id: 'sleep', icon: 'nights_stay', label: 'Sleep', value: '7h 12m',
      unit: 'last night', color: '#8b5cf6',
      chart: [6.5, 7.0, 6.2, 7.5, 6.8, 7.9, 7.2] },
    { id: 'water', icon: 'water_drop', label: 'Water', value: '1.2',
      unit: 'liters today', color: '#0ea5e9',
      chart: [0.4, 0.8, 0.6, 1.0, 0.9, 1.1, 1.2] },
  ];

  function checkBridge() {
    loading = true;
    render();
    jsr.fa.health('summary', {}).then(function(result) {
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
        color: loading ? t.muted : '#f59e0b', size: 28 },
      { type: 'sizedBox', height: 8 },
      { type: 'text',
        data: loading ? 'Checking the health bridge…'
          : bridgeError ? 'Health bridge not available yet'
          : 'Health bridge connected',
        style: { color: t.text, fontSize: 14, fontWeight: 'w600',
          textAlign: 'center' } },
    ];
    if (!loading && bridgeError) {
      children.push({ type: 'sizedBox', height: 4 });
      children.push({ type: 'text', data: bridgeError,
        style: { color: t.muted, fontSize: 11, textAlign: 'center' } });
      children.push({ type: 'sizedBox', height: 10 });
      children.push({ type: 'textButton', text: 'Retry', onTap: 'retry' });
    }
    return {
      type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'container',
        padding: [14, 14, 14, 14],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: loading ? t.border : '#f59e0b', width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'center',
          children: children },
      },
    };
  }

  function demoBanner() {
    return {
      type: 'padding', padding: [16, 10, 16, 6], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'expanded', child: {
            type: 'text', data: 'Dashboard preview',
            style: { color: t.text, fontSize: 13, fontWeight: 'w700' } } },
          { type: 'container',
            padding: [6, 3, 6, 3],
            decoration: { color: '#f59e0b22', borderRadius: 6,
              border: { color: '#f59e0b', width: 1 } },
            child: { type: 'text', data: 'DEMO DATA',
              style: { color: '#f59e0b', fontSize: 9, fontWeight: 'w700',
                letterSpacing: 1 } },
          },
        ] },
    };
  }

  function metricCard(m) {
    return {
      type: 'container',
      padding: [12, 12, 12, 12],
      decoration: {
        color: t.surface, borderRadius: 12,
        border: { color: t.border, width: 1 },
      },
      child: { type: 'column', crossAxisAlignment: 'start', children: [
        { type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: m.icon, color: m.color, size: 16 },
          { type: 'sizedBox', width: 6 },
          { type: 'expanded', child: {
            type: 'text', data: m.label,
            style: { color: t.muted, fontSize: 11 } } },
        ] },
        { type: 'sizedBox', height: 6 },
        { type: 'text', data: m.value,
          style: { color: t.text, fontSize: 20, fontWeight: 'w700' } },
        { type: 'text', data: m.unit,
          style: { color: t.muted, fontSize: 10 } },
        { type: 'sizedBox', height: 6 },
        { type: 'chart', data: m.chart, color: m.color,
          fillColor: m.color + '33', strokeWidth: 2, height: 36 },
      ] },
    };
  }

  function grid() {
    var rows = [];
    for (var i = 0; i < DEMO.length; i += 2) {
      rows.push({
        type: 'padding', padding: [16, 4, 16, 4], child: {
          type: 'row', crossAxisAlignment: 'start', children: [
            { type: 'expanded', child: metricCard(DEMO[i]) },
            { type: 'sizedBox', width: 8 },
            { type: 'expanded', child: metricCard(DEMO[i + 1]) },
          ] },
      });
    }
    return rows;
  }

  function render() {
    var children = [
      // Header
      { type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'favorite', color: '#f43f5e', size: 20 },
          { type: 'sizedBox', width: 8 },
          { type: 'text', data: 'Health',
            style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
        ] } },
      bridgeCard(),
      demoBanner(),
    ];
    children = children.concat(grid());
    children.push({
      type: 'padding', padding: [16, 8, 16, 16], child: {
        type: 'text',
        data: 'All numbers above are static sample data. Once the host ' +
          'implements the health bridge, this dashboard will show your ' +
          'real metrics.',
        style: { color: t.muted, fontSize: 10, textAlign: 'center' } },
    });
    jsr.render({ type: 'column', crossAxisAlignment: 'stretch',
      children: children });
    jsr.exportState({
      loading: loading,
      bridgeAvailable: !loading && !bridgeError,
      bridgeError: bridgeError,
      demoData: true,
    });
  }

  jsr.onEvent(function(actionId) {
    if (actionId === 'retry') checkBridge();
  });
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Health');
  checkBridge();
})();
