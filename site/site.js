const toggle = document.querySelector('#demo-toggle');
const sentence = document.querySelector('#demo-text');
toggle?.addEventListener('click', () => {
  const original = toggle.getAttribute('aria-pressed') !== 'true';
  toggle.setAttribute('aria-pressed', String(original));
  toggle.textContent = original ? 'Show translation' : 'Show original';
  sentence.lang = original ? 'es' : 'en';
  sentence.textContent = original ? 'El tren sale mañana a las nueve.' : 'The train leaves tomorrow at nine.';
});
