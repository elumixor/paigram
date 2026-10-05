/**
 * `bun run tag [--minor] [--dry-run]`: bump versions.json, commit it, tag it `ios-vX.Y.Z` and push. The tag
 * is what the TestFlight workflow waits for, so this is the whole release from any machine — no Xcode,
 * no Mac. Everything the build needs lives in the repo's GitHub secrets.
 *
 * What gets built is what the tag points at, so the tree must be what is committed and pushed. On the box
 * the files arrive by sync while its `.git` is its own and lags behind: when the files already match
 * origin, its HEAD is moved there first (the files stay as they are). Submodules are left out of every
 * check — the synced tree's submodule links point into the Mac's `.git`.
 */
import { $ } from "bun";
import { bumpVersion, readVersions, root } from "./repo.ts";

const dryRun = process.argv.includes("--dry-run");
const git = (args: string[]) => $`git ${args}`.cwd(root).quiet();

await git(["fetch", "-q", "origin"]);
const branch = (await git(["rev-parse", "--abbrev-ref", "HEAD"]).text()).trim();
const upstream = `origin/${branch === "HEAD" ? "master" : branch}`;
const dirty = async () =>
  (await $`git diff --quiet --ignore-submodules=all HEAD --`.cwd(root).nothrow().quiet()).exitCode !== 0 ||
  (await git(["ls-files", "--others", "--exclude-standard", "--", "scripts", "submodules/PaiUI", "Telegram", "versions.json"]).text()).trim() !== "";

const behind = Number((await git(["rev-list", "--count", `HEAD..${upstream}`]).text()).trim());
if (behind > 0) {
  // The index moves with HEAD (the files stay), so the comparison sees every file origin has.
  const before = (await git(["rev-parse", "HEAD"]).text()).trim();
  await git(["reset", "-q", upstream]);
  const differs = await dirty();
  if (differs || dryRun) await git(["reset", "-q", before]);
  if (differs) throw new Error(`HEAD is ${behind} behind ${upstream} and the files differ from it too: commit and push from where the work was done first`);
  console.log(`HEAD was ${behind} behind ${upstream}; the files match it, so HEAD moves there`);
} else if (await dirty()) {
  throw new Error("uncommitted changes: what is not committed and pushed would not be in the build");
}
const ahead = Number((await git(["rev-list", "--count", `${upstream}..HEAD`]).text()).trim());
if (ahead > 0) console.log(`${ahead} local commit(s) go out with the tag`);

if (dryRun) {
  console.log(`ready: the next release is the one after ${(await readVersions()).app}`);
  process.exit(0);
}

const version = await bumpVersion(process.argv.includes("--minor"));
const tag = `ios-v${version}`;
// Annotated: `--follow-tags` leaves lightweight tags behind.
await git(["tag", "-a", tag, "-m", `Paigram v${version}`]);
await git(["push", "-q", "--follow-tags", "origin", `HEAD:${branch === "HEAD" ? "master" : branch}`]);
console.log(`pushed ${tag}; the TestFlight workflow builds and uploads it`);
