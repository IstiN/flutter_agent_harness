// yolo-hello — animated demo showcasing widget engine capabilities
// Features: animatedContainer, gestureDetector, requestAnimationFrame
(function() {
  var hue = 0;
  var scale = 1.0;
  var label = 'Hello YoLoIT!';
  var tapCount = 0;
  var bouncing = false;
  var bounceY = 0;
  var bounceVel = 0;

  function hslToHex(h, s, l) {
    s /= 100; l /= 100;
    var a = s * Math.min(l, 1 - l);
    function f(n) {
      var k = (n + h / 30) % 12;
      var color = l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1);
      return Math.round(255 * color).toString(16).padStart(2, '0');
    }
    return '#' + f(0) + f(8) + f(4);
  }

  function render() {
    var bg = hslToHex(hue, 70, 45);
    var textColor = '#ffffff';

    jsr.render({
      type: 'center',
      child: {type: 'column', mainAxisSize: 'min', crossAxisAlignment: 'center', children: [
        // Animated bouncing box
        {type: 'animatedContainer',
          duration: bouncing ? 50 : 300,
          curve: bouncing ? 'linear' : 'bounce',
          width: 200 * scale,
          height: 120 * scale,
          transform: {translateY: bounceY, scale: scale},
          decoration: {color: bg, borderRadius: 16,
            gradient: {colors: [bg, hslToHex((hue + 40) % 360, 70, 35)], begin: 'topLeft', end: 'bottomRight'}
          },
          child: {type: 'gestureDetector', onTap: 'tap', onPanUpdate: 'drag',
            child: {type: 'center',
              child: {type: 'column', mainAxisSize: 'min', children: [
                {type: 'animatedOpacity', opacity: 1.0, duration: 200,
                  child: {type: 'text', data: label, style: {color: textColor, fontSize: 20, fontWeight: 'w700', textAlign: 'center'}}},
                {type: 'sizedBox', height: 8},
                {type: 'text', data: 'Taps: ' + tapCount, style: {color: '#ffffffaa', fontSize: 12, textAlign: 'center'}},
              ]}
            }
          }
        },
        {type: 'sizedBox', height: 20},
        // Controls
        {type: 'row', mainAxisSize: 'min', children: [
          {type: 'textButton', text: '🎨 Color', onTap: 'color'},
          {type: 'sizedBox', width: 8},
          {type: 'textButton', text: '🏀 Bounce', onTap: 'bounce'},
          {type: 'sizedBox', width: 8},
          {type: 'textButton', text: scale > 1 ? '⬇️ Shrink' : '⬆️ Grow', onTap: 'resize'},
        ]},
      ]}
    });
  }

  function startBounce() {
    if (bouncing) return;
    bouncing = true;
    bounceVel = -8;
    function frame(elapsed) {
      bounceVel += 0.6; // gravity
      bounceY += bounceVel;
      if (bounceY >= 0) {
        bounceY = 0;
        bounceVel = -bounceVel * 0.6;
        if (Math.abs(bounceVel) < 1) {
          bouncing = false;
          bounceY = 0;
          render();
          return;
        }
      }
      render();
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  function handleEvent(actionId, payload) {
    switch (actionId) {
      case 'tap':
        tapCount++;
        hue = (hue + 30) % 360;
        render();
        break;
      case 'color':
        hue = (hue + 60) % 360;
        render();
        break;
      case 'bounce':
        startBounce();
        break;
      case 'resize':
        scale = scale > 1 ? 1.0 : 1.3;
        render();
        break;
      case 'drag':
        hue = (hue + 5) % 360;
        render();
        break;
    }
  }

  jsr.onEvent(handleEvent);
  jsr.setTitle('Hello Animated');
  render();
})();
