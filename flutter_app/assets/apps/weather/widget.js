// Weather widget — native Flutter UI via JSON tree
// Uses wttr.in free API (fetched through Dart, no CORS)
// Features animated transitions between city changes
// All colors come from jsr.theme (follows the host's light/dark mode).
(function() {
  var city = 'London';
  var _inputCity = city;
  var _lastData = null; // last successful payload, kept for theme re-renders

  // The host fetch has no timeout of its own — a hanging request must not
  // spin the loader forever.
  function withTimeout(promise, ms, message) {
    return new Promise(function(resolve, reject) {
      var done = false;
      setTimeout(function() {
        if (!done) { done = true; reject(new Error(message)); }
      }, ms);
      promise.then(function(v) {
        if (!done) { done = true; resolve(v); }
      }, function(e) {
        if (!done) { done = true; reject(e); }
      });
    });
  }

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

  function _stat(t, icon, label, value) {
    return {type:'column',crossAxisAlignment:'center',mainAxisSize:'min',children:[
      {type:'text',data:icon,style:{fontSize:18}},
      {type:'sizedBox',height:2},
      {type:'text',data:value,style:{color:t.text,fontSize:13,fontWeight:'w600'}},
      {type:'text',data:label,style:{color:t.muted,fontSize:10}},
    ]};
  }

  function render(d) {
    // Read jsr.theme fresh on every render — the object is replaced when
    // the host theme changes.
    var t = jsr.theme;
    jsr.render({
      type: 'animatedOpacity',
      opacity: 1.0,
      duration: 400,
      curve: 'easeInOut',
      child: {
      type: 'column',
      crossAxisAlignment: 'stretch',
      children: [
        // Header with animated temperature
        {type:'animatedContainer', duration:500, curve:'easeOut',
         decoration:{color:t.surface, borderRadius:0},
         padding:[16,20,16,16],
         child:{type:'column',crossAxisAlignment:'center',children:[
          {type:'text',data:d.icon,style:{fontSize:52}},
          {type:'sizedBox',height:4},
          {type:'text',data:d.areaName+', '+d.country,
           style:{color:t.muted,fontSize:12,textAlign:'center'}},
          {type:'sizedBox',height:6},
          {type:'text',data:d.tempC+'°C',
           style:{fontSize:40,fontWeight:'w700',color:t.text,textAlign:'center'}},
          {type:'text',data:d.desc,
           style:{color:t.text,fontSize:13,textAlign:'center'}},
        ]}},
        // Stats row
        {type:'padding',padding:[12,12,12,8],child:{type:'row',
          mainAxisAlignment:'spaceAround',
          children:[
            _stat(t,'💧','Humidity',d.humidity+'%'),
            _stat(t,'💨','Wind',d.windKmph+' km/h'),
            _stat(t,'🌡️','Feels',d.feelsLikeC+'°C'),
            _stat(t,'👁️','Vis.',d.visibilityKm+' km'),
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
          style:{color:t.muted,fontSize:10,textAlign:'right'},
        }},
      ]
    }});
  }

  async function load() {
    jsr.exportState({ loading: true, query: city });
    jsr.render({type:'center',child:{type:'circularProgressIndicator',size:24}});
    try {
      var url = 'https://wttr.in/' + encodeURIComponent(city) + '?format=j1';
      var data = await withTimeout(jsr.fetchJson(url), 10000, 'Request timed out');
      var cur = data.current_condition[0];
      var area = data.nearest_area[0];

      jsr.setTitle('Weather — ' + area.areaName[0].value);

      _lastData = {
        icon: iconForDesc(cur.weatherDesc[0].value),
        areaName: area.areaName[0].value,
        country: area.country[0].value,
        tempC: cur.temp_C,
        desc: cur.weatherDesc[0].value,
        humidity: cur.humidity,
        windKmph: cur.windspeedKmph,
        feelsLikeC: cur.FeelsLikeC,
        visibilityKm: cur.visibility,
      };
      render(_lastData);
      jsr.exportState({
        loading: false,
        query: city,
        city: _lastData.areaName,
        country: _lastData.country,
        tempC: _lastData.tempC,
        feelsLikeC: _lastData.feelsLikeC,
        humidity: _lastData.humidity,
        windKmph: _lastData.windKmph,
        visibilityKm: _lastData.visibilityKm,
        description: _lastData.desc,
      });
    } catch(e) {
      jsr.exportState({ loading: false, query: city, error: e.message || String(e) });
      jsr.showError('Could not load weather:\n'+e.message);
    }
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
  // Re-render with the new colors when the host flips light/dark mode.
  jsr._onThemeChange = function() {
    if (_lastData) render(_lastData);
  };
  jsr.storage.get('city').then(function(saved) {
    if (saved) { city = saved; _inputCity = saved; }
    load();
    setInterval(load, 10 * 60 * 1000);
  });
})();
