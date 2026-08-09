// Project layout for the Fa — AI Agent promo v2 ("Describe it. Fa builds it.").
//
// One continuous canvas: a prompt pill types at each station, launches, and
// the real app capture assembles where it lands. Dark brand stage, two
// white-flash theme wipes, off-white end card. Beats per CREATIVE_V2.md.
//
// Layers: background (orbs + vignette, full length) → content beats with
// ~6f crossfade overlaps.

project = {
  lib: 'lib/animation.js',
  texts: {
    en: {
      hook: { timeline: 'Hook', pill: 'Fa — build a game' },
      game: {
        timeline: 'Game',
        caption: 'apps built by chat',
        pill: 'Fa — build my fitness trainer',
      },
      fitness: {
        timeline: 'Fitness',
        caption: 'your coach, in a tap',
        pill: 'Fa — teach me English',
      },
      teacher: {
        timeline: 'English',
        caption: 'a tutor that adapts',
        pill: 'Fa — help with my homework',
      },
      homework: {
        timeline: 'Homework',
        caption: 'homework? solved, shown',
        chip: 'python3',
        pill: 'Fa — watch my stocks',
      },
      stocks: {
        timeline: 'Stocks',
        caption: 'it keeps watch for you',
        pill: 'Fa — keys stay mine',
      },
      zoomout: {
        timeline: 'Everywhere',
        lock: 'your keys stay in the Keychain',
        headline1: 'One agent.',
        headline2: 'Every device.',
      },
      end: {
        timeline: 'End',
        title: 'Describe it. Fa builds it.',
        meta: 'one agent harness · every device',
      },
    },
    ru: {
      hook: { timeline: 'Хук', pill: 'Fa — собери игру' },
      game: {
        timeline: 'Игра',
        caption: 'приложения из чата',
        pill: 'Fa — собери мне фитнес-тренера',
      },
      fitness: {
        timeline: 'Фитнес',
        caption: 'твой тренер — в один тап',
        pill: 'Fa — научи меня английскому',
      },
      teacher: {
        timeline: 'Английский',
        caption: 'репетитор, который подстраивается',
        pill: 'Fa — помоги с домашкой',
      },
      homework: {
        timeline: 'Домашка',
        caption: 'домашка? решено и объяснено',
        chip: 'python3',
        pill: 'Fa — следи за моими акциями',
      },
      stocks: {
        timeline: 'Акции',
        caption: 'оно следит за тобой',
        pill: 'Fa — ключи не трогай',
      },
      zoomout: {
        timeline: 'Везде',
        lock: 'ключи — только в Keychain',
        headline1: 'Один агент.',
        headline2: 'Все устройства.',
      },
      end: {
        timeline: 'Финал',
        title: 'Скажи — и Fa построит.',
        meta: 'один агент · все устройства',
      },
    },
  },
  scenes: [
    { path: 'scenes/background.scene.js', layer: 'background', start: 0, duration: 900 },
    { path: 'scenes/v2_00_hook.scene.js', layer: 'content', start: 0, duration: 60 },
    { path: 'scenes/v2_01_game.scene.js', layer: 'content', start: 54, duration: 156 },
    { path: 'scenes/v2_02_fitness.scene.js', layer: 'content', start: 204, duration: 126 },
    { path: 'scenes/v2_03_teacher.scene.js', layer: 'content', start: 324, duration: 126 },
    { path: 'scenes/v2_04_homework.scene.js', layer: 'content', start: 444, duration: 126 },
    { path: 'scenes/v2_05_stocks.scene.js', layer: 'content', start: 564, duration: 126 },
    { path: 'scenes/v2_06_zoomout.scene.js', layer: 'content', start: 684, duration: 96 },
    { path: 'scenes/v2_07_endcard.scene.js', layer: 'content', start: 774, duration: 126 },
  ],
};
