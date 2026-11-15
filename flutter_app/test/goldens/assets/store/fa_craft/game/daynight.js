// Day/night cycle: deterministic clock over a fixed period. Noon at t=0.
var Facraft = Facraft || {};
Facraft.daynight = (function() {
  var PERIOD = 600; // seconds per full cycle
  var DAY = [0.53, 0.81, 0.98];   // sky color at noon
  var NIGHT = [0.04, 0.06, 0.15]; // sky color at midnight

  function advance(t, dt) {
    var next = t + dt;
    while (next >= PERIOD) next -= PERIOD;
    return next;
  }

  function sky(t) {
    var phase = (t % PERIOD + PERIOD) % PERIOD / PERIOD; // 0..1
    var sun = Math.max(0, Math.cos(phase * 2 * Math.PI)); // 1 at noon, 0 at midnight
    var light = 0.12 + 0.88 * sun;
    var c = [
      Math.round((NIGHT[0] + (DAY[0] - NIGHT[0]) * sun) * 255),
      Math.round((NIGHT[1] + (DAY[1] - NIGHT[1]) * sun) * 255),
      Math.round((NIGHT[2] + (DAY[2] - NIGHT[2]) * sun) * 255),
    ];
    return {
      light: light,
      color: '#' + c.map(function(v) { return ('0' + v.toString(16)).slice(-2); }).join(''),
      isDay: sun > 0.2,
    };
  }

  return { PERIOD: PERIOD, advance: advance, sky: sky };
})();
