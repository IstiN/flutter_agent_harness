// Project layout for the Fa — AI Agent hero promo.
//
// Layers: background (orbs + vignette, full length) → content (showcase,
// then endcard overlapping the showcase's fade-out).

project = {
  lib: 'lib/animation.js',
  texts: {
    en: {
      showcase: {
        timeline: 'Showcase',
        phases: [
          { kicker: 'L I V E   W I D G E T S', line1: 'A dashboard that is', line2: 'truly yours.' },
          { kicker: 'T H E   A G E N T   B U I L D S   I T', line1: 'Your own apps,', line2: 'built by chat.' },
          { kicker: 'I N - A P P   C H A T', line1: 'Fa lives inside', line2: 'every app.' },
          { kicker: 'M E D I A', line1: 'It draws, speaks', line2: 'and plays.' },
          { kicker: 'P R I V A C Y', line1: 'Any provider — keys', line2: 'stay in the Keychain.' },
        ],
      },
      endcard: {
        timeline: 'End card',
        title: 'Fa — AI Agent',
        tag: 'on your hardware, under your rules',
      },
    },
    ru: {
      showcase: {
        timeline: 'Витрина',
        phases: [
          { kicker: 'Ж И В Ы Е   В И Д Ж Е Т Ы', line1: 'Дашборд, который', line2: 'по-настоящему ваш.' },
          { kicker: 'А Г Е Н Т   С Т Р О И Т', line1: 'Свои приложения —', line2: 'прямо из чата.' },
          { kicker: 'Ч А Т   В Н У Т Р И', line1: 'Fa живёт внутри', line2: 'каждого приложения.' },
          { kicker: 'М Е Д И А', line1: 'Рисует, говорит', line2: 'и играет.' },
          { kicker: 'П Р И В А Т Н О С Т Ь', line1: 'Любой провайдер —', line2: 'ключи в Keychain.' },
        ],
      },
      endcard: {
        timeline: 'Финал',
        title: 'Fa — AI-агент',
        tag: 'на вашем железе, по вашим правилам',
      },
    },
  },
  scenes: [
    { path: 'scenes/background.scene.js', layer: 'background', start: 0, duration: 570 },
    { path: 'scenes/01_showcase.scene.js', layer: 'content', start: 0, duration: 456 },
    { path: 'scenes/02_endcard.scene.js', layer: 'content', start: 444, duration: 126 },
  ],
};
