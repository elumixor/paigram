/** The repository's own paths and the one file that says which version is being built. */
import { $ } from "bun";

export const root = new URL("..", import.meta.url).pathname;
export const configPath = `${root}build-system/paigram.json`;
export const exampleConfigPath = `${root}build-system/paigram.example.json`;
export const codesigningPath = `${root}build-system/paigram-codesigning`;
export const secretsPath = `${root}submodules/PaiUI/Sources/PaiSecrets.swift`;
const versionsPath = `${root}versions.json`;

export interface Versions {
  /** versions.json also pins bazel, macos and the deploy Xcode; they are carried through untouched on a bump. */
  readonly [key: string]: string;
  readonly app: string;
  readonly xcode: string;
}

export const readVersions = () => Bun.file(versionsPath).json() as Promise<Versions>;

/** Every release is a new patch (or minor) version recorded in versions.json and committed, so TestFlight tells builds apart. */
export async function bumpVersion(minor: boolean): Promise<string> {
  const versions = await readVersions();
  const [major, min, patch] = versions.app.split(".").map(Number);
  const app = minor ? `${major}.${min + 1}.0` : `${major}.${min}.${patch + 1}`;
  await Bun.write(versionsPath, `${JSON.stringify({ ...versions, app }, null, 4)}\n`);
  await $`git commit -qm ${`Paigram v${app}`} -- versions.json`.cwd(root);
  console.log(`version ${app}`);
  return app;
}
