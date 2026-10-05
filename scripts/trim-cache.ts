/**
 * `bun scripts/trim-cache.ts <dir> <limitGB>`: drops the least recently used files until the
 * directory fits the limit. Bazel's disk cache grows without bound and GitHub rejects a cache entry
 * over 10 GB, so CI trims it before saving.
 */
import { existsSync, readdirSync, rmSync, statSync } from "node:fs";

interface Entry {
  readonly path: string;
  readonly size: number;
  readonly atime: number;
}

function files(directory: string): Entry[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) return files(path);
    if (!entry.isFile()) return [];
    const stat = statSync(path);
    return [{ path, size: stat.size, atime: stat.atimeMs }];
  });
}

const [directory, limitGB] = process.argv.slice(2);
if (!directory || !limitGB) throw new Error("usage: trim-cache.ts <dir> <limitGB>");
if (!existsSync(directory)) {
  console.log(`${directory} does not exist, nothing to trim`);
  process.exit(0);
}

const limit = Number(limitGB) * 1024 ** 3;
const entries = files(directory).sort((a, b) => a.atime - b.atime);
let total = entries.reduce((sum, entry) => sum + entry.size, 0);
const before = total;
let removed = 0;
for (const entry of entries) {
  if (total <= limit) break;
  rmSync(entry.path, { force: true });
  total -= entry.size;
  removed++;
}
const gb = (bytes: number) => (bytes / 1024 ** 3).toFixed(1);
console.log(`${directory}: ${gb(before)} GB → ${gb(total)} GB (${removed} files dropped, limit ${limitGB} GB)`);
