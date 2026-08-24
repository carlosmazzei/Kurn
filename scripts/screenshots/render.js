#!/usr/bin/env node
//
// render.js
//
// Renders polished marketing screenshots (dark gradient background, 3D
// phone mockup, glassmorphism card) from the raw App Store screenshots that
// `bundle exec fastlane screenshots` (fastlane/Fastfile) captures.
//
// Expects --input-dir to contain one subdirectory per App Store locale
// (matching fastlane/metadata/<locale>/, e.g. "en-US", "pt-BR"), each with
// fastlane's raw "<device>-<screenName>.png" files (SnapshotHelper's
// naming). Copy per locale + screen name comes from config.json; a locale
// with no entry falls back to config.json's "default" block.
//
// Usage:
//   node render.js --input-dir <dir> --output-dir <dir> \
//     [--config <config.json>] [--template <template.html>] \
//     [--width 1290] [--height 2796]
//
'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const DEFAULT_WIDTH = 1290;
const DEFAULT_HEIGHT = 2796;

function parseArgs(argv) {
  const args = {
    inputDir: null,
    outputDir: null,
    configPath: path.join(__dirname, 'config.json'),
    templatePath: path.join(__dirname, 'template.html'),
    width: DEFAULT_WIDTH,
    height: DEFAULT_HEIGHT
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--input-dir':
        args.inputDir = argv[++i];
        break;
      case '--output-dir':
        args.outputDir = argv[++i];
        break;
      case '--config':
        args.configPath = argv[++i];
        break;
      case '--template':
        args.templatePath = argv[++i];
        break;
      case '--width':
        args.width = parseInt(argv[++i], 10);
        break;
      case '--height':
        args.height = parseInt(argv[++i], 10);
        break;
      default:
        console.warn(`[render] Ignoring unrecognized argument: ${arg}`);
    }
  }

  if (!args.inputDir || !args.outputDir || Number.isNaN(args.width) || Number.isNaN(args.height)) {
    console.error(
      '[render] Usage: node render.js --input-dir <dir> --output-dir <dir> ' +
        '[--config <config.json>] [--template <template.html>] [--width N] [--height N]'
    );
    process.exit(1);
  }

  return args;
}

function loadJSON(file, label) {
  if (!fs.existsSync(file)) {
    console.warn(`[render] ${label} not found at "${file}"; continuing with no configuration.`);
    return {};
  }
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    console.error(`[render] Failed to parse ${label} at "${file}": ${err.message}`);
    process.exit(1);
  }
}

// fastlane's SnapshotHelper names files "<device>-<screenName>.png". Device
// names never contain a dash (e.g. "iPhone 17 Pro Max"), so the first dash
// is the separator.
function extractScreenName(baseName) {
  const dash = baseName.indexOf('-');
  return dash === -1 ? baseName : baseName.slice(dash + 1);
}

function isPhoneDevice(baseName) {
  return /iphone/i.test(baseName);
}

function escapeHTML(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function fillTemplate(template, { copy, screenshotSrc }) {
  return template
    .replaceAll('{{BADGE}}', escapeHTML(copy.badge || ''))
    .replaceAll('{{TITLE}}', escapeHTML(copy.title || ''))
    .replaceAll('{{TITLE_HIGHLIGHT}}', escapeHTML(copy.titleHighlight || ''))
    .replaceAll('{{SUBTITLE}}', escapeHTML(copy.subtitle || ''))
    .replaceAll('{{CARD_ICON}}', escapeHTML(copy.cardIcon || '✦'))
    .replaceAll('{{CARD_STAT}}', escapeHTML(copy.cardStat || ''))
    .replaceAll('{{CARD_LABEL}}', escapeHTML(copy.cardLabel || ''))
    .replaceAll('{{SCREENSHOT_SRC}}', screenshotSrc);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!fs.existsSync(args.inputDir)) {
    console.error(`[render] Input directory not found: "${args.inputDir}"`);
    process.exit(1);
  }

  const template = fs.readFileSync(args.templatePath, 'utf8');
  const config = loadJSON(args.configPath, 'config.json');

  fs.mkdirSync(args.outputDir, { recursive: true });

  const locales = fs
    .readdirSync(args.inputDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();

  if (locales.length === 0) {
    console.warn(`[render] No locale directories found under "${args.inputDir}". Nothing to render.`);
  }

  const browser = await chromium.launch();
  let rendered = 0;
  let skipped = 0;

  try {
    const page = await browser.newPage({
      viewport: { width: args.width, height: args.height },
      deviceScaleFactor: 1
    });

    for (const locale of locales) {
      const localeInputDir = path.join(args.inputDir, locale);
      let localeConfig = config[locale];
      if (!localeConfig) {
        console.warn(
          `[render] No copy configured for locale "${locale}" in config.json; falling back to "default".`
        );
        localeConfig = config.default || {};
      }

      const files = fs
        .readdirSync(localeInputDir)
        .filter((file) => file.toLowerCase().endsWith('.png'))
        .sort();

      if (files.length === 0) {
        console.warn(`[render] No screenshots found in "${localeInputDir}"; skipping locale.`);
        continue;
      }

      const localeOutputDir = path.join(args.outputDir, locale);
      fs.mkdirSync(localeOutputDir, { recursive: true });

      for (const file of files) {
        const baseName = path.basename(file, '.png');

        if (!isPhoneDevice(baseName)) {
          console.warn(
            `[render] Skipping "${locale}/${file}": this template targets ${args.width}x${args.height} ` +
              '(6.7" iPhone); other device sizes need a different template/resolution.'
          );
          skipped++;
          continue;
        }

        const screenName = extractScreenName(baseName);
        const copy = localeConfig[screenName];
        if (!copy) {
          console.warn(
            `[render] No copy configured for screen "${screenName}" (locale "${locale}") in config.json; skipping.`
          );
          skipped++;
          continue;
        }

        const imagePath = path.join(localeInputDir, file);
        let imageBase64;
        try {
          imageBase64 = fs.readFileSync(imagePath).toString('base64');
        } catch (err) {
          console.warn(`[render] Could not read "${imagePath}": ${err.message}; skipping.`);
          skipped++;
          continue;
        }

        const html = fillTemplate(template, {
          copy,
          screenshotSrc: `data:image/png;base64,${imageBase64}`
        });

        await page.setContent(html, { waitUntil: 'networkidle' });

        const outFile = path.join(localeOutputDir, `${screenName}.png`);
        await page.screenshot({ path: outFile });
        console.log(`[render] Rendered ${locale}/${screenName}.png`);
        rendered++;
      }
    }
  } finally {
    await browser.close();
  }

  console.log(`[render] Done. Rendered ${rendered} image(s), skipped ${skipped}.`);

  if (rendered === 0) {
    console.error('[render] No marketing screenshots were rendered - check the warnings above.');
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(`[render] Fatal error: ${err.stack || err}`);
  process.exit(1);
});
