/**
 * `bun run watch-icon`: render the watch app icon from the iPhone's `Telegram.icon`, so the two never drift.
 * The watch build takes a flat 1024px PNG: Icon Composer's watchOS rendition is a circle with a glass rim and
 * transparent corners, so it is rendered larger, cropped inside the rim and laid on the icon's own gradient.
 * Needs Xcode's `ictool` and ImageMagick (`brew install imagemagick`).
 */
import { $ } from "bun";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { root } from "./repo.ts";

const ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool";
const icon = `${root}Telegram/Telegram-iOS/Telegram.icon`;
const output = `${root}Telegram/Telegram-iOS/WatchAppIcon.png`;
const size = 1024;
const renderSize = 1100;

const dir = mkdtempSync(`${tmpdir()}/watch-icon-`);
const render = `${dir}/render.png`;
const background = `${dir}/background.png`;

const fill = (await Bun.file(`${icon}/icon.json`).json()).fill["linear-gradient"] as string[];
const [top, bottom] = fill.map((color) => {
  const [r, g, b] = color.split(":")[1]!.split(",").map((c) => Math.round(Number(c) * 255));
  return `rgb(${r},${g},${b})`;
});

await $`${ictool} ${icon} --export-image --output-file ${render} --platform watchOS --rendition Default --width ${renderSize} --height ${renderSize} --scale 1`.quiet();
await $`magick -size ${size}x${size} gradient:${top}-${bottom} ${background}`;
await $`magick ${background} ${"("} ${render} -gravity center -crop ${size}x${size}+0+0 +repage ${")"} -composite -alpha off -strip ${output}`;
console.log(output);
