// Weather widget — native Flutter UI via JSON tree
// Uses wttr.in free API (fetched through Dart, no CORS)
// Features animated transitions between city changes
(function() {
  var city = 'London';
  var _inputCity = city;
  var _visible = false; // for fade-in animation

  function iconForDesc(desc) {
    var d = desc.toLowerCase();
    if (d.indexOf('sun') >= 0 || d.indexOf('clear') >= 0) return '☀️';
    if (d.indexOf('part') >= 0) return '⛅';
    if (d.indexOf('cloud') >= 0 || d.indexOf('overcast') >= 0) return '☁️';
    if (d.indexOf('rain') >= 0 || d.indexOf('drizzle') >= 0) return '🌧️';
    if (d.indexOf('snow') >= 0 || d.indexOf('blizzard') >= 0) return '❄️';
    if (d.indexOf('thunder') >= 0) return '⛈️';
    if (d.indexOf('fog') >= 0 || d.indexOf('mist') >= 0) return '🌫️';
    return '🌡️';
  }

  async function load() {
    jsr.exportState({ loading: true, query: city });
    jsr.render({type:'center',child:{type:'circularProgressIndicator',size:24}});
    try {
      var url = 'https://wttr.in/' + encodeURIComponent(city) + '?format=j1';
      var data = await jsr.fetchJson(url);
      var cur = data.current_condition[0];
      var area = data.nearest_area[0];
      var areaName = area.areaName[0].value;
      var country = area.country[0].value;
      var icon = iconForDesc(cur.weatherDesc[0].value);

      jsr.setTitle('Weather — ' + areaName);

      // Fade out then in on city change
      _visible = true;

      jsr.render({
        type: 'animatedOpacity',
        opacity: _visible ? 1.0 : 0.0,
        duration: 400,
        curve: 'easeInOut',
        child: {
        type: 'column',
        crossAxisAlignment: 'stretch',
        children: [
          // Header with animated temperature
          {type:'animatedContainer', duration:500, curve:'easeOut',
           decoration:{color:'#0f172a', borderRadius:0},
           padding:[16,20,16,16],
           child:{type:'column',crossAxisAlignment:'center',children:[
            {type:'text',data:icon,style:{fontSize:52}},
            {type:'sizedBox',height:4},
            {type:'text',data:areaName+', '+country,
             style:{color:'#94a3b8',fontSize:12,textAlign:'center'}},
            {type:'sizedBox',height:6},
            {type:'text',data:cur.temp_C+'°C',
             style:{fontSize:40,fontWeight:'w700',color:'#f1f5f9',textAlign:'center'}},
            {type:'text',data:cur.weatherDesc[0].value,
             style:{color:'#cbd5e1',fontSize:13,textAlign:'center'}},
          ]}},
          // Stats row
          {type:'padding',padding:[12,12,12,8],child:{type:'row',
            mainAxisAlignment:'spaceAround',
            children:[
              _stat('💧','Humidity',cur.humidity+'%'),
              _stat('💨','Wind',cur.windspeedKmph+' km/h'),
              _stat('🌡️','Feels',cur.FeelsLikeC+'°C'),
              _stat('👁️','Vis.',cur.visibility+' km'),
            ]
          }},
          // City input row
          {type:'padding',padding:[12,0,12,12],child:{type:'row',crossAxisAlignment:'center',children:[
            {type:'expanded',child:{
              type:'textField',
              value: city,
              hint: 'Enter city…',
              onSubmit: 'submit_city',
              onChange: 'city_input_change',
            }},
            {type:'sizedBox',width:8},
            {type:'textButton',text:'Go',onTap:'submit_city_btn'},
          ]}},
          {type:'padding',padding:[0,0,12,8],child:{
            type:'text',
            data:'via wttr.in',
            style:{color:'#334155',fontSize:10,textAlign:'right'},
          }},
        ]
      }});
      jsr.exportState({
        loading: false,
        query: city,
        city: areaName,
        country: country,
        tempC: cur.temp_C,
        feelsLikeC: cur.FeelsLikeC,
        humidity: cur.humidity,
        windKmph: cur.windspeedKmph,
        visibilityKm: cur.visibility,
        description: cur.weatherDesc[0].value,
      });
    } catch(e) {
      jsr.exportState({ loading: false, query: city, error: e.message || String(e) });
      jsr.showError('Could not load weather:\n'+e.message);
    }
  }

  function _stat(icon, label, value) {
    return {type:'column',crossAxisAlignment:'center',mainAxisSize:'min',children:[
      {type:'text',data:icon,style:{fontSize:18}},
      {type:'sizedBox',height:2},
      {type:'text',data:value,style:{color:'#e2e8f0',fontSize:13,fontWeight:'w600'}},
      {type:'text',data:label,style:{color:'#64748b',fontSize:10}},
    ]};
  }

  function cityFromPayload(payload) {
    if (!payload) return '';
    return String(
      payload.city || payload.value || payload.name || '',
    ).trim();
  }

  async function handleEvent(actionId, payload) {
    if (actionId === 'city_input_change') {
      _inputCity = payload.value;
    } else if (
      actionId === 'set_city' ||
      actionId === 'submit_city' ||
      actionId === 'submit_city_btn'
    ) {
      var newCity = cityFromPayload(payload) || _inputCity.trim();
      if (!newCity) return;
      city = newCity;
      _inputCity = city;
      await jsr.storage.set('city', city);
      await load();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.storage.get('city').then(function(saved) {
    if (saved) { city = saved; _inputCity = saved; }
    load();
    setInterval(load, 10 * 60 * 1000);
  });
})();
