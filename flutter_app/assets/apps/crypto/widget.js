// Crypto widget — CoinGecko free API (fetched via Dart, no CORS)
(function() {
  var COINS = [
    {id:'bitcoin',   sym:'BTC', icon:'₿',  color:'#f59e0b'},
    {id:'ethereum',  sym:'ETH', icon:'Ξ',  color:'#818cf8'},
    {id:'solana',    sym:'SOL', icon:'◎',  color:'#34d399'},
    {id:'binancecoin',sym:'BNB',icon:'B',  color:'#fbbf24'},
    {id:'ripple',    sym:'XRP', icon:'✕',  color:'#60a5fa'},
  ];
  var _chartCoin = null;

  function fmtPrice(n) {
    if (n >= 1000) return '$' + Math.round(n).toLocaleString('en-US');
    if (n >= 1)    return '$' + n.toFixed(2);
    return '$' + n.toFixed(4);
  }

  async function load() {
    _chartCoin = null;
    jsr.exportState({ loading: true, view: 'list' });
    jsr.render({type:'center',child:{type:'circularProgressIndicator',size:24}});
    try {
      var ids = COINS.map(function(c){return c.id;}).join(',');
      var url = 'https://api.coingecko.com/api/v3/simple/price?ids='+ids+'&vs_currencies=usd&include_24hr_change=true';
      var data = await jsr.fetchJson(url);

      var now = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
      var rows = COINS.map(function(coin) {
        var info = data[coin.id];
        if (!info) return {type:'sizedBox',height:0};
        var price = info.usd;
        var chg = info.usd_24h_change || 0;
        var chgColor = chg >= 0 ? '#4ade80' : '#f87171';
        var arrow = chg >= 0 ? '▲' : '▼';
        return {
          type:'inkWell', onTap:'show_chart_'+coin.id,
          child:{
            type:'animatedContainer',
            duration: 300,
            curve: 'easeOut',
            margin:[0,0,0,6],
            decoration:{color:'#1e293b',borderRadius:8,borderColor:'#1e3a5f',borderWidth:1},
            padding:[12,10,12,10],
            child:{type:'row',crossAxisAlignment:'center',children:[
              // Icon
              {type:'container',
               decoration:{color:'#0f172a',borderRadius:20},
               padding:[8,8,8,8],
               child:{type:'text',data:coin.icon,style:{fontSize:18,color:coin.color}}},
              {type:'sizedBox',width:10},
              // Name
              {type:'expanded',child:{type:'column',crossAxisAlignment:'start',children:[
                {type:'text',data:coin.sym,style:{color:'#e2e8f0',fontWeight:'w700',fontSize:14}},
                {type:'text',data:coin.id,style:{color:'#475569',fontSize:10}},
              ]}},
              // Price & change
              {type:'column',crossAxisAlignment:'end',mainAxisSize:'min',children:[
                {type:'text',data:fmtPrice(price),
                 style:{color:'#f1f5f9',fontWeight:'w700',fontSize:14}},
                {type:'row',mainAxisSize:'min',children:[
                  {type:'text',data:arrow+' ',style:{color:chgColor,fontSize:11}},
                  {type:'text',data:Math.abs(chg).toFixed(2)+'%',
                   style:{color:chgColor,fontSize:11}},
                ]},
              ]},
            ]},
          },
        };
      });

      jsr.render({
        type:'column',
        crossAxisAlignment:'stretch',
        children:[
          {type:'padding',padding:[12,12,12,8],child:{type:'column',
            crossAxisAlignment:'stretch',
            children: rows,
          }},
          {type:'padding',padding:[0,0,12,8],child:{
            type:'row',mainAxisAlignment:'spaceBetween',children:[
              {type:'padding',padding:[12,0,0,0],child:{
                type:'text',data:'via CoinGecko · '+now,
                style:{color:'#334155',fontSize:10},
              }},
              {type:'textButton',text:'Refresh',onTap:'refresh'},
            ],
          }},
        ]
      });
      var exported = COINS.map(function(coin) {
        var info = data[coin.id];
        if (!info) return null;
        return {
          id: coin.id,
          symbol: coin.sym,
          usd: info.usd,
          change24h: info.usd_24h_change || 0,
        };
      }).filter(function(item) { return item != null; });
      jsr.exportState({ loading: false, view: 'list', updatedAt: now, prices: exported });
    } catch(e) {
      jsr.exportState({ loading: false, view: 'list', error: e.message || String(e) });
      jsr.showError('Could not load prices:\n'+e.message);
    }
  }

  async function showChart(coin) {
    jsr.render({type:'center',child:{type:'circularProgressIndicator',size:24}});
    try {
      var url = 'https://api.coingecko.com/api/v3/coins/'+coin.id+'/market_chart?vs_currency=usd&days=1&interval=hourly';
      var data = await jsr.fetchJson(url);
      // data.prices is [[timestamp, price], ...]
      var prices = data.prices.map(function(p){ return p[1]; });

      var price = prices.length ? prices[prices.length-1] : 0;
      // Get 24h change from simple price endpoint if available, else compute
      var first = prices.length ? prices[0] : price;
      var chg = first > 0 ? ((price - first) / first) * 100 : 0;
      var chgColor = chg >= 0 ? '#4ade80' : '#f87171';
      var arrow = chg >= 0 ? '▲' : '▼';

      jsr.render({
        type:'column', crossAxisAlignment:'stretch',
        children:[
          // Header
          {type:'padding', padding:[12,12,12,8], child:{type:'row',
            crossAxisAlignment:'center',
            children:[
              {type:'inkWell', onTap:'back', child:{type:'padding', padding:[0,0,8,0],
                child:{type:'icon', icon:'arrow_back_ios', size:18, color:'#94a3b8'}}},
              {type:'container',
               decoration:{color:'#0f172a',borderRadius:20},
               padding:[6,6,6,6],
               child:{type:'text',data:coin.icon,style:{fontSize:16,color:coin.color}}},
              {type:'sizedBox',width:8},
              {type:'expanded',child:{type:'column',crossAxisAlignment:'start',children:[
                {type:'text',data:coin.sym,style:{color:'#f1f5f9',fontWeight:'w700',fontSize:16}},
                {type:'text',data:coin.id,style:{color:'#64748b',fontSize:10}},
              ]}},
              {type:'column',crossAxisAlignment:'end',mainAxisSize:'min',children:[
                {type:'text',data:fmtPrice(price),style:{color:'#f1f5f9',fontWeight:'w700',fontSize:16}},
                {type:'row',mainAxisSize:'min',children:[
                  {type:'text',data:arrow+' ',style:{color:chgColor,fontSize:11}},
                  {type:'text',data:Math.abs(chg).toFixed(2)+'%',style:{color:chgColor,fontSize:11}},
                ]},
              ]},
            ]
          }},
          // Chart
          {type:'padding', padding:[12,0,12,12], child:{
            type:'chart', points:prices, color:chgColor, height:120, fill:true,
          }},
          // Footer
          {type:'padding', padding:[12,0,12,8], child:{
            type:'text', data:'24h — via CoinGecko',
            style:{color:'#334155',fontSize:10,textAlign:'center'},
          }},
        ]
      });
    } catch(e) {
      jsr.showError('Could not load chart:\n'+e.message);
    }
  }

  function handleEvent(actionId, payload) {
    if (actionId === 'refresh') { load(); return; }
    if (actionId === 'back') { _chartCoin = null; load(); return; }
    if (actionId.startsWith('show_chart_')) {
      var coinId = actionId.substring('show_chart_'.length);
      var coin = COINS.find(function(c){ return c.id === coinId; });
      if (coin) { _chartCoin = coin; showChart(coin); }
      return;
    }
  }

  jsr.onEvent(handleEvent);
  jsr.setTitle('Crypto Prices');
  load();
  setInterval(load, 60 * 1000);
})();
