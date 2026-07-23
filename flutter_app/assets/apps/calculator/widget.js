// Calculator widget — pure JS with native Flutter UI + animations
(function() {
  var expr = '';
  var justCalc = false;
  var pressedKey = '';

  function render() {
    var btnRows = [
      ['C','±','%','÷'],
      ['7','8','9','×'],
      ['4','5','6','−'],
      ['1','2','3','+'],
      ['0','.','⌫','='],
    ];

    var opBg = '#b45309'; var numBg = '#1e293b';
    var specBg= '#334155'; var eqBg  = '#2563eb';

    var rows = btnRows.map(function(row) {
      return {type:'row',children:row.map(function(k) {
        var bg = (['÷','×','−','+'].indexOf(k)>=0) ? opBg :
                 (k==='=' ? eqBg :
                 (['C','±','%','⌫'].indexOf(k)>=0) ? specBg : numBg);
        var isPressed = (pressedKey === k);
        return {
          type:'expanded',
          child:{type:'padding',padding:[3,3,3,3],child:{
            type:'gestureDetector',
            onTapDown:'press_'+k,
            onTapUp:'release_'+k,
            onTap:'btn_'+k,
            child:{type:'animatedContainer',
              duration: 100,
              curve: 'easeOut',
              decoration:{color: isPressed ? '#ffffff22' : bg, borderRadius:8},
              padding:[0, isPressed ? 12 : 14, 0, isPressed ? 12 : 14],
              transform: isPressed ? {scale: 0.92} : {scale: 1.0},
              child:{type:'text',data:k,style:{
                color:'#ffffff',fontSize:18,fontWeight:'w600',textAlign:'center',
              }},
            },
          }},
        };
      })};
    });

    // Animated display
    var display = {type:'animatedContainer',
      duration: 200,
      curve: 'easeOut',
      decoration:{color:'#0f172a',borderRadius:12},
      padding:[16,12,16,12],
      margin:[0,0,0,8],
      child:{type:'column',crossAxisAlignment:'end',children:[
        {type:'text',data:expr||'',style:{color:'#475569',fontSize:13},
         maxLines:1,overflow:'ellipsis'},
        {type:'sizedBox',height:4},
        {type:'animatedOpacity', opacity: expr ? 1.0 : 0.6, duration: 150,
         child:{type:'text',data:_preview()||'0',
          style:{color:'#f1f5f9',fontSize:32,fontWeight:'w700'},
          maxLines:1,overflow:'ellipsis'}},
      ]},
    };

    jsr.render({
      type:'padding',padding:[12,12,12,12],
      child:{type:'column',crossAxisAlignment:'stretch',children:[display].concat(rows)},
    });
    jsr.exportState({
      expression: expr,
      preview: _preview(),
      display: _preview() || '0',
    });
  }

  function _preview() {
    if (!expr) return '0';
    try {
      var safe = expr.replace(/÷/g,'/').replace(/×/g,'*').replace(/−/g,'-');
      var v = Function('"use strict";return('+safe+')')();
      if (!isFinite(v)) return 'Error';
      return +v.toFixed(10)+'';
    } catch(e){ return ''; }
  }

  function press(k) {
    if (k==='C'){expr='';justCalc=false;render();return;}
    if (k==='⌫'){expr=expr.slice(0,-1);render();return;}
    if (k==='='){
      try{
        var safe=expr.replace(/÷/g,'/').replace(/×/g,'*').replace(/−/g,'-');
        var v=Function('"use strict";return('+safe+')')();
        expr=''+Number(v.toFixed(10));
        justCalc=true;
      }catch(e){expr='';justCalc=true;}
      render();return;
    }
    if (k==='±'){expr=expr.startsWith('-')?expr.slice(1):expr?'-'+expr:expr;render();return;}
    if (k==='%'){
      try{var v=Function('"use strict";return('+expr.replace(/÷/g,'/').replace(/×/g,'*').replace(/−/g,'-')+')')();expr=''+Number((v/100).toFixed(10));}catch(e){}
      render();return;
    }
    var opMap={'÷':'/','×':'*'};
    if (justCalc && /[\d.]/.test(k)){expr='';justCalc=false;}
    expr += opMap[k]||k;
    render();
  }

  function handleEvent(actionId, payload) {
    if (actionId.startsWith('press_')) {
      pressedKey = actionId.slice(6);
      render();
    } else if (actionId.startsWith('release_')) {
      pressedKey = '';
      render();
    } else if (actionId.startsWith('btn_')) {
      pressedKey = '';
      press(actionId.slice(4));
    }
  }

  jsr.onEvent(handleEvent);
  jsr.setTitle('Calculator');
  render();
})();
