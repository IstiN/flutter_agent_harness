// First-person player physics: axis-separated AABB vs voxels, gravity, jump,
// sprint, sneak, fly. The sim decouples from frame rate via a dt clamp (E3).
var Facraft = Facraft || {};
Facraft.physics = (function() {
  var W = function() { return Facraft.world; };
  var B = function() { return Facraft.blocks; };

  var WALK = 4.3, SPRINT = 5.6, SNEAK = 1.3, FLY = 10;
  var JUMP = 8.6, GRAVITY = 28, MAX_FALL = 50;
  var HALF = 0.3, HEIGHT = 1.8;
  var DT_MAX = 0.25;

  function dirOf(yaw, pitch) {
    var cp = Math.cos(pitch);
    return { x: -Math.sin(yaw) * cp, y: Math.sin(pitch), z: -Math.cos(yaw) * cp };
  }

  function solidAt(w, x, y, z) {
    return B().isSolid(W().get(w, Math.floor(x), Math.floor(y), Math.floor(z)));
  }

  // Does the entity AABB at (x, y feet, z) overlap any solid voxel?
  // Half-width / height default to the player dims; entities (mobs)
  // carry their own so the collision box matches the visible body.
  function collides(w, x, y, z, hw, h) {
    if (hw === undefined) hw = HALF;
    if (h === undefined) h = HEIGHT;
    for (var bx = Math.floor(x - hw); bx <= Math.floor(x + hw); bx++) {
      for (var by = Math.floor(y); by <= Math.floor(y + h); by++) {
        for (var bz = Math.floor(z - hw); bz <= Math.floor(z + hw); bz++) {
          if (B().isSolid(W().get(w, bx, by, bz))) return true;
        }
      }
    }
    return false;
  }

  // Wish direction in the horizontal plane from held input + yaw (analog
  // joystick axes fold in; sub-unit deflection stays analog).
  function wishDir(p, input) {
    var fwd = (input.forward ? 1 : 0) - (input.back ? 1 : 0) + (input.moveF || 0);
    var strafe = (input.right ? 1 : 0) - (input.left ? 1 : 0) + (input.moveS || 0);
    if (fwd === 0 && strafe === 0) return { x: 0, z: 0 };
    var dir = dirOf(p.yaw, 0);
    var rx = -dir.z, rz = dir.x; // right vector
    var fx = dir.x * fwd + rx * strafe;
    var fz = dir.z * fwd + rz * strafe;
    var len = Math.sqrt(fx * fx + fz * fz);
    if (len > 1) { fx /= len; fz /= len; }
    return { x: fx, z: fz };
  }

  function moveAxis(w, p, delta, axis) {
    if (delta === 0) return { pos: p[axis], blocked: false };
    var cand = p[axis] + delta;
    var hit = collides(
      w,
      axis === 'x' ? cand : p.x,
      axis === 'y' ? cand : p.y,
      axis === 'z' ? cand : p.z,
      p.halfW,
      p.height
    );
    return { pos: hit ? p[axis] : cand, blocked: hit };
  }

  // One step. Returns { landed: impactSpeed|0 }.
  // Substeps so no single move teleports further than ~0.4 blocks:
  // moveAxis only collision-checks the DESTINATION, so one janky frame
  // (rAF starved by a slow paint) at terminal fall speed would otherwise
  // tunnel straight through the floor into the void.
  function step(p, input, w, dt, mode) {
    if (dt > DT_MAX) dt = DT_MAX; // E3: backgrounded tab / throttled rAF
    if (dt < 0) dt = 0;
    var maxV = Math.max(Math.abs(p.vx), Math.abs(p.vy), Math.abs(p.vz), WALK);
    var n = Math.max(1, Math.ceil((maxV + GRAVITY * dt) * dt / 0.4));
    var h = dt / n;
    var landed = 0;
    for (var s = 0; s < n; s++) {
      var r = substep(p, input, w, h, mode);
      if (r.landed > landed) landed = r.landed;
    }
    return { landed: landed };
  }

  function applyInput(p, input, dt, mode) {
    var flying = p.flying === true && mode === 'creative';
    var speed = flying ? FLY : (input.sneak ? SNEAK : (input.sprint ? SPRINT : WALK));
    var wish = wishDir(p, input);
    p.vx = wish.x * speed;
    p.vz = wish.z * speed;

    if (flying) {
      p.vy = (input.jump ? FLY : 0) - (input.sneak ? FLY : 0);
    } else {
      if (input.jump && p.onGround) { p.vy = JUMP; p.onGround = false; }
      p.vy -= GRAVITY * dt;
      if (p.vy < -MAX_FALL) p.vy = -MAX_FALL;
    }
    return flying;
  }

  function moveVertical(w, p, dt, flying, impactBefore) {
    var landed = 0;
    var ry = moveAxis(w, p, p.vy * dt, 'y');
    if (ry.blocked && p.vy < 0) {
      p.y = Math.floor(p.y + p.vy * dt) + 1; // snap onto the block top (no micro-bounce)
      if (!p.onGround) landed = impactBefore;
      p.onGround = true;
      p.vy = 0;
    } else if (ry.blocked) {
      p.vy = 0; // head bump
    } else {
      p.y = ry.pos;
      if (!flying) p.onGround = false;
    }
    return landed;
  }

  function substep(p, input, w, dt, mode) {
    var flying = applyInput(p, input, dt, mode);
    var impactBefore = -p.vy;

    var rx = moveAxis(w, p, p.vx * dt, 'x');
    p.x = rx.pos;
    if (rx.blocked) p.vx = 0;
    var rz = moveAxis(w, p, p.vz * dt, 'z');
    p.z = rz.pos;
    if (rz.blocked) p.vz = 0;

    return { landed: moveVertical(w, p, dt, flying, impactBefore) };
  }

  return { step: step, dirOf: dirOf, EYE_H: 1.62, DT_MAX: DT_MAX };
})();
