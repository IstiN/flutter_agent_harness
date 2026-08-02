// Fitness Trainer — guided workout of the day.
// Live feel: the rep counter ticks, the rest timer counts down in a loop,
// and the progress ring fills as you go. All colors come from jsr.theme.
(function() {
  var SVG = {
    dumbbell: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 7.5v9M4.5 9v6M16.5 7.5v9M19.5 9v6M7.5 12h9"/></svg>',
    flame: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/></svg>',
    timer: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2h4M12 8v4l2.5 2.5"/><circle cx="12" cy="14" r="8"/></svg>',
    check: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8.5 12 2.5 2.5 4.5-5"/></svg>'
  };
  var RING_PATH = 'M 12 2 A 10 10 0 1 1 11.99 2';

  var exercises = [
    { name: 'Goblet Squat', detail: '4 × 15', done: false },
    { name: 'Push-up', detail: '4 × 12', done: false },
    { name: 'Plank', detail: '3 × 45 s', done: true }
  ];

  var reps = 8, target = 15, rest = 30;

  setInterval(function() {
    reps += 1;
    if (reps > target) reps = 8;
    render();
  }, 1200);

  setInterval(function() {
    rest -= 1;
    if (rest < 0) rest = 30;
    render();
  }, 1000);

  function chip(t, iconSvg, text, accent) {
    return {type:'container',padding:[10,6,10,6],decoration:{color:t.surfaceAlt,borderRadius:16,border:{color:t.border}},
      child:{type:'row',mainAxisSize:'min',children:[
        {type:'svg',data:iconSvg,width:14,color:accent ? t.accent : t.muted},
        {type:'sizedBox',width:5},
        {type:'text',data:text,style:{color:accent ? t.accent : t.muted,fontSize:11,fontWeight:'w600'}}
      ]}};
  }

  function progressRing(t) {
    var p = reps / target;
    return {type:'stack',alignment:'center',children:[
      {type:'path',path:RING_PATH,progress:1,color:t.border,strokeWidth:2.6,cap:'round',width:96,height:96,opacity:0.35},
      {type:'path',path:RING_PATH,progress:p,color:t.accent2,strokeWidth:2.6,cap:'round',width:96,height:96},
      {type:'column',mainAxisSize:'min',crossAxisAlignment:'center',children:[
        {type:'text',data:reps + '',style:{color:t.text,fontSize:26,fontWeight:'w700'}},
        {type:'text',data:'of ' + target,style:{color:t.muted,fontSize:11}}
      ]}
    ]};
  }

  function exerciseRow(t, ex, i) {
    return {type:'entrance',animation:'slideUp',delay:300 + i * 90,duration:280,curve:'easeOut',
      child:{type:'container',margin:[0,0,0,8],padding:[12,10,12,10],decoration:{color:t.surface,borderRadius:12,border:{color:t.border}},
        child:{type:'row',children:[
          {type:'svg',data:SVG.check,width:18,color:ex.done ? t.accent : t.border},
          {type:'sizedBox',width:10},
          {type:'expanded',child:{type:'text',data:ex.name,style:{color:ex.done ? t.muted : t.text,fontSize:13,fontWeight:'w600'}}},
          {type:'text',data:ex.detail,style:{color:t.muted,fontSize:12}}
        ]}}};
  }

  function render() {
    var t = jsr.theme;
    var restText = rest <= 3 ? 'GO!' : 'REST 0:' + (rest < 10 ? '0' + rest : rest);
    jsr.render({type:'safeArea',child:{type:'column',crossAxisAlignment:'stretch',children:[
      {type:'padding',padding:[16,12,16,8],child:{type:'row',children:[
        {type:'container',width:34,height:34,alignment:'center',decoration:{color:t.surfaceAlt,borderRadius:10},
          child:{type:'svg',data:SVG.dumbbell,width:20,color:t.accent2}},
        {type:'sizedBox',width:10},
        {type:'expanded',child:{type:'column',crossAxisAlignment:'start',mainAxisSize:'min',children:[
          {type:'text',data:"Today's workout",style:{color:t.text,fontSize:15,fontWeight:'w700'}},
          {type:'text',data:'Full body · 18 min',style:{color:t.muted,fontSize:11}}
        ]}},
        chip(t, SVG.flame, '12', true)
      ]}},

      {type:'entrance',animation:'fadeScale',delay:120,duration:320,curve:'easeOut',
        child:{type:'container',margin:[16,4,16,0],padding:[18,14,18,14],decoration:{color:t.surface,borderRadius:16,border:{color:t.borderBright}},
          child:{type:'row',children:[
            {type:'expanded',child:{type:'column',crossAxisAlignment:'start',mainAxisSize:'min',children:[
              {type:'text',data:'SET 2 OF 4',style:{color:t.accent,fontSize:10,fontWeight:'w700',letterSpacing:1.1}},
              {type:'sizedBox',height:4},
              {type:'text',data:'Goblet Squat',style:{color:t.text,fontSize:17,fontWeight:'w700'}},
              {type:'sizedBox',height:10},
              chip(t, SVG.timer, restText, rest <= 3)
            ]}},
            {type:'sizedBox',width:12},
            progressRing(t)
          ]}}},

      {type:'padding',padding:[16,10,16,0],child:{type:'column',crossAxisAlignment:'stretch',children:[
        {type:'text',data:'UP NEXT',style:{color:t.muted,fontSize:10,fontWeight:'w700',letterSpacing:1.1}},
        {type:'sizedBox',height:8},
        exerciseRow(t, exercises[0], 0),
        exerciseRow(t, exercises[1], 1),
        exerciseRow(t, exercises[2], 2)
      ]}}
    ]}});
  }

  jsr.onEvent(function() {});
  render();
})();
