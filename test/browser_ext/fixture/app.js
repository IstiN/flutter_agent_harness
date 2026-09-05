// Fixture app for the headless Chrome suite: counter, form, shadow DOM,
// SPA route, and a trusted-event recorder (window.__events) the AC16 pin
// asserts against. Plain js, no build step.
(() => {
  'use strict';

  // Trusted-event recorder: every document-level click lands here with
  // isTrusted, so tests can tell real input from synthesized events.
  window.__events = [];
  document.addEventListener('click', (e) => {
    window.__events.push({ trusted: e.isTrusted, target: e.target.id || '' });
  });

  let count = 0;
  const counter = document.getElementById('counter');
  counter.addEventListener('click', () => {
    count += 1;
    document.getElementById('count').textContent = String(count);
    counter.textContent = `clicked ${count} times`;
  });

  document.getElementById('greet-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const greeting = document.getElementById('greeting');
    greeting.textContent = `Hello, ${document.getElementById('name').value}!`;
    greeting.hidden = false;
  });

  // Shadow-DOM node: invisible to document.querySelector, visible to
  // read_dom({includeShadow: true}).
  const shadowTarget = document.createElement('button');
  shadowTarget.id = 'shadow-target';
  shadowTarget.textContent = 'inside shadow';
  document.getElementById('host').attachShadow({ mode: 'open' })
    .appendChild(shadowTarget);

  // SPA-style route: pushState + DOM marker, no reload.
  document.getElementById('router').addEventListener('click', (e) => {
    e.preventDefault();
    history.pushState({}, '', '/route2');
    const marker = document.getElementById('route-marker');
    marker.textContent = `navigated: ${location.pathname}`;
    marker.hidden = false;
  });
})();
