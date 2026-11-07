// Small fixed recipe table → craft from broken blocks (mini-survival ruling).
// Pure functions over a plain inventory map {blockIdOrItem: count}.
var Facraft = Facraft || {};
Facraft.craft = (function() {
  var B = function() { return Facraft.blocks; };

  var RECIPES = [
    { id: 'planks', inn: [{ id: function() { return B().LOG; }, n: 1 }], out: { id: function() { return B().PLANKS; }, n: 4 } },
    { id: 'sticks', inn: [{ id: function() { return B().PLANKS; }, n: 2 }], out: { id: 'stick', n: 4 } },
    { id: 'bricks', inn: [{ id: function() { return B().STONE; }, n: 4 }], out: { id: function() { return B().BRICKS; }, n: 4 } },
  ];

  function find(id) {
    for (var i = 0; i < RECIPES.length; i++) if (RECIPES[i].id === id) return RECIPES[i];
    return null;
  }

  function canCraft(inv, recipe, times) {
    for (var i = 0; i < recipe.inn.length; i++) {
      var need = recipe.inn[i].n * times;
      var have = inv[recipe.inn[i].id()] || 0;
      if (!Number.isInteger(have) || have < need) {
        return 'needs ' + need + '× ' + Facraft.blocks.name(recipe.inn[i].id()) +
          ', has ' + have;
      }
    }
    return null;
  }

  // Returns {ok:true, inv} or {ok:false, error}.
  function craft(inv, recipeId, times) {
    var recipe = find(recipeId);
    if (!recipe) return { ok: false, error: 'unknown recipe ' + recipeId };
    if (!Number.isInteger(times) || times < 1) return { ok: false, error: 'bad count' };
    var err = canCraft(inv, recipe, times);
    if (err) return { ok: false, error: err };
    var out = {};
    for (var k in inv) out[k] = inv[k];
    for (var j = 0; j < recipe.inn.length; j++) {
      var ing = recipe.inn[j];
      out[ing.id()] = (out[ing.id()] || 0) - ing.n * times;
    }
    var oid = typeof recipe.out.id === 'function' ? recipe.out.id() : recipe.out.id;
    out[oid] = (out[oid] || 0) + recipe.out.n * times;
    return { ok: true, inv: out };
  }

  return { recipes: RECIPES, craft: craft, find: find };
})();
