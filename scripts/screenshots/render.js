#!/usr/bin/env node
//
// render.js
//
// Renders App-Store-ready marketing screenshots (dark gradient background,
// real iPhone/iPad device frame, glassmorphism card) from the raw App Store
// screenshots that `bundle exec fastlane screenshots` (fastlane/Fastfile)
// captures. Output is sized to Apple's exact required App Store Connect
// pixel dimensions per device (see frames.json) so it can be uploaded
// directly, not just used as a separate marketing asset.
//
// Expects --input-dir to contain one subdirectory per App Store locale
// (matching fastlane/metadata/<locale>/, e.g. "en-US", "pt-BR"), each with
// fastlane's raw "<device>-<screenName>.png" files (SnapshotHelper's
// naming). Copy per locale + screen name comes from config.json; a locale
// with no entry falls back to config.json's "default" block. Device frame
// assets + placement come from frames.json + frames/*.png (vendored from
// fastlane/frameit-frames, MIT).
//
// Usage:
//   node render.js --input-dir <dir> --output-dir <dir> \
//     [--config <config.json>] [--template <template.html>] \
//     [--frames-manifest <frames.json>] [--frames-dir <frames/>] \
//     [--frame-color <name>] [--width 1290] [--height 2796]
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
    framesManifestPath: path.join(__dirname, 'frames.json'),
    framesDir: path.join(__dirname, 'frames'),
    frameColor: null,
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
      case '--frames-manifest':
        args.framesManifestPath = argv[++i];
        break;
      case '--frames-dir':
        args.framesDir = argv[++i];
        break;
      case '--frame-color':
        args.frameColor = argv[++i];
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
        '[--config <config.json>] [--template <template.html>] ' +
        '[--frames-manifest <frames.json>] [--frames-dir <frames/>] [--frame-color <name>] ' +
        '[--width N] [--height N]'
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

// fastlane's SnapshotHelper names files "<device>-<screenName>.png", and the
// device name itself can contain a dash - "iPad Pro 13-inch (M5)" does - so
// splitting on the first dash mangles those into device "iPad Pro 13" and
// screen "inch (M5)-...". Match the known device names from frames.json
// first (longest wins, so a more specific key can't be shadowed) and only
// fall back to the first dash for devices the manifest doesn't cover, such
// as the Apple Watch captures, whose names happen to have no dash.
function splitDeviceAndScreen(baseName, framesManifest) {
  const known = Object.keys(framesManifest)
    .filter((key) => !key.startsWith('_'))
    .sort((a, b) => b.length - a.length);

  for (const device of known) {
    const prefix = `${device}-`;
    if (baseName.startsWith(prefix)) {
      return { deviceName: device, screenName: baseName.slice(prefix.length) };
    }
  }

  const dash = baseName.indexOf('-');
  return dash === -1
    ? { deviceName: baseName, screenName: baseName }
    : { deviceName: baseName.slice(0, dash), screenName: baseName.slice(dash + 1) };
}

// Only iPhone/iPad get the marketing frame treatment; Apple Watch captures
// are always skipped here (framing isn't meaningful at that size, and there
// is no Watch entry in frames.json).
function isFramableDevice(deviceName) {
  return /iphone|ipad/i.test(deviceName);
}

// Reads width/height straight out of a PNG's IHDR chunk (bytes 16-23),
// avoiding a dependency on an image library just to probe frame dimensions.
function readPngDimensions(buffer) {
  const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (buffer.length < 24 || !buffer.subarray(0, 8).equals(PNG_SIGNATURE)) {
    throw new Error('not a valid PNG file (bad signature)');
  }
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20)
  };
}

function escapeHTML(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

// Resolves + caches (per device+color, not per screenshot) the frame image
// and its placement geometry as percentages, so the same numbers work
// whatever vw-based scale the template ends up rendering the frame at.
function resolveFrame(deviceName, colorArg, framesManifest, framesDir, cache) {
  const entry = framesManifest[deviceName];
  if (!entry) {
    console.warn(`[render] No frame configured for device "${deviceName}" in frames.json; skipping.`);
    return null;
  }

  let color = colorArg || entry.defaultColor;
  if (!entry.colors[color]) {
    console.warn(
      `[render] Unknown frame color "${color}" for "${deviceName}"; falling back to "${entry.defaultColor}".`
    );
    color = entry.defaultColor;
  }
  const colorEntry = entry.colors[color];
  if (!colorEntry) {
    console.warn(`[render] No usable frame color for "${deviceName}"; skipping.`);
    return null;
  }

  const cacheKey = `${deviceName}::${color}`;
  if (cache.has(cacheKey)) {
    return cache.get(cacheKey);
  }

  const framePath = path.join(framesDir, colorEntry.file);
  let frameBuffer;
  try {
    frameBuffer = fs.readFileSync(framePath);
  } catch (err) {
    console.warn(`[render] Could not read frame asset "${framePath}": ${err.message}; skipping.`);
    cache.set(cacheKey, null);
    return null;
  }

  let dims;
  try {
    dims = readPngDimensions(frameBuffer);
  } catch (err) {
    console.warn(`[render] Frame asset "${framePath}" is not a readable PNG: ${err.message}; skipping.`);
    cache.set(cacheKey, null);
    return null;
  }

  // The screen box is pinned to the cutout's own measured rectangle rather
  // than left to the raw capture's intrinsic aspect ratio: the screenshot is
  // then clipped to (and fills) exactly the cutout, whatever it was captured
  // at. Corner radii are expressed separately against the box's width and
  // height so the percentages resolve back to one circular radius.
  const radius = entry.screenCornerRadius || 0;
  const resolved = {
    frameSrc: `data:image/png;base64,${frameBuffer.toString('base64')}`,
    leftPct: (colorEntry.offsetX / dims.width) * 100,
    topPct: (colorEntry.offsetY / dims.height) * 100,
    widthPct: (entry.screenshotWidth / dims.width) * 100,
    heightPct: (entry.screenshotHeight / dims.height) * 100,
    radiusXPct: (radius / entry.screenshotWidth) * 100,
    radiusYPct: (radius / entry.screenshotHeight) * 100,
    aspectRatio: `${dims.width} / ${dims.height}`,
    outputWidth: entry.outputWidth,
    outputHeight: entry.outputHeight
  };
  cache.set(cacheKey, resolved);
  return resolved;
}

function fillTemplate(template, { copy, screenshotSrc, frame }) {
  return template
    .replaceAll('{{BADGE}}', escapeHTML(copy.badge || ''))
    .replaceAll('{{TITLE}}', escapeHTML(copy.title || ''))
    .replaceAll('{{TITLE_HIGHLIGHT}}', escapeHTML(copy.titleHighlight || ''))
    .replaceAll('{{SUBTITLE}}', escapeHTML(copy.subtitle || ''))
    .replaceAll('{{CARD_ICON}}', escapeHTML(copy.cardIcon || '✦'))
    .replaceAll('{{CARD_STAT}}', escapeHTML(copy.cardStat || ''))
    .replaceAll('{{CARD_LABEL}}', escapeHTML(copy.cardLabel || ''))
    .replaceAll('{{SCREENSHOT_SRC}}', screenshotSrc)
    .replaceAll('{{FRAME_SRC}}', frame.frameSrc)
    .replaceAll('{{FRAME_ASPECT_RATIO}}', frame.aspectRatio)
    .replaceAll('{{SCREENSHOT_LEFT_PCT}}', frame.leftPct.toFixed(3))
    .replaceAll('{{SCREENSHOT_TOP_PCT}}', frame.topPct.toFixed(3))
    .replaceAll('{{SCREENSHOT_WIDTH_PCT}}', frame.widthPct.toFixed(3))
    .replaceAll('{{SCREENSHOT_HEIGHT_PCT}}', frame.heightPct.toFixed(3))
    .replaceAll('{{SCREEN_RADIUS_X_PCT}}', frame.radiusXPct.toFixed(3))
    .replaceAll('{{SCREEN_RADIUS_Y_PCT}}', frame.radiusYPct.toFixed(3));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!fs.existsSync(args.inputDir)) {
    console.error(`[render] Input directory not found: "${args.inputDir}"`);
    process.exit(1);
  }

  const template = fs.readFileSync(args.templatePath, 'utf8');
  const config = loadJSON(args.configPath, 'config.json');
  const framesManifest = loadJSON(args.framesManifestPath, 'frames.json');

  fs.mkdirSync(args.outputDir, { recursive: true });

  const locales = fs
    .readdirSync(args.inputDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();

  if (locales.length === 0) {
    console.warn(`[render] No locale directories found under "${args.inputDir}". Nothing to render.`);
  }

  // KURN_CHROMIUM_EXECUTABLE lets a preview run reuse a Chromium that is
  // already on the machine (a system package, or one whose build number
  // doesn't match this Playwright release) instead of downloading one. CI
  // leaves it unset and uses `npx playwright install`'s own browser.
  const launchOptions = {};
  if (process.env.KURN_CHROMIUM_EXECUTABLE) {
    launchOptions.executablePath = process.env.KURN_CHROMIUM_EXECUTABLE;
  }
  const browser = await chromium.launch(launchOptions);
  const frameCache = new Map();
  let rendered = 0;
  let skipped = 0;

  try {
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
        const { deviceName, screenName } = splitDeviceAndScreen(baseName, framesManifest);

        if (!isFramableDevice(deviceName)) {
          console.warn(
            `[render] Skipping "${locale}/${file}": no marketing frame treatment for device "${deviceName}" ` +
              '(only iPhone/iPad are framed here).'
          );
          skipped++;
          continue;
        }

        const copy = localeConfig[screenName];
        if (!copy) {
          console.warn(
            `[render] No copy configured for screen "${screenName}" (locale "${locale}") in config.json; skipping.`
          );
          skipped++;
          continue;
        }

        const frame = resolveFrame(deviceName, args.frameColor, framesManifest, args.framesDir, frameCache);
        if (!frame) {
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
          screenshotSrc: `data:image/png;base64,${imageBase64}`,
          frame
        });

        const canvasWidth = frame.outputWidth || args.width;
        const canvasHeight = frame.outputHeight || args.height;
        const page = await browser.newPage({
          viewport: { width: canvasWidth, height: canvasHeight },
          deviceScaleFactor: 1
        });
        try {
          await page.setContent(html, { waitUntil: 'networkidle' });
          // Keep fastlane's own "<device>-<screenName>.png" naming: several
          // devices produce the same screen names, so a device-less filename
          // makes them overwrite each other. It also lets the upload job
          // drop the framed files straight in beside the raw Watch captures.
          const outFile = path.join(localeOutputDir, `${baseName}.png`);
          await page.screenshot({ path: outFile });
          console.log(`[render] Rendered ${locale}/${baseName}.png (${deviceName}, ${canvasWidth}x${canvasHeight})`);
          rendered++;
        } finally {
          await page.close();
        }
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
