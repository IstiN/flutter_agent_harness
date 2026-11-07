// Input mapping tables: keyboard / touch / pointer-lock → game actions.
// Pure tables + pure functions (IT: mapping tables are tested directly).
var Facraft = Facraft || {};
Facraft.inputmap = (function() {
  var KEY_ACTIONS = {
    'w': 'forward', 'arrowUp': 'forward',
    's': 'back', 'arrowDown': 'back',
    'a': 'left', 'arrowLeft': 'left',
    'd': 'right', 'arrowRight': 'right',
    'space': 'jump',
    'shiftLeft': 'sneak', 'shift': 'sneak', // runtime labels modifiers generically
    'controlLeft': 'sprint', 'control': 'sprint',
    'q': 'break', 'e': 'place', // mouse-free mining/building on desktops
    'f': 'fly', 'c': 'craft', 'g': 'mode', 'f3': 'debug',
    'digit1': 'hotbar1', 'digit2': 'hotbar2', 'digit3': 'hotbar3', 'digit4': 'hotbar4',
    'digit5': 'hotbar5', 'digit6': 'hotbar6', 'digit7': 'hotbar7', 'digit8': 'hotbar8',
    // jsr.onKey labels printable keys by CHARACTER ('1'), not code ('digit1').
    '1': 'hotbar1', '2': 'hotbar2', '3': 'hotbar3', '4': 'hotbar4',
    '5': 'hotbar5', '6': 'hotbar6', '7': 'hotbar7', '8': 'hotbar8',
  };

  var HELD = { forward: 1, back: 1, left: 1, right: 1, jump: 1, sneak: 1, sprint: 1 };

  var LOOK_SENS = 0.004;      // default radians per px (pointer-lock deltas)
  var JOY_RADIUS = 48;        // px of virtual joystick travel

  function isHeld(action) { return HELD[action] === 1; }

  // Map one key event into the held-state map. Returns {action} for the
  // dispatcher (null = ignore). Held verbs update state; taps fire once
  // (repeats suppressed).
  function applyKey(held, ev) {
    var action = KEY_ACTIONS[ev.key];
    if (!action) return { action: null };
    if (isHeld(action)) {
      held[action] = ev.down === true;
      return { action: action, held: true };
    }
    if (!ev.down || ev.repeat) return { action: null };
    return { action: action };
  }

  // Drag-to-look (touch / fallback) and pointer-lock deltas share one mapping
  // (AC7): both are "look deltas in px" → yaw/pitch radians.
  function panToLook(dx, dy, sens) {
    var s = typeof sens === 'number' ? sens : LOOK_SENS;
    return { dyaw: -dx * s, dpitch: -dy * s };
  }
  var pointerDeltaToLook = panToLook;

  // Virtual joystick: px offset from pad center → analog move vector.
  // {x: strafe right+, z: forward+}, clamped to the unit circle.
  function joystickMove(dx, dy, radius) {
    var r = radius || JOY_RADIUS;
    var x = dx / r, z = -dy / r;
    var len = Math.sqrt(x * x + z * z);
    if (len > 1) { x /= len; z /= len; }
    return { x: x, z: z };
  }

  return {
    KEY_ACTIONS: KEY_ACTIONS, LOOK_SENS: LOOK_SENS, JOY_RADIUS: JOY_RADIUS,
    isHeld: isHeld, applyKey: applyKey, panToLook: panToLook,
    pointerDeltaToLook: pointerDeltaToLook, joystickMove: joystickMove,
  };
})();
