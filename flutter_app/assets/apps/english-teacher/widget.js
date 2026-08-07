// Language Tutor — Duolingo-style vocabulary trainer.
// Quiz sessions of 10 questions with hearts and XP, a typing review mode,
// a built-in offline word bank per language, LLM-generated extra words via
// jsr.fa.llm.chat (validated + deduped), and a target-language picker.
// Progress and settings persist in jsr.storage. All colors from jsr.theme.
(function() {
  var SVG = {
    cap: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0zM22 10v6M6 12.5V16a6 3 0 0 0 12 0v-3.5"/></svg>',
    flame: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/></svg>',
    check: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4.5 4.5L19 7"/></svg>',
    x: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg>',
    heart: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M19.5 12.6 12 20l-7.5-7.4A5 5 0 1 1 12 6.1a5 5 0 1 1 7.5 6.5z"/></svg>',
    globe: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/></svg>',
    spark: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l1.9 5.6L19.5 10l-5.6 1.9L12 17.5l-1.9-5.6L4.5 10l5.6-1.4zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8z"/></svg>',
    keyboard: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>',
    trophy: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 21h8M12 17v4M7 4h10v6a5 5 0 0 1-10 0zM7 6H4a1 1 0 0 0-1 1c0 2 1.5 3.5 4 3.6M17 6h3a1 1 0 0 1 1 1c0 2-1.5 3.5-4 3.6"/></svg>'
  };

  var LANGS = [
    { id: 'en', ru: 'Английский', en: 'English' },
    { id: 'de', ru: 'Немецкий', en: 'German' },
    { id: 'es', ru: 'Испанский', en: 'Spanish' },
    { id: 'fr', ru: 'Французский', en: 'French' },
    { id: 'pl', ru: 'Польский', en: 'Polish' }
  ];

  // Built-in offline bank: 12 beginner words per language, translations
  // into both supported UI languages (ru/en).
  var BANK = {
    en: [
      { w: 'apple', p: '[ˈæpəl]', t: { ru: 'яблоко', en: 'apple' } },
      { w: 'journey', p: '[ˈdʒɜːni]', t: { ru: 'путешествие', en: 'journey' } },
      { w: 'bright', p: '[braɪt]', t: { ru: 'яркий', en: 'bright' } },
      { w: 'river', p: '[ˈrɪvər]', t: { ru: 'река', en: 'river' } },
      { w: 'quick', p: '[kwɪk]', t: { ru: 'быстрый', en: 'quick' } },
      { w: 'window', p: '[ˈwɪndəʊ]', t: { ru: 'окно', en: 'window' } },
      { w: 'friend', p: '[frend]', t: { ru: 'друг', en: 'friend' } },
      { w: 'hungry', p: '[ˈhʌŋɡri]', t: { ru: 'голодный', en: 'hungry' } },
      { w: 'morning', p: '[ˈmɔːnɪŋ]', t: { ru: 'утро', en: 'morning' } },
      { w: 'listen', p: '[ˈlɪsən]', t: { ru: 'слушать', en: 'listen' } },
      { w: 'garden', p: '[ˈɡɑːdən]', t: { ru: 'сад', en: 'garden' } },
      { w: 'strong', p: '[strɒŋ]', t: { ru: 'сильный', en: 'strong' } }
    ],
    de: [
      { w: 'Apfel', p: '[ˈaːpfəl]', t: { ru: 'яблоко', en: 'apple' } },
      { w: 'Reise', p: '[ˈʁaɪ̯zə]', t: { ru: 'путешествие', en: 'journey' } },
      { w: 'hell', p: '[hɛl]', t: { ru: 'яркий', en: 'bright' } },
      { w: 'Fluss', p: '[flʊs]', t: { ru: 'река', en: 'river' } },
      { w: 'schnell', p: '[ʃnɛl]', t: { ru: 'быстрый', en: 'quick' } },
      { w: 'Fenster', p: '[ˈfɛnstɐ]', t: { ru: 'окно', en: 'window' } },
      { w: 'Freund', p: '[fʁɔʏ̯nt]', t: { ru: 'друг', en: 'friend' } },
      { w: 'hungrig', p: '[ˈhʊŋʁɪç]', t: { ru: 'голодный', en: 'hungry' } },
      { w: 'Morgen', p: '[ˈmɔʁɡən]', t: { ru: 'утро', en: 'morning' } },
      { w: 'zuhören', p: '[ˈtsuːˌhøːʁən]', t: { ru: 'слушать', en: 'listen' } },
      { w: 'Garten', p: '[ˈɡaʁtən]', t: { ru: 'сад', en: 'garden' } },
      { w: 'stark', p: '[ʃtaʁk]', t: { ru: 'сильный', en: 'strong' } }
    ],
    es: [
      { w: 'manzana', p: '[manˈθana]', t: { ru: 'яблоко', en: 'apple' } },
      { w: 'viaje', p: '[ˈbjaxe]', t: { ru: 'путешествие', en: 'journey' } },
      { w: 'brillante', p: '[briˈʎante]', t: { ru: 'яркий', en: 'bright' } },
      { w: 'río', p: '[ˈri.o]', t: { ru: 'река', en: 'river' } },
      { w: 'rápido', p: '[ˈrapiðo]', t: { ru: 'быстрый', en: 'quick' } },
      { w: 'ventana', p: '[benˈtana]', t: { ru: 'окно', en: 'window' } },
      { w: 'amigo', p: '[aˈmiɣo]', t: { ru: 'друг', en: 'friend' } },
      { w: 'hambriento', p: '[amˈbrjento]', t: { ru: 'голодный', en: 'hungry' } },
      { w: 'mañana', p: '[maˈɲana]', t: { ru: 'утро', en: 'morning' } },
      { w: 'escuchar', p: '[eskuˈtʃaɾ]', t: { ru: 'слушать', en: 'listen' } },
      { w: 'jardín', p: '[xaɾˈðin]', t: { ru: 'сад', en: 'garden' } },
      { w: 'fuerte', p: '[ˈfweɾte]', t: { ru: 'сильный', en: 'strong' } }
    ],
    fr: [
      { w: 'pomme', p: '[pɔm]', t: { ru: 'яблоко', en: 'apple' } },
      { w: 'voyage', p: '[vwa.jaʒ]', t: { ru: 'путешествие', en: 'journey' } },
      { w: 'brillant', p: '[bʁi.jɑ̃]', t: { ru: 'яркий', en: 'bright' } },
      { w: 'rivière', p: '[ʁi.vjɛʁ]', t: { ru: 'река', en: 'river' } },
      { w: 'rapide', p: '[ʁa.pid]', t: { ru: 'быстрый', en: 'quick' } },
      { w: 'fenêtre', p: '[fə.nɛtʁ]', t: { ru: 'окно', en: 'window' } },
      { w: 'ami', p: '[a.mi]', t: { ru: 'друг', en: 'friend' } },
      { w: 'affamé', p: '[a.fa.me]', t: { ru: 'голодный', en: 'hungry' } },
      { w: 'matin', p: '[ma.tɛ̃]', t: { ru: 'утро', en: 'morning' } },
      { w: 'écouter', p: '[e.ku.te]', t: { ru: 'слушать', en: 'listen' } },
      { w: 'jardin', p: '[ʒaʁ.dɛ̃]', t: { ru: 'сад', en: 'garden' } },
      { w: 'fort', p: '[fɔʁ]', t: { ru: 'сильный', en: 'strong' } }
    ],
    pl: [
      { w: 'jabłko', p: '[ˈjap.wkɔ]', t: { ru: 'яблоко', en: 'apple' } },
      { w: 'podróż', p: '[ˈpɔd.ruʂ]', t: { ru: 'путешествие', en: 'journey' } },
      { w: 'jasny', p: '[ˈjas.nɨ]', t: { ru: 'яркий', en: 'bright' } },
      { w: 'rzeka', p: '[ˈʐɛ.ka]', t: { ru: 'река', en: 'river' } },
      { w: 'szybki', p: '[ˈʂɨp.ki]', t: { ru: 'быстрый', en: 'quick' } },
      { w: 'okno', p: '[ˈɔk.nɔ]', t: { ru: 'окно', en: 'window' } },
      { w: 'przyjaciel', p: '[pʂɨˈja.tɕɛl]', t: { ru: 'друг', en: 'friend' } },
      { w: 'głodny', p: '[ˈɡwɔd.nɨ]', t: { ru: 'голодный', en: 'hungry' } },
      { w: 'ranek', p: '[ˈra.nɛk]', t: { ru: 'утро', en: 'morning' } },
      { w: 'słuchać', p: '[ˈswu.xatɕ]', t: { ru: 'слушать', en: 'listen' } },
      { w: 'ogród', p: '[ˈɔ.ɡrut]', t: { ru: 'сад', en: 'garden' } },
      { w: 'silny', p: '[ˈɕil.nɨ]', t: { ru: 'сильный', en: 'strong' } }
    ]
  };

  var I18N = {
    ru: {
      pickLanguage: 'Выбери язык',
      pickHint: 'Что будем учить?',
      start: 'Урок (10 вопросов)',
      typing: 'Печатать слова',
      generate: 'Новые слова (AI)',
      changeLang: 'Сменить язык',
      words: 'слов в базе',
      question: 'Вопрос',
      of: 'из',
      translateThis: 'Переведи слово',
      pickRight: 'Выбери перевод',
      typeAnswer: 'Напиши перевод',
      checkBtn: 'Проверить',
      continueBtn: 'Дальше',
      correct: 'Верно!',
      wrongPrefix: 'Ошибка. Правильно:',
      results: 'Урок завершён',
      xpEarned: 'опыта',
      accuracy: 'точность',
      again: 'Ещё раз',
      home: 'Домой',
      outOfHearts: 'Закончились жизни',
      streakDays: 'дн. подряд',
      generating: 'Генерирую слова…',
      generateFail: 'Не удалось сгенерировать. Проверь подключение модели.',
      generatedOk: 'Добавлено слов: ',
      learned: 'выучено',
      title: 'Языковой тренажёр'
    },
    en: {
      pickLanguage: 'Pick a language',
      pickHint: 'What shall we learn?',
      start: 'Lesson (10 questions)',
      typing: 'Type the words',
      generate: 'New words (AI)',
      changeLang: 'Change language',
      words: 'words in the bank',
      question: 'Question',
      of: 'of',
      translateThis: 'Translate this word',
      pickRight: 'Pick the translation',
      typeAnswer: 'Type the translation',
      checkBtn: 'Check',
      continueBtn: 'Continue',
      correct: 'Correct!',
      wrongPrefix: 'Wrong. Correct answer:',
      results: 'Lesson complete',
      xpEarned: 'XP',
      accuracy: 'accuracy',
      again: 'Again',
      home: 'Home',
      outOfHearts: 'Out of hearts',
      streakDays: 'day streak',
      generating: 'Generating words…',
      generateFail: 'Generation failed. Check the model connection.',
      generatedOk: 'Words added: ',
      learned: 'learned',
      title: 'Language Tutor'
    }
  };

  var state = {
    screen: 'loading',
    native: (typeof jsr.locale === 'string' && jsr.locale.indexOf('ru') === 0) ? 'ru' : 'en',
    lang: null,
    words: [],
    customWords: {},
    quiz: null,
    typedValue: '',
    generating: false,
    notice: null,
    progress: { xp: 0, streak: 0, lastDay: null, learned: {} }
  };

  function L() { return I18N[state.native] || I18N.en; }
  function langMeta(id) {
    for (var i = 0; i < LANGS.length; i++) if (LANGS[i].id === id) return LANGS[i];
    return LANGS[0];
  }
  function langName(id) { var m = langMeta(id); return state.native === 'ru' ? m.ru : m.en; }

  function today() {
    var d = new Date();
    return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
  }

  function shuffle(arr) {
    for (var i = arr.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1));
      var tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
    }
    return arr;
  }

  function allWords() {
    return (BANK[state.lang] || []).concat(state.customWords[state.lang] || []);
  }

  function saveProgress() { jsr.storage.set('tutor_progress', state.progress); }
  function saveSettings() { jsr.storage.set('tutor_settings', { lang: state.lang }); }
  function saveCustom() { jsr.storage.set('tutor_custom', state.customWords); }

  // ── quiz construction ──────────────────────────────────────────────────

  function buildQuiz(typing) {
    var pool = shuffle(allWords().slice());
    var items = pool.slice(0, Math.min(10, pool.length));
    var questions = items.map(function(item, i) {
      var forward = typing ? false : (i % 2 === 0);
      var others = pool.filter(function(o) { return o.w !== item.w; });
      var distract = shuffle(others.slice()).slice(0, 3);
      var options = shuffle([item].concat(distract));
      var answer = 0;
      for (var k = 0; k < options.length; k++) if (options[k].w === item.w) answer = k;
      return { item: item, forward: forward, options: options, answer: answer };
    });
    return { questions: questions, idx: 0, hearts: 3, xp: 0, correctCount: 0, feedback: null, typing: !!typing };
  }

  function startQuiz(typing) {
    state.quiz = buildQuiz(typing);
    state.typedValue = '';
    state.screen = 'quiz';
    render();
  }

  function currentQ() { return state.quiz.questions[state.quiz.idx]; }

  function answerText(q) {
    return q.forward ? q.item.t[state.native] : q.item.w;
  }

  function pickOption(i) {
    var quiz = state.quiz;
    if (!quiz || quiz.feedback) return;
    var q = currentQ();
    var ok = i === q.answer;
    if (ok) {
      quiz.xp += 10;
      quiz.correctCount += 1;
    } else {
      quiz.hearts -= 1;
    }
    quiz.feedback = { picked: i, ok: ok };
    render();
  }

  function checkTyped() {
    var quiz = state.quiz;
    if (!quiz || quiz.feedback) return;
    var q = currentQ();
    var norm = function(s) { return (s || '').trim().toLowerCase(); };
    var ok = norm(state.typedValue) === norm(answerText(q));
    if (ok) {
      quiz.xp += 15;
      quiz.correctCount += 1;
    } else {
      quiz.hearts -= 1;
    }
    quiz.feedback = { picked: -1, ok: ok };
    render();
  }

  function nextQuestion() {
    var quiz = state.quiz;
    if (!quiz || !quiz.feedback) return;
    quiz.feedback = null;
    state.typedValue = '';
    quiz.idx += 1;
    if (quiz.hearts <= 0 || quiz.idx >= quiz.questions.length) {
      finishQuiz();
      return;
    }
    render();
  }

  function finishQuiz() {
    var quiz = state.quiz;
    var learned = state.progress.learned[state.lang] || 0;
    state.progress.learned[state.lang] = learned + quiz.correctCount;
    state.progress.xp += quiz.xp + (quiz.hearts > 0 ? 5 : 0);
    var day = today();
    if (quiz.correctCount > 0 && state.progress.lastDay !== day) {
      state.progress.streak += 1;
      state.progress.lastDay = day;
    }
    saveProgress();
    state.screen = 'results';
    render();
  }

  // ── LLM word generation ────────────────────────────────────────────────

  function generateWords() {
    if (state.generating) return;
    state.generating = true;
    state.notice = null;
    render();
    var known = allWords().map(function(x) { return x.w; }).join(', ');
    var nativeName = state.native === 'ru' ? 'Russian' : 'English';
    var targetName = langMeta(state.lang).en;
    var prompt =
      'You are a language teacher. Give me 8 NEW beginner (A1-A2) ' + targetName +
      ' words with phonetic transcription and ' + nativeName + ' translation. ' +
      'Reply with ONLY a JSON array, no markdown, no comments, like: ' +
      '[{"w":"...","p":"[...]","t":"..."}]. Avoid these words: ' + known;
    jsr.fa.llm.chat([{ role: 'user', content: prompt }]).then(function(reply) {
      var added = 0;
      try {
        var start = reply.indexOf('[');
        var end = reply.lastIndexOf(']');
        var parsed = JSON.parse(reply.substring(start, end + 1));
        var existing = {};
        allWords().forEach(function(x) { existing[x.w.toLowerCase()] = true; });
        var custom = (state.customWords[state.lang] || []).slice();
        parsed.forEach(function(x) {
          if (!x || typeof x.w !== 'string' || typeof x.t !== 'string') return;
          if (existing[x.w.toLowerCase()]) return;
          custom.push({ w: x.w, p: typeof x.p === 'string' ? x.p : '', t: (function() {
            var t = { ru: x.t, en: x.t };
            t[state.native] = x.t;
            return t;
          })() });
          existing[x.w.toLowerCase()] = true;
          added += 1;
        });
        state.customWords[state.lang] = custom;
        saveCustom();
        state.notice = L().generatedOk + added;
      } catch (e) {
        state.notice = L().generateFail;
      }
      state.generating = false;
      render();
    }, function() {
      state.generating = false;
      state.notice = L().generateFail;
      render();
    });
  }

  // ── shared widgets ─────────────────────────────────────────────────────

  function chip(t, iconSvg, text, accent) {
    return { type: 'container', padding: [10, 6, 10, 6], decoration: { color: t.surfaceAlt, borderRadius: 16, border: { color: t.border } },
      child: { type: 'row', mainAxisSize: 'min', children: [
        { type: 'svg', data: iconSvg, width: 14, color: accent ? t.accent : t.muted },
        { type: 'sizedBox', width: 5 },
        { type: 'text', data: text, style: { color: accent ? t.accent : t.muted, fontSize: 11, fontWeight: 'w600' } }
      ] } };
  }

  function header(t, subtitle, chips) {
    return { type: 'padding', padding: [16, 12, 16, 8], child: { type: 'row', children: [
      { type: 'container', width: 34, height: 34, alignment: 'center', decoration: { color: t.surfaceAlt, borderRadius: 10 },
        child: { type: 'svg', data: SVG.cap, width: 20, color: t.accent2 } },
      { type: 'sizedBox', width: 10 },
      { type: 'expanded', child: { type: 'column', crossAxisAlignment: 'start', mainAxisSize: 'min', children: [
        { type: 'text', data: L().title, style: { color: t.text, fontSize: 15, fontWeight: 'w700' } },
        { type: 'text', data: subtitle, style: { color: t.muted, fontSize: 11 } }
      ] } }
    ].concat(chips || []) } };
  }

  function bigButton(t, label, icon, action, accent, disabled) {
    return { type: 'button', label: label, icon: icon,
      color: disabled ? t.surfaceAlt : (accent ? t.accent2 : t.surfaceAlt),
      textColor: disabled ? t.muted : (accent ? t.onAccent : t.text),
      onPressed: disabled ? 'noop' : action };
  }

  function heartsRow(t, hearts) {
    var children = [];
    for (var i = 0; i < 3; i++) {
      children.push({ type: 'svg', data: SVG.heart, width: 16, color: i < hearts ? t.error : t.border });
      children.push({ type: 'sizedBox', width: 3 });
    }
    return { type: 'row', mainAxisSize: 'min', children: children };
  }

  function progressBar(t, done, total) {
    var children = [];
    for (var i = 0; i < total; i++) {
      children.push({ type: 'expanded', child: { type: 'animatedContainer', duration: 250, curve: 'easeInOut',
        height: 6, margin: [0, 0, 3, 0],
        decoration: { color: i < done ? t.accent2 : t.border, borderRadius: 3 } } });
    }
    return { type: 'row', children: children };
  }

  function noticeBar(t) {
    if (!state.notice) return { type: 'sizedBox' };
    return { type: 'padding', padding: [16, 8, 16, 0], child: { type: 'container',
      padding: [10, 8, 10, 8], decoration: { color: t.surfaceAlt, borderRadius: 10, border: { color: t.border } },
      child: { type: 'text', data: state.notice, style: { color: t.text, fontSize: 12 } } } };
  }

  // ── screens ────────────────────────────────────────────────────────────

  function langScreen(t) {
    var buttons = LANGS.map(function(lang) {
      return { type: 'padding', padding: [16, 4, 16, 4], child:
        bigButton(t, state.native === 'ru' ? lang.ru : lang.en, 'language', 'lang:' + lang.id, lang.id === 'en') };
    });
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      header(t, L().pickHint, []),
      { type: 'padding', padding: [16, 8, 16, 4], child: { type: 'text', data: L().pickLanguage,
        style: { color: t.text, fontSize: 18, fontWeight: 'w700' } } }
    ].concat(buttons) } };
  }

  function homeScreen(t) {
    var learned = state.progress.learned[state.lang] || 0;
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      header(t, langName(state.lang), [
        chip(t, SVG.flame, state.progress.streak + ' ' + L().streakDays, true),
        { type: 'sizedBox', width: 6 },
        chip(t, SVG.trophy, state.progress.xp + ' ' + L().xpEarned, false)
      ]),
      noticeBar(t),
      { type: 'padding', padding: [16, 12, 16, 0], child: { type: 'text',
        data: allWords().length + ' ' + L().words + ' · ' + learned + ' ' + L().learned,
        style: { color: t.muted, fontSize: 12, fontWeight: 'w600' } } },
      { type: 'padding', padding: [16, 16, 16, 0], child: bigButton(t, L().start, 'check', 'start', true, allWords().length < 4) },
      { type: 'padding', padding: [16, 8, 16, 0], child: bigButton(t, L().typing, 'edit', 'typing', false, allWords().length < 1) },
      { type: 'padding', padding: [16, 8, 16, 0], child: bigButton(t,
        state.generating ? L().generating : L().generate, 'star', 'generate', false, state.generating) },
      { type: 'padding', padding: [16, 8, 16, 0], child: bigButton(t, L().changeLang, 'language', 'changelang', false, state.generating) }
    ] } };
  }

  function optionButton(t, quiz, q, i) {
    var label = q.forward ? q.options[i].t[state.native] : q.options[i].w;
    var color = t.surface, textColor = t.text, borderColor = t.border;
    if (quiz.feedback) {
      if (i === q.answer) { color = t.accent2; textColor = t.onAccent; borderColor = t.accent2; }
      else if (i === quiz.feedback.picked) { color = t.error; textColor = t.onAccent; borderColor = t.error; }
    }
    return { type: 'padding', padding: [16, 4, 16, 4], child: { type: 'inkWell', onTap: 'opt:' + i,
      child: { type: 'container', padding: [14, 12, 14, 12],
        decoration: { color: color, borderRadius: 12, border: { color: borderColor } },
        child: { type: 'row', children: [
          { type: 'expanded', child: { type: 'text', data: label, style: { color: textColor, fontSize: 14, fontWeight: 'w600' } } },
          quiz.feedback && i === q.answer
            ? { type: 'svg', data: SVG.check, width: 16, color: t.onAccent }
            : (quiz.feedback && i === quiz.feedback.picked
              ? { type: 'svg', data: SVG.x, width: 16, color: t.onAccent }
              : { type: 'sizedBox' })
        ] } } } };
  }

  function feedbackBar(t, quiz, q) {
    if (!quiz.feedback) return { type: 'sizedBox' };
    var ok = quiz.feedback.ok;
    return { type: 'padding', padding: [16, 10, 16, 0], child: { type: 'container',
      padding: [12, 10, 12, 10],
      decoration: { color: ok ? t.surfaceAlt : t.surface, borderRadius: 12,
        border: { color: ok ? t.accent2 : t.error } },
      child: { type: 'column', crossAxisAlignment: 'stretch', mainAxisSize: 'min', children: [
        { type: 'text', data: ok ? L().correct : L().wrongPrefix + ' ' + answerText(q),
          style: { color: ok ? t.accent2 : t.error, fontSize: 13, fontWeight: 'w700' } },
        { type: 'sizedBox', height: 8 },
        bigButton(t, L().continueBtn, 'check', 'next', true)
      ] } } };
  }

  function quizScreen(t) {
    var quiz = state.quiz;
    var q = currentQ();
    var shown = q.forward ? q.item.w : q.item.t[state.native];
    var body;
    if (quiz.typing) {
      body = [
        { type: 'padding', padding: [16, 6, 16, 0], child: { type: 'text', data: L().typeAnswer,
          style: { color: t.muted, fontSize: 12 } } },
        { type: 'padding', padding: [16, 8, 16, 0], child: { type: 'textField',
          hint: L().typeAnswer, value: state.typedValue, onChange: 'typed', onSubmit: 'checktyped' } },
        { type: 'padding', padding: [16, 8, 16, 0], child: bigButton(t, L().checkBtn, 'check', 'checktyped', true, quiz.feedback != null) }
      ];
    } else {
      body = [
        { type: 'padding', padding: [16, 6, 16, 0], child: { type: 'text', data: L().pickRight,
          style: { color: t.muted, fontSize: 12 } } },
        optionButton(t, quiz, q, 0),
        optionButton(t, quiz, q, 1),
        optionButton(t, quiz, q, 2),
        optionButton(t, quiz, q, 3)
      ];
    }
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      { type: 'padding', padding: [16, 12, 16, 4], child: { type: 'row', children: [
        { type: 'text', data: L().question + ' ' + (quiz.idx + 1) + ' ' + L().of + ' ' + quiz.questions.length,
          style: { color: t.muted, fontSize: 11, fontWeight: 'w600' } },
        { type: 'expanded', child: { type: 'sizedBox' } },
        heartsRow(t, quiz.hearts)
      ] } },
      { type: 'padding', padding: [16, 0, 16, 0], child: progressBar(t, quiz.idx, quiz.questions.length) },
      { type: 'container', margin: [16, 12, 16, 0], padding: [22, 16, 22, 16], alignment: 'center',
        decoration: { color: t.surface, borderRadius: 16, border: { color: t.borderBright } },
        child: { type: 'column', mainAxisSize: 'min', crossAxisAlignment: 'center', children: [
          { type: 'text', data: L().translateThis, style: { color: t.muted, fontSize: 11, fontWeight: 'w600' } },
          { type: 'sizedBox', height: 6 },
          { type: 'text', data: shown, style: { color: t.text, fontSize: 24, fontWeight: 'w700' } },
          q.forward && q.item.p ? { type: 'text', data: q.item.p, style: { color: t.muted, fontSize: 12 } } : { type: 'sizedBox' }
        ] } }
    ].concat(body).concat([feedbackBar(t, quiz, q)]) } };
  }

  function resultsScreen(t) {
    var quiz = state.quiz;
    var total = quiz.questions.length;
    var pct = total > 0 ? Math.round((quiz.correctCount / total) * 100) : 0;
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      header(t, langName(state.lang), []),
      { type: 'container', margin: [16, 8, 16, 0], padding: [22, 16, 22, 16], alignment: 'center',
        decoration: { color: t.surface, borderRadius: 16, border: { color: t.borderBright } },
        child: { type: 'column', mainAxisSize: 'min', crossAxisAlignment: 'center', children: [
          { type: 'svg', data: SVG.trophy, width: 40, color: t.accent2 },
          { type: 'sizedBox', height: 10 },
          { type: 'text', data: quiz.hearts <= 0 ? L().outOfHearts : L().results,
            style: { color: t.text, fontSize: 18, fontWeight: 'w700' } },
          { type: 'sizedBox', height: 6 },
          { type: 'text', data: quiz.xp + ' ' + L().xpEarned + ' · ' + pct + '% ' + L().accuracy,
            style: { color: t.muted, fontSize: 13 } }
        ] } },
      { type: 'padding', padding: [16, 16, 16, 0], child: bigButton(t, L().again, 'check', 'start', true, allWords().length < 4) },
      { type: 'padding', padding: [16, 8, 16, 0], child: bigButton(t, L().home, 'language', 'home', false) }
    ] } };
  }

  function render() {
    var t = jsr.theme;
    if (state.screen === 'lang') return jsr.render(langScreen(t));
    if (state.screen === 'quiz') return jsr.render(quizScreen(t));
    if (state.screen === 'results') return jsr.render(resultsScreen(t));
    return jsr.render(homeScreen(t));
  }

  // ── events ─────────────────────────────────────────────────────────────

  jsr.onEvent(function(name, payload) {
    if (name === 'noop') return;
    if (name.indexOf('lang:') === 0) {
      state.lang = name.substring(5);
      saveSettings();
      state.screen = 'home';
      state.notice = null;
      return render();
    }
    if (name === 'changelang') { state.screen = 'lang'; return render(); }
    if (name === 'start') return startQuiz(false);
    if (name === 'typing') return startQuiz(true);
    if (name === 'home') { state.screen = 'home'; return render(); }
    if (name === 'generate') return generateWords();
    if (name.indexOf('opt:') === 0) return pickOption(parseInt(name.substring(4), 10));
    if (name === 'typed') { state.typedValue = payload && payload.value !== undefined ? payload.value : ''; return; }
    if (name === 'checktyped') return checkTyped();
    if (name === 'next') return nextQuestion();
  });

  // ── boot: restore settings + progress + custom words ───────────────────

  Promise.all([
    jsr.storage.get('tutor_settings'),
    jsr.storage.get('tutor_progress'),
    jsr.storage.get('tutor_custom')
  ]).then(function(values) {
    var settings = values[0], progress = values[1], custom = values[2];
    if (settings && typeof settings.lang === 'string' && BANK[settings.lang]) {
      state.lang = settings.lang;
      state.screen = 'home';
    } else {
      state.screen = 'lang';
    }
    if (progress && typeof progress === 'object') {
      state.progress = {
        xp: progress.xp || 0,
        streak: progress.streak || 0,
        lastDay: progress.lastDay || null,
        learned: progress.learned || {}
      };
    }
    if (custom && typeof custom === 'object') state.customWords = custom;
    render();
  });
})();
