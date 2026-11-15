// Light survival: fall/environment damage, death → respawn, no permadeath.
// Health lives on the world object so log replay derives it (I3/E7).
var Facraft = Facraft || {};
Facraft.survival = (function() {
  var MAX_HP = 20;
  var SAFE_IMPACT = 12;      // impact speed below which landings are safe
  var FALL_FACTOR = 1.5;     // damage per impact-speed block above safe
  var VOID_Y = -16;          // below the world
  var VOID_RATE = 4;         // hp per second in the void

  // Returns {damage: applied}. Dead players take nothing (idempotent death).
  function damage(life, cause, amount) {
    if (life.dead) return { damage: 0 };
    var amt = typeof amount === 'number' && isFinite(amount) ? amount : 0;
    if (amt <= 0) return { damage: 0 };
    amt = Math.min(amt, MAX_HP);
    life.health = Math.max(0, life.health - amt);
    if (life.health === 0) life.dead = true;
    return { damage: amt, cause: cause };
  }

  // Landing after a fall: impact speed → damage (0 below the safe threshold).
  function landing(life, impactSpeed) {
    if (impactSpeed <= SAFE_IMPACT) return { damage: 0 };
    var dmg = Math.floor((impactSpeed - SAFE_IMPACT) * FALL_FACTOR);
    return damage(life, 'fall', dmg);
  }

  // Environment damage per tick while below the world.
  function voidTick(life, y, dt) {
    if (y >= VOID_Y) return { damage: 0 };
    return damage(life, 'void', VOID_RATE * dt);
  }

  // Respawn at full health; inventory untouched (E7 — no dupes, no loss).
  function respawn(life, pos) {
    life.health = MAX_HP;
    life.dead = false;
    life.deaths = (life.deaths || 0) + 1;
    if (pos && life.player) {
      life.player.x = pos.x; life.player.y = pos.y; life.player.z = pos.z;
      life.player.vx = 0; life.player.vy = 0; life.player.vz = 0;
    }
    return { x: life.player ? life.player.x : 0, y: life.player ? life.player.y : 0, z: life.player ? life.player.z : 0 };
  }

  return {
    MAX_HP: MAX_HP, SAFE_IMPACT: SAFE_IMPACT, VOID_Y: VOID_Y,
    damage: damage, landing: landing, voidTick: voidTick, respawn: respawn,
  };
})();
