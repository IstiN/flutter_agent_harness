// English Teacher — daily flashcards with an auto-flip demo loop, progress
// dots and a streak counter. All colors come from jsr.theme.
(function() {
  var SVG = {
    cap: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0zM22 10v6M6 12.5V16a6 3 0 0 0 12 0v-3.5"/></svg>',
    flame: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/></svg>',
    volume: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H2v6h4l5 4zM15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>',
    check: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4.5 4.5L19 7"/></svg>',
    refresh: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 0 1 15.5-6.2L21 8.5M21 3v5.5h-5.5M21 12a9 9 0 0 1-15.5 6.2L3 15.5M3 21v-5.5h5.5"/></svg>'
  };

  var cards = [
    { en: 'apple', phon: '[ˈæpəl]', ru: 'яблоко', note: 'съедобный плод' },
    { en: 'journey', phon: '[ˈdʒɜːni]', ru: 'путешествие', note: 'долгая дорога' },
    { en: 'bright', phon: '[braɪt]', ru: 'яркий', note: 'полный света' }
  ];
  var total = 12;
  var cardIndex = 0, learned = 4, flipped = false;

  setInterval(function() {
    flipped = !flipped;
    render();
  }, 2400);

  setInterval(function() {
    cardIndex = (cardIndex + 1) % cards.length;
    flipped = false;
    if (cardIndex === 0 && learned < total) learned += 1;
    render();
  }, 7200);

  function chip(t, iconSvg, text, accent) {
    return {type:'container',padding:[10,6,10,6],decoration:{color:t.surfaceAlt,borderRadius:16,border:{color:t.border}},
      child:{type:'row',mainAxisSize:'min',children:[
        {type:'svg',data:iconSvg,width:14,color:accent ? t.accent : t.muted},
        {type:'sizedBox',width:5},
        {type:'text',data:text,style:{color:accent ? t.accent : t.muted,fontSize:11,fontWeight:'w600'}}
      ]}};
  }

  function dots(t) {
    var children = [];
    for (var i = 0; i < total; i++) {
      children.push({type:'animatedContainer',duration:350,curve:'easeInOut',
        width: i === learned - 1 ? 18 : 8,height:8,margin:[0,0,4,0],
        decoration:{color:i < learned ? t.accent2 : t.border,borderRadius:4}});
    }
    return {type:'row',mainAxisSize:'min',children:children};
  }

  function flashcard(t) {
    var card = cards[cardIndex];
    var front = {type:'column',mainAxisSize:'min',crossAxisAlignment:'center',children:[
      {type:'text',data:card.en,style:{color:t.text,fontSize:26,fontWeight:'w700'}},
      {type:'sizedBox',height:4},
      {type:'row',mainAxisSize:'min',children:[
        {type:'svg',data:SVG.volume,width:14,color:t.muted},
        {type:'sizedBox',width:5},
        {type:'text',data:card.phon,style:{color:t.muted,fontSize:13}}
      ]}
    ]};
    var back = {type:'column',mainAxisSize:'min',crossAxisAlignment:'center',children:[
      {type:'text',data:card.ru,style:{color:t.accent2,fontSize:24,fontWeight:'w700'}},
      {type:'sizedBox',height:4},
      {type:'text',data:card.note,style:{color:t.muted,fontSize:13}}
    ]};
    return {type:'entrance',animation:'fadeScale',delay:140,duration:320,curve:'easeOut',
      child:{type:'container',margin:[16,4,16,0],height:150,alignment:'center',
        decoration:{color:t.surface,borderRadius:16,border:{color:t.borderBright}},
        child:{type:'animatedSwitcher',switchKey:flipped ? 'back' : 'front',
          animation:'scale',duration:260,curve:'fastOutSlowIn',
          child:flipped ? back : front}}};
  }

  function render() {
    var t = jsr.theme;
    jsr.render({type:'safeArea',child:{type:'column',crossAxisAlignment:'stretch',children:[
      {type:'padding',padding:[16,12,16,8],child:{type:'row',children:[
        {type:'container',width:34,height:34,alignment:'center',decoration:{color:t.surfaceAlt,borderRadius:10},
          child:{type:'svg',data:SVG.cap,width:20,color:t.accent2}},
        {type:'sizedBox',width:10},
        {type:'expanded',child:{type:'column',crossAxisAlignment:'start',mainAxisSize:'min',children:[
          {type:'text',data:'Daily English',style:{color:t.text,fontSize:15,fontWeight:'w700'}},
          {type:'text',data:'A2 → B1 · 10 min a day',style:{color:t.muted,fontSize:11}}
        ]}},
        chip(t, SVG.flame, '7-day', true)
      ]}},

      flashcard(t),

      {type:'padding',padding:[16,12,16,0],child:{type:'column',crossAxisAlignment:'stretch',children:[
        {type:'row',children:[
          {type:'text',data:learned + ' of ' + total + ' learned',style:{color:t.muted,fontSize:11,fontWeight:'w600'}},
          {type:'expanded',child:{type:'sizedBox'}},
          chip(t, SVG.refresh, 'review', false)
        ]},
        {type:'sizedBox',height:10},
        dots(t)
      ]}},

      {type:'padding',padding:[16,12,16,0],child:{type:'row',children:[
        {type:'expanded',child:{type:'button',label:'Show answer',icon:'refresh',color:t.surfaceAlt,textColor:t.text,onPressed:'flip'}},
        {type:'sizedBox',width:10},
        {type:'expanded',child:{type:'button',label:'I know this',icon:'check',color:t.accent2,textColor:t.onAccent,onPressed:'know'}}
      ]}}
    ]}});
  }

  jsr.onEvent(function(name) {
    if (name === 'flip') { flipped = !flipped; render(); }
    if (name === 'know') {
      if (learned < total) learned += 1;
      cardIndex = (cardIndex + 1) % cards.length;
      flipped = false;
      render();
    }
  });
  render();
})();
