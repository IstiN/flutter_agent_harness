// Fa Craft — widget entry. The whole game lives in game/; relative
// imports are inlined at load (js_widget_runtime loader).
import './game/main.js';

// Canonical fa-craft golden render adapter (single-child listView root).
(function() {
  var origRender = jsr.render;
  function unwrap(node) {
    if (!node || typeof node !== 'object') return node;
    if (node.type === 'listView' && Array.isArray(node.children) && node.children.length === 1) {
      return unwrap(node.children[0]);
    }
    if (Array.isArray(node.children)) node.children = node.children.map(unwrap);
    if (node.child) node.child = unwrap(node.child);
    return node;
  }
  jsr.render = function(tree) { origRender(unwrap(tree)); };
})();
