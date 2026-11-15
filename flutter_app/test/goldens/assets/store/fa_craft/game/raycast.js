// Voxel raycast (Amanatides & Woo DDA) for block targeting.
var Facraft = Facraft || {};
Facraft.raycast = (function() {
  function ddaState(ox, oy, oz, dx, dy, dz, x, y, z) {
    var stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1, stepZ = dz > 0 ? 1 : -1;
    return {
      x: x, y: y, z: z,
      stepX: stepX, stepY: stepY, stepZ: stepZ,
      tMaxX: dx !== 0 ? ((dx > 0 ? x + 1 - ox : ox - x) / Math.abs(dx)) : Infinity,
      tMaxY: dy !== 0 ? ((dy > 0 ? y + 1 - oy : oy - y) / Math.abs(dy)) : Infinity,
      tMaxZ: dz !== 0 ? ((dz > 0 ? z + 1 - oz : oz - z) / Math.abs(dz)) : Infinity,
      tDeltaX: dx !== 0 ? 1 / Math.abs(dx) : Infinity,
      tDeltaY: dy !== 0 ? 1 / Math.abs(dy) : Infinity,
      tDeltaZ: dz !== 0 ? 1 / Math.abs(dz) : Infinity,
      nx: 0, ny: 0, nz: 0, t: 0,
    };
  }

  function advance(r) {
    if (r.tMaxX < r.tMaxY && r.tMaxX < r.tMaxZ) {
      r.x += r.stepX; r.t = r.tMaxX; r.tMaxX += r.tDeltaX;
      r.nx = -r.stepX; r.ny = 0; r.nz = 0;
    } else if (r.tMaxY < r.tMaxZ) {
      r.y += r.stepY; r.t = r.tMaxY; r.tMaxY += r.tDeltaY;
      r.nx = 0; r.ny = -r.stepY; r.nz = 0;
    } else {
      r.z += r.stepZ; r.t = r.tMaxZ; r.tMaxZ += r.tDeltaZ;
      r.nx = 0; r.ny = 0; r.nz = -r.stepZ;
    }
  }

  // Returns {hit:true, x,y,z (block), nx,ny,nz (entry face normal),
  // px,py,pz (adjacent placement cell)} or {hit:false}.
  function pick(world, ox, oy, oz, dx, dy, dz, maxDist) {
    var len = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (len === 0) return { hit: false };
    dx /= len; dy /= len; dz /= len;

    var x = Math.floor(ox), y = Math.floor(oy), z = Math.floor(oz);
    var solid = function(bx, by, bz) {
      return Facraft.blocks.isSolid(Facraft.world.get(world, bx, by, bz));
    };
    if (solid(x, y, z)) {
      return { hit: true, x: x, y: y, z: z, nx: 0, ny: 0, nz: 0, px: x, py: y, pz: z };
    }

    var r = ddaState(ox, oy, oz, dx, dy, dz, x, y, z);
    while (r.t <= maxDist) {
      advance(r);
      if (r.t > maxDist) break;
      if (solid(r.x, r.y, r.z)) {
        return {
          hit: true, x: r.x, y: r.y, z: r.z, nx: r.nx, ny: r.ny, nz: r.nz,
          px: r.x + r.nx, py: r.y + r.ny, pz: r.z + r.nz,
        };
      }
    }
    return { hit: false };
  }

  return { pick: pick };
})();
