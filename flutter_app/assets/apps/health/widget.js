// Health dashboard — reads real HealthKit data through jsr.fa.health.summary
// (iOS). When the bridge is unavailable (other platforms, permission off,
// access denied) the app says so honestly and shows a clearly-labeled demo
// dashboard of the metrics it displays once real data flows.
(function() {
  var t = jsr.theme;
  var DAYS = 7;
  var loading = true;
  var bridgeError = null;
  var summary = null;

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
      unit: 'liters today', color: '#0ea5e9', chartType: 'bar',
      chart: [0.4, 0.8, 0.6, 1.0, 0.9, 1.1, 1.2] },
  ];

  function checkBridge() {
    loading = true;
    render();
    jsr.fa.health.summary({ days: DAYS }).then(function(result) {
      loading = false;
      if (result && result.__error) {
        bridgeError = String(result.__error);
        summary = null;
      } else {
        bridgeError = null;
        summary = result;
      }
      render();
    }, function(e) {
      loading = false;
      bridgeError = String(e);
      summary = null;
      render();
    });
  }

  function latest(samples) {
    return samples && samples.length ? samples[samples.length - 1] : null;
  }

  function series(samples) {
    var out = [];
    for (var i = 0; i < (samples || []).length; i++) out.push(samples[i].value);
    return out;
  }

  function fmtCount(v) {
    var s = String(Math.round(v));
    var out = '';
    while (s.length > 3) { out = ',' + s.slice(-3) + out; s = s.slice(0, -3); }
    return s + out;
  }

  // The real dashboard cards from the bridge summary; empty when the span
  // has no data at all.
  function realCards() {
    var cards = [];
    var steps = latest(summary.steps);
    if (steps) {
      cards.push({ id: 'steps', icon: 'trending_up', label: 'Steps',
        value: fmtCount(steps.value), unit: 'steps · ' + steps.date,
        color: '#22c55e', chart: series(summary.steps) });
    }
    var hr = latest(summary.restingHeartRate);
    if (hr) {
      cards.push({ id: 'heart', icon: 'favorite', label: 'Resting HR',
        value: String(Math.round(hr.value)), unit: 'bpm · ' + hr.date,
        color: '#f43f5e', chart: series(summary.restingHeartRate) });
    }
    var sleep = latest(summary.sleepHours);
    if (sleep) {
      cards.push({ id: 'sleep', icon: 'nights_stay', label: 'Sleep',
        value: sleep.value.toFixed(1) + ' h',
        unit: 'night ending ' + sleep.date,
        color: '#8b5cf6', chart: series(summary.sleepHours) });
    }
    return cards;
  }

  function bridgeCard(connected) {
    var children = [
      { type: 'icon',
        name: loading ? 'refresh' : connected ? 'check_circle' : 'info',
        color: loading ? t.muted : connected ? '#22c55e' : '#f59e0b',
        size: 28 },
      { type: 'sizedBox', height: 8 },
      { type: 'text',
        data: loading ? 'Checking the health bridge…'
          : connected ? 'HealthKit connected'
          : 'Health bridge not available',
        style: { color: t.text, fontSize: 14, fontWeight: 'w600',
          textAlign: 'center' } },
    ];
    if (!loading && !connected && bridgeError) {
      children.push({ type: 'sizedBox', height: 4 });
      children.push({ type: 'text', data: bridgeError,
        style: { color: t.muted, fontSize: 11, textAlign: 'center' } });
    }
    if (!loading) {
      children.push({ type: 'sizedBox', height: 10 });
      children.push({ type: 'textButton', text: 'Refresh', onTap: 'retry' });
    }
    return {
      type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'container',
        padding: [14, 14, 14, 14],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: {
            color: loading ? t.border : connected ? '#22c55e' : '#f59e0b',
            width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'center',
          children: children },
      },
    };
  }

  function banner(title, tag, color) {
    return {
      type: 'padding', padding: [16, 10, 16, 6], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'expanded', child: {
            type: 'text', data: title,
            style: { color: t.text, fontSize: 13, fontWeight: 'w700' } } },
          { type: 'container',
            padding: [6, 3, 6, 3],
            decoration: { color: color + '22', borderRadius: 6,
              border: { color: color, width: 1 } },
            child: { type: 'text', data: tag,
              style: { color: color, fontSize: 9, fontWeight: 'w700',
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
        { type: 'chart', data: m.chart, chartType: m.chartType,
          color: m.color, fillColor: m.color + '33', strokeWidth: 2,
          height: 36 },
      ] },
    };
  }

  function cardGrid(cards) {
    var rows = [];
    for (var i = 0; i < cards.length; i += 2) {
      var rowChildren = [
        { type: 'expanded', child: metricCard(cards[i]) },
        { type: 'sizedBox', width: 8 },
      ];
      rowChildren.push(cards[i + 1]
        ? { type: 'expanded', child: metricCard(cards[i + 1]) }
        : { type: 'expanded', child: { type: 'sizedBox', height: 1 } });
      rows.push({
        type: 'padding', padding: [16, 4, 16, 4], child: {
          type: 'row', crossAxisAlignment: 'start', children: rowChildren },
      });
    }
    return rows;
  }

  function emptyCard() {
    return {
      type: 'padding', padding: [16, 10, 16, 6], child: {
        type: 'container',
        padding: [16, 14, 16, 14],
        decoration: { color: t.surface, borderRadius: 12,
          border: { color: t.border, width: 1 } },
        child: { type: 'text',
          data: 'No health data recorded in the last ' + DAYS + ' days.',
          style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
      },
    };
  }

  function latestState() {
    var out = {};
    var steps = latest(summary.steps);
    if (steps) out.steps = steps.value;
    var hr = latest(summary.restingHeartRate);
    if (hr) out.restingHeartRate = hr.value;
    var sleep = latest(summary.sleepHours);
    if (sleep) out.sleepHours = sleep.value;
    return out;
  }

  function render() {
    var real = !loading && !bridgeError && !!summary;
    var children = [
      // Header
      { type: 'padding', padding: [16, 12, 16, 4], child: {
        type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'favorite', color: '#f43f5e', size: 20 },
          { type: 'sizedBox', width: 8 },
          { type: 'text', data: 'Health',
            style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
        ] } },
      bridgeCard(real),
    ];
    if (real) {
      var cards = realCards();
      if (cards.length) {
        children.push(banner('Your health data · last ' + DAYS + ' days',
          'LIVE', '#22c55e'));
        children = children.concat(cardGrid(cards));
      } else {
        children.push(emptyCard());
      }
    } else if (!loading) {
      // Honest fallback: the bridge is unavailable, so preview the dashboard
      // with clearly-labeled sample data.
      children.push(banner('Dashboard preview', 'DEMO DATA', '#f59e0b'));
      children = children.concat(cardGrid(DEMO));
      children.push({
        type: 'padding', padding: [16, 8, 16, 16], child: {
          type: 'text',
          data: 'All numbers above are static sample data. On iOS with ' +
            'health access granted, this dashboard shows your real ' +
            'HealthKit metrics.',
          style: { color: t.muted, fontSize: 10, textAlign: 'center' } },
      });
    }
    jsr.render({ type: 'listView', shrinkWrap: false, children: children });
    jsr.exportState({
      loading: loading,
      bridgeAvailable: real,
      bridgeError: bridgeError,
      demoData: !loading && !real,
      days: DAYS,
      latest: real ? latestState() : null,
    });
  }

  jsr.onEvent(function(actionId) {
    if (actionId === 'retry') checkBridge();
  });
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Health');
  checkBridge();
})();
