// Animation Showcase — interactive menu with demo scenes
// Demonstrates: animatedContainer, animatedOpacity, animatedPositioned,
// gestureDetector, requestAnimationFrame, transforms
(function() {
  var currentScene = 'menu';

  // ── Scene: Menu ────────────────────────────────────────────────────────
  function renderMenu() {
    var demos = [
      {id:'fade',     icon:'👻', title:'Fade In/Out',       desc:'animatedOpacity toggle'},
      {id:'morph',    icon:'🔮', title:'Container Morph',   desc:'animatedContainer size + color'},
      {id:'bounce',   icon:'🏀', title:'Bouncing Ball',     desc:'requestAnimationFrame + physics'},
      {id:'cards',    icon:'🃏', title:'Card Stack',        desc:'animatedPositioned in Stack'},
      {id:'drag',     icon:'👆', title:'Drag & Follow',     desc:'gestureDetector onPanUpdate'},
      {id:'pulse',    icon:'💓', title:'Pulse Animation',   desc:'RAF + scale oscillation'},
      {id:'colors',   icon:'🌈', title:'Color Transitions', desc:'smooth gradient morphing'},
    ];

    var items = demos.map(function(d) {
      return {type:'inkWell', onTap:'go_'+d.id, borderRadius:10,
        child:{type:'animatedContainer', duration:200, curve:'easeOut',
          decoration:{color: jsr.theme.surface, borderRadius:10, borderColor: jsr.theme.border, borderWidth:1},
          padding:[12,12,12,12], margin:[0,0,0,8],
          child:{type:'row', crossAxisAlignment:'center', children:[
            {type:'text', data:d.icon, style:{fontSize:24}},
            {type:'sizedBox', width:12},
            {type:'expanded', child:{type:'column', crossAxisAlignment:'start', children:[
              {type:'text', data:d.title, style:{color: jsr.theme.text, fontSize:14, fontWeight:'w600'}},
              {type:'text', data:d.desc, style:{color: jsr.theme.muted, fontSize:11}},
            ]}},
            {type:'icon', name:'arrow_forward', size:16, color: jsr.theme.muted},
          ]},
        },
      };
    });

    jsr.render({type:'column', crossAxisAlignment:'stretch', children:[
      {type:'padding', padding:[12,16,12,8], child:{type:'text', data:'🎬 Animation Demos',
        style:{color: jsr.theme.text, fontSize:18, fontWeight:'w700'}}},
      {type:'expanded', child:{type:'listView', shrinkWrap:false, padding:[12,0,12,12], children:items}},
    ]});
  }

  // ── Scene: Fade ────────────────────────────────────────────────────────
  var fadeVisible = true;
  function renderFade() {
    jsr.render(sceneWrap('Fade In/Out', {
      type:'column', mainAxisAlignment:'center', crossAxisAlignment:'center', children:[
        {type:'animatedOpacity', duration:500, curve:'easeInOut', opacity: fadeVisible ? 1.0 : 0.0,
          child:{type:'container', width:150, height:150,
            decoration:{color: jsr.theme.accent, borderRadius:20},
            child:{type:'center', child:{type:'text', data:'👻', style:{fontSize:48}}}}},
        {type:'sizedBox', height:24},
        {type:'button', text: fadeVisible ? 'Fade Out' : 'Fade In', onTap:'toggle_fade'},
      ]
    }));
  }

  // ── Scene: Morph ───────────────────────────────────────────────────────
  var morphState = 0; // 0,1,2 — different shapes
  var morphConfigs = [
    {w:100, h:100, radius:8,  color:'#3b82f6'},
    {w:200, h:60,  radius:30, color:'#ef4444'},
    {w:140, h:140, radius:70, color:'#10b981'},
  ];
  function renderMorph() {
    var cfg = morphConfigs[morphState];
    jsr.render(sceneWrap('Container Morph', {
      type:'column', mainAxisAlignment:'center', crossAxisAlignment:'center', children:[
        {type:'animatedContainer', duration:600, curve:'elasticIn',
          width:cfg.w, height:cfg.h,
          decoration:{color:cfg.color, borderRadius:cfg.radius},
          child:{type:'center', child:{type:'text', data:'🔮', style:{fontSize:32}}}},
        {type:'sizedBox', height:24},
        {type:'button', text:'Morph →', onTap:'morph_next'},
        {type:'sizedBox', height:8},
        {type:'text', data:'State: '+(morphState+1)+'/'+morphConfigs.length,
          style:{color: jsr.theme.muted, fontSize:11}},
      ]
    }));
  }

  // ── Scene: Bounce ──────────────────────────────────────────────────────
  var ballY = 0, ballVel = 0, ballActive = false;
  function renderBounce() {
    jsr.render(sceneWrap('Bouncing Ball', {
      type:'column', crossAxisAlignment:'center', children:[
        {type:'sizedBox', height:20},
        {type:'container', width:200, height:200,
          decoration:{borderColor: jsr.theme.border, borderWidth:1, borderRadius:12},
          child:{type:'stack', children:[
            // Ball
            {type:'animatedPositioned', duration:16, curve:'linear',
              left:80, top: 160 - Math.max(0, ballY),
              child:{type:'container', width:40, height:40,
                decoration:{color:'#f59e0b', borderRadius:20}}},
            // Ground
            {type:'container', width:200, height:4, decoration:{color: jsr.theme.border},
              positioned:{left:0, bottom:0}},
          ]}},
        {type:'sizedBox', height:16},
        {type:'button', text: ballActive ? '⏸ Stop' : '🏀 Drop!', onTap:'bounce_toggle'},
      ]
    }));
  }
  function bounceLoop() {
    if (!ballActive) return;
    ballVel += 1.2; // gravity
    ballY -= ballVel;
    if (ballY <= 0) {
      ballY = 0;
      ballVel = -ballVel * 0.7;
      if (Math.abs(ballVel) < 2) { ballActive = false; }
    }
    renderBounce();
    if (ballActive) requestAnimationFrame(bounceLoop);
  }

  // ── Scene: Cards ───────────────────────────────────────────────────────
  var cardOffset = 0;
  var cardColors = ['#ef4444','#3b82f6','#10b981','#f59e0b','#8b5cf6'];
  function renderCards() {
    var cards = [];
    for (var i = 0; i < 5; i++) {
      var idx = (i + cardOffset) % 5;
      cards.push({
        type:'animatedPositioned', duration:400, curve:'easeOut',
        left: 30 + idx * 20, top: 10 + idx * 15,
        child:{type:'container', width:120, height:80,
          decoration:{color: cardColors[i], borderRadius:12,
            gradient:{colors:[cardColors[i], '#00000044'], begin:'topLeft', end:'bottomRight'}},
          child:{type:'center', child:{type:'text', data:'#'+(i+1),
            style:{color:'#ffffff', fontSize:20, fontWeight:'w700'}}}},
      });
    }
    jsr.render(sceneWrap('Card Stack', {
      type:'column', crossAxisAlignment:'center', children:[
        {type:'sizedBox', height:16},
        {type:'container', width:260, height:180,
          child:{type:'stack', children: cards}},
        {type:'sizedBox', height:16},
        {type:'button', text:'Shuffle 🃏', onTap:'shuffle_cards'},
      ]
    }));
  }

  // ── Scene: Drag ────────────────────────────────────────────────────────
  var dragX = 100, dragY = 100;
  function renderDrag() {
    jsr.render(sceneWrap('Drag & Follow', {
      type:'container', width:280, height:250,
      decoration:{borderColor: jsr.theme.border, borderWidth:1, borderRadius:12},
      child:{type:'stack', children:[
        {type:'animatedPositioned', duration:80, curve:'easeOut',
          left: dragX - 25, top: dragY - 25,
          child:{type:'container', width:50, height:50,
            decoration:{color:'#8b5cf6', borderRadius:25,
              gradient:{colors:['#8b5cf6','#ec4899'], begin:'topLeft', end:'bottomRight'}},
            child:{type:'center', child:{type:'text', data:'👆', style:{fontSize:20}}}}},
        // Full-area gesture catcher
        {type:'gestureDetector', onPanUpdate:'drag_move', onTapDown:'drag_tap',
          child:{type:'container', width:280, height:250}},
      ]},
    }));
  }

  // ── Scene: Pulse ───────────────────────────────────────────────────────
  var pulseScale = 1.0, pulseGrowing = true, pulseActive = false;
  function renderPulse() {
    jsr.render(sceneWrap('Pulse Animation', {
      type:'column', mainAxisAlignment:'center', crossAxisAlignment:'center', children:[
        {type:'animatedContainer', duration:50, curve:'linear',
          width: 80 * pulseScale, height: 80 * pulseScale,
          decoration:{color:'#ef4444', borderRadius: 40 * pulseScale},
          child:{type:'center', child:{type:'text', data:'💓', style:{fontSize: 24 * pulseScale}}}},
        {type:'sizedBox', height:24},
        {type:'button', text: pulseActive ? '⏹ Stop' : '▶ Start', onTap:'pulse_toggle'},
      ]
    }));
  }
  function pulseLoop() {
    if (!pulseActive) return;
    if (pulseGrowing) {
      pulseScale += 0.02;
      if (pulseScale >= 1.5) pulseGrowing = false;
    } else {
      pulseScale -= 0.02;
      if (pulseScale <= 0.8) pulseGrowing = true;
    }
    renderPulse();
    requestAnimationFrame(pulseLoop);
  }

  // ── Scene: Colors ──────────────────────────────────────────────────────
  var colorHue = 0, colorActive = false;
  function hsl(h, s, l) {
    s /= 100; l /= 100;
    var a = s * Math.min(l, 1 - l);
    function f(n) {
      var k = (n + h / 30) % 12;
      var c = l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1);
      return Math.round(255 * c).toString(16).padStart(2, '0');
    }
    return '#' + f(0) + f(8) + f(4);
  }
  function renderColors() {
    jsr.render(sceneWrap('Color Transitions', {
      type:'column', mainAxisAlignment:'center', crossAxisAlignment:'center', children:[
        {type:'animatedContainer', duration:100, curve:'linear',
          width:200, height:120, decoration:{borderRadius:16,
            gradient:{colors:[hsl(colorHue,70,50), hsl((colorHue+120)%360,70,40)],
              begin:'topLeft', end:'bottomRight'}},
          child:{type:'center', child:{type:'text', data:'🌈',style:{fontSize:40}}}},
        {type:'sizedBox', height:16},
        {type:'text', data:'Hue: '+Math.round(colorHue)+'°', style:{color: jsr.theme.muted, fontSize:12}},
        {type:'sizedBox', height:8},
        {type:'button', text: colorActive ? '⏹ Stop' : '▶ Start', onTap:'color_toggle'},
      ]
    }));
  }
  function colorLoop() {
    if (!colorActive) return;
    colorHue = (colorHue + 2) % 360;
    renderColors();
    requestAnimationFrame(colorLoop);
  }

  // ── Helpers ────────────────────────────────────────────────────────────
  function sceneWrap(title, content) {
    return {type:'column', crossAxisAlignment:'stretch', children:[
      {type:'padding', padding:[8,8,8,4], child:{type:'row', children:[
        {type:'inkWell', onTap:'go_menu', borderRadius:6,
          child:{type:'padding', padding:[8,6,8,6],
            child:{type:'row', mainAxisSize:'min', children:[
              {type:'icon', name:'arrow_back', size:16, color: jsr.theme.accent},
              {type:'sizedBox', width:4},
              {type:'text', data:'Menu', style:{color: jsr.theme.accent, fontSize:12}},
            ]}}},
        {type:'sizedBox', width:8},
        {type:'text', data:title, style:{color: jsr.theme.text, fontSize:14, fontWeight:'w600'}},
      ]}},
      {type:'divider', color: jsr.theme.border},
      {type:'expanded', child:{type:'center', child: content}},
    ]};
  }

  // ── Event handler ──────────────────────────────────────────────────────
  function handleEvent(actionId, payload) {
    // Navigation
    if (actionId === 'go_menu')   { stopAll(); currentScene = 'menu'; renderMenu(); return; }
    if (actionId === 'go_fade')   { currentScene = 'fade'; renderFade(); return; }
    if (actionId === 'go_morph')  { currentScene = 'morph'; renderMorph(); return; }
    if (actionId === 'go_bounce') { currentScene = 'bounce'; ballY=0; ballVel=0; ballActive=false; renderBounce(); return; }
    if (actionId === 'go_cards')  { currentScene = 'cards'; renderCards(); return; }
    if (actionId === 'go_drag')   { currentScene = 'drag'; dragX=100; dragY=100; renderDrag(); return; }
    if (actionId === 'go_pulse')  { currentScene = 'pulse'; pulseScale=1; pulseActive=false; renderPulse(); return; }
    if (actionId === 'go_colors') { currentScene = 'colors'; colorHue=0; colorActive=false; renderColors(); return; }

    // Fade
    if (actionId === 'toggle_fade') { fadeVisible = !fadeVisible; renderFade(); return; }

    // Morph
    if (actionId === 'morph_next') { morphState = (morphState + 1) % morphConfigs.length; renderMorph(); return; }

    // Bounce
    if (actionId === 'bounce_toggle') {
      if (ballActive) { ballActive = false; }
      else { ballActive = true; ballY = 150; ballVel = 0; bounceLoop(); }
      return;
    }

    // Cards
    if (actionId === 'shuffle_cards') { cardOffset = (cardOffset + 1) % 5; renderCards(); return; }

    // Drag
    if (actionId === 'drag_move') { dragX = payload.x; dragY = payload.y; renderDrag(); return; }
    if (actionId === 'drag_tap')  { dragX = payload.x; dragY = payload.y; renderDrag(); return; }

    // Pulse
    if (actionId === 'pulse_toggle') {
      pulseActive = !pulseActive;
      if (pulseActive) pulseLoop(); else renderPulse();
      return;
    }

    // Colors
    if (actionId === 'color_toggle') {
      colorActive = !colorActive;
      if (colorActive) colorLoop(); else renderColors();
      return;
    }
  }

  function stopAll() {
    ballActive = false;
    pulseActive = false;
    colorActive = false;
  }

  jsr.onEvent(handleEvent);
  jsr.setTitle('🎬 Animation Showcase');
  renderMenu();
})();
