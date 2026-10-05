/**
 * `bun run tag [--minor]`: bump versions.json, commit it, tag it `ios-vX.Y.Z` and push. The tag is
 * what the TestFlight workflow waits for, so this is the whole release from any machine — no Xcode,
 * no Mac. Everything the build needs lives in the repo's GitHub secrets.
 */
import { $ } from "bun";
import { bumpVersion, root } from "./repo.ts";

const status = await $`git status --porcelain -- versions.json`.cwd(root).text();
if (status.trim()) throw new Error("versions.json has uncommitted changes; commit or discard them first");

const version = await bumpVersion(process.argv.includes("--minor"));
const tag = `ios-v${version}`;
// Annotated: `--follow-tags` leaves lightweight tags behind.
await $`git tag -a ${tag} -m ${`Paigram v${version}`}`.cwd(root);
await $`git push --follow-tags`.cwd(root);
console.log(`pushed ${tag}; the TestFlight workflow builds and uploads it`);
