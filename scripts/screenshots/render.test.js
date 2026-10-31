// Run with `node --test` (marketing-screenshots.yml does, before rendering).
// Pins which captures each App Store locale is rendered over.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { planLocales, languageOf, splitDeviceAndScreen } = require('./render.js');
const config = require('./config.json');
const frames = require('./frames.json');

const UI_LANGUAGES = ['en-US', 'pt-BR', 'es-ES', 'fr-FR', 'it', 'de-DE', 'zh-Hans'];

function sources(plan) {
  return Object.fromEntries(plan.map(({ locale, source }) => [locale, source]));
}

test('regional store locales use the capture of their own language', () => {
  const plan = sources(planLocales(UI_LANGUAGES, config, 'en-US'));
  assert.equal(plan['es-MX'], 'es-ES');
  assert.equal(plan['pt-PT'], 'pt-BR');
  assert.equal(plan['fr-CA'], 'fr-FR');
  for (const locale of ['en-GB', 'en-AU', 'en-CA']) {
    assert.equal(plan[locale], 'en-US');
  }
  for (const locale of UI_LANGUAGES) {
    assert.equal(plan[locale], locale);
  }
});

test('every configured locale is rendered', () => {
  const configured = Object.keys(config).filter((key) => key !== 'default' && !key.startsWith('_'));
  const plan = sources(planLocales(UI_LANGUAGES, config, 'en-US'));
  assert.deepEqual(Object.keys(plan).sort(), configured.sort());
});

test('an uncaptured language falls back, and nothing does without a fallback', () => {
  const plan = sources(planLocales(['en-US'], config, 'en-US'));
  assert.equal(plan['de-DE'], 'en-US');
  const withoutFallback = sources(planLocales(['en-US'], config, null));
  assert.equal(withoutFallback['de-DE'], undefined);
  assert.equal(withoutFallback['en-GB'], 'en-US');
});

test('locale and device names are split correctly', () => {
  assert.equal(languageOf('zh-Hans'), 'zh');
  assert.equal(languageOf('it'), 'it');
  assert.deepEqual(splitDeviceAndScreen('iPad Pro 13-inch (M5)-04Summary', frames), {
    deviceName: 'iPad Pro 13-inch (M5)',
    screenName: '04Summary'
  });
});
