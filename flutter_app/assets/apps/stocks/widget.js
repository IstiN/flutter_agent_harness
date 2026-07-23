// Stocks widget — Yahoo Finance v8 chart API (fetched via Dart, no CORS)
(function() {
  var DEFAULT = ['AAPL','MSFT','GOOGL','NVDA','TSLA'];
  var symbols = DEFAULT.slice();
  var _chartSymbol = null;
  var _symbolInput = '';

  function fmt(n, sign) {
    var s = n >= 0 ? (sign ? '+' : '') : '-';
    return s + Math.abs(n).toFixed(2);
  }

  async function fetchQuote(sym) {
    var url = 'https://query2.finance.yahoo.com/v8/finance/chart/' + sym + '?interval=1d&range=5d';
    var data = await jsr.fetchJson(url, {
      headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36' }
    });
    var meta = data.chart.result[0].meta;
    var price = meta.regularMarketPrice || 0;
    var prev  = meta.chartPreviousClose || price;
    var chgAbs = price - prev;
    var chgPct = prev > 0 ? (chgAbs / prev) * 100 : 0;
    return { symbol: sym, price: price, chgAbs: chgAbs, chgPct: chgPct,
             longName: meta.longName || meta.shortName || sym };
  }

  async function load() {
    _chartSymbol = null;
    jsr.exportState({ loading: true, symbols: symbols, view: 'list' });
    jsr.render({type:'center',child:{type:'circularProgressIndicator',size:24}});
    try {
      var quotes = await Promise.all(symbols.map(fetchQuote));
      var now = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});

      var rows = quotes.map(function(q) {
        var chgColor = q.chgPct >= 0 ? '#4ade80' : '#f87171';
        var bgColor  = q.chgPct >= 0 ? '#052e16' : '#2d0a0a';
        return {
          type: 'inkWell', onTap: 'show_chart_' + q.symbol,
          child: {
            type: 'container', margin: [0,0,0,6],
            decoration: {color:'#1e293b', borderRadius:8, borderColor:'#334155', borderWidth:1},
            padding: [12,10,12,10],
            child: {type:'row', crossAxisAlignment:'center', children:[
              {type:'expanded', child:{type:'column', crossAxisAlignment:'start', children:[
                {type:'text', data: q.symbol, style:{color:'#e2e8f0', fontWeight:'w700', fontSize:14}},
                {type:'text', data: q.longName.substring(0,22),
                 style:{color:'#475569', fontSize:10}, maxLines:1, overflow:'ellipsis'},
              ]}},
              {type:'column', crossAxisAlignment:'end', mainAxisSize:'min', children:[
                {type:'text', data: '$' + q.price.toFixed(2),
                 style:{color:'#f1f5f9', fontWeight:'w700', fontSize:14}},
                {type:'container', decoration:{color:bgColor, borderRadius:4}, padding:[3,2,3,2],
                 child:{type:'text', data: fmt(q.chgAbs,true)+' ('+fmt(q.chgPct,true)+'%)',
                        style:{color:chgColor, fontSize:10}}},
              ]},
            ]},
          },
        };
      });

      jsr.render({
        type: 'column', crossAxisAlignment: 'stretch',
        children: [
          {type:'padding', padding:[12,12,12,4], child:{
            type:'column', crossAxisAlignment:'stretch', children: rows,
          }},
          {type:'padding', padding:[12,4,12,4], child:{
            type:'textField', value: symbols.join(','), hint:'AAPL,MSFT,GOOGL',
            onSubmit:'apply_symbols', onChange:'symbol_input_change',
          }},
          {type:'padding', padding:[12,4,12,8], child:{type:'row',
            mainAxisAlignment:'end',
            children:[
              {type:'textButton', text:'Refresh', onTap:'refresh'},
            ]
          }},
          {type:'padding', padding:[0,0,12,8], child:{
            type:'text', data:'Yahoo Finance · '+now,
            style:{color:'#334155', fontSize:10, textAlign:'right'},
          }},
        ]
      });
      jsr.exportState({
        loading: false,
        view: 'list',
        symbols: symbols,
        updatedAt: now,
        quotes: quotes.map(function(q) {
          return {
            symbol: q.symbol,
            name: q.longName,
            price: q.price,
            changeAbs: q.chgAbs,
            changePct: q.chgPct,
          };
        }),
      });
    } catch(e) {
      jsr.exportState({ loading: false, symbols: symbols, error: e.message || String(e) });
      jsr.showError('Could not load stocks:\n' + e.message);
    }
  }

  async function showChart(sym) {
    jsr.render({type:'center',child:{type:'circularProgressIndicator',size:24}});
    try {
      var url = 'https://query2.finance.yahoo.com/v8/finance/chart/' + sym + '?interval=5m&range=1d';
      var data = await jsr.fetchJson(url, {
        headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36' }
      });
      var result = data.chart.result[0];
      var meta = result.meta;
      var closes = result.indicators.quote[0].close;
      // Filter out null values
      var filtered = closes.filter(function(v){ return v != null; });
      var price = meta.regularMarketPrice || 0;
      var prev  = meta.chartPreviousClose || price;
      var chgAbs = price - prev;
      var chgPct = prev > 0 ? (chgAbs / prev) * 100 : 0;
      var chgColor = chgPct >= 0 ? '#4ade80' : '#f87171';
      var q = result.indicators.quote[0];
      var open  = (q.open  && q.open.length)  ? (q.open.find(function(v){return v!=null;})||0).toFixed(2)  : '—';
      var high  = (q.high  && q.high.length)  ? Math.max.apply(null, q.high.filter(function(v){return v!=null;})).toFixed(2)  : '—';
      var low   = (q.low   && q.low.length)   ? Math.min.apply(null, q.low.filter(function(v){return v!=null;})).toFixed(2)   : '—';
      var close = filtered.length ? filtered[filtered.length-1].toFixed(2) : '—';

      jsr.render({
        type:'column', crossAxisAlignment:'stretch',
        children:[
          // Header row
          {type:'padding', padding:[12,12,12,4], child:{type:'row',
            crossAxisAlignment:'center',
            children:[
              {type:'inkWell', onTap:'back', child:{type:'padding', padding:[0,0,8,0],
                child:{type:'icon', icon:'arrow_back_ios', size:18, color:'#94a3b8'}}},
              {type:'expanded', child:{type:'column', crossAxisAlignment:'start', children:[
                {type:'text', data:sym, style:{color:'#f1f5f9', fontWeight:'w700', fontSize:16}},
                {type:'text', data:meta.longName||sym, style:{color:'#64748b', fontSize:10}, maxLines:1},
              ]}},
              {type:'column', crossAxisAlignment:'end', mainAxisSize:'min', children:[
                {type:'text', data:'$'+price.toFixed(2), style:{color:'#f1f5f9', fontWeight:'w700', fontSize:16}},
                {type:'text', data: fmt(chgAbs,true)+' ('+fmt(chgPct,true)+'%)',
                 style:{color:chgColor, fontSize:11}},
              ]},
            ]
          }},
          // Chart
          {type:'padding', padding:[12,4,12,12], child:{
            type:'chart', points:filtered, color:chgColor, height:120, fill:true,
          }},
          // OHLC row
          {type:'padding', padding:[12,0,12,12], child:{type:'row',
            mainAxisAlignment:'spaceBetween',
            children:[
              {type:'column', crossAxisAlignment:'center', mainAxisSize:'min', children:[
                {type:'text', data:'O', style:{color:'#64748b', fontSize:10}},
                {type:'text', data:'$'+open, style:{color:'#e2e8f0', fontSize:12}},
              ]},
              {type:'column', crossAxisAlignment:'center', mainAxisSize:'min', children:[
                {type:'text', data:'H', style:{color:'#64748b', fontSize:10}},
                {type:'text', data:'$'+high, style:{color:'#4ade80', fontSize:12}},
              ]},
              {type:'column', crossAxisAlignment:'center', mainAxisSize:'min', children:[
                {type:'text', data:'L', style:{color:'#64748b', fontSize:10}},
                {type:'text', data:'$'+low, style:{color:'#f87171', fontSize:12}},
              ]},
              {type:'column', crossAxisAlignment:'center', mainAxisSize:'min', children:[
                {type:'text', data:'C', style:{color:'#64748b', fontSize:10}},
                {type:'text', data:'$'+close, style:{color:'#e2e8f0', fontSize:12}},
              ]},
            ]
          }},
        ]
      });
    } catch(e) {
      jsr.showError('Could not load chart:\n' + e.message);
    }
  }

  function handleEvent(actionId, payload) {
    if (actionId === 'refresh') { load(); return; }
    if (actionId === 'back') { _chartSymbol = null; load(); return; }
    if (actionId === 'symbol_input_change') {
      _symbolInput = payload && payload.value ? payload.value : '';
      return;
    }
    if (actionId === 'apply_symbols') {
      var val = (payload && payload.value) ? payload.value : _symbolInput;
      var parsed = val.split(',').map(function(s){ return s.trim().toUpperCase(); })
                      .filter(function(s){ return s.length > 0; });
      if (parsed.length > 0) {
        symbols = parsed;
        jsr.storage.set('symbols', symbols);
        load();
      }
      return;
    }
    if (actionId.startsWith('show_chart_')) {
      var sym = actionId.substring('show_chart_'.length);
      _chartSymbol = sym;
      showChart(sym);
      return;
    }
  }

  jsr.onEvent(handleEvent);
  jsr.setTitle('Stocks');
  jsr.storage.get('symbols').then(function(saved) {
    if (saved && Array.isArray(saved)) symbols = saved;
    load();
    setInterval(load, 5 * 60 * 1000);
  });
})();
