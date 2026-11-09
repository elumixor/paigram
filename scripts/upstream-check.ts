/**
 * Says whether Telegram-iOS has a release newer than the one merged into this branch.
 * Exits 1 when there is one, so CI can act on it; `--quiet` prints only the tag.
 */
import { $ } from "bun";
import { appendFile } from "node:fs/promises";
import { root } from "./repo";

const upstreamUrl = "https://github.com/TelegramMessenger/Telegram-iOS.git";
const quiet = process.argv.includes("--quiet");
const git = (...args: string[]) => $`git ${args}`.cwd(root).quiet().nothrow();

if ((await git("remote", "get-url", "upstream")).exitCode !== 0) {
  await git("remote", "add", "upstream", upstreamUrl);
}
// Upstream marks each release with a `release-X.Y[.Z]` tag on master.
const fetched = await git("fetch", "--quiet", "--no-tags", "upstream", "master", "+refs/tags/release-*:refs/tags/release-*");
if (fetched.exitCode !== 0) {
  console.error(fetched.stderr.toString());
  process.exit(2);
}

const tags = (await git("tag", "--list", "release-*", "--sort=-v:refname")).stdout.toString().split("\n").filter(Boolean);
let current = "none";
for (const tag of tags) {
  if ((await git("merge-base", "--is-ancestor", tag, "HEAD")).exitCode === 0) {
    current = tag;
    break;
  }
}
const latest = tags[0];
const behind = Number((await git("rev-list", "--count", "HEAD..upstream/master")).stdout.toString().trim());
const pending = latest !== undefined && latest !== current;

if (process.env.GITHUB_OUTPUT) {
  await appendFile(process.env.GITHUB_OUTPUT, `latest=${latest ?? ""}\ncurrent=${current}\nbehind=${behind}\npending=${pending}\n`);
}
if (quiet) {
  if (pending) console.log(latest);
} else {
  console.log(`merged ${current}, latest ${latest ?? "none"}, ${behind} upstream/master commits not merged`);
  if (pending) console.log(`new release: git merge ${latest} on a branch upstream-${latest.replace("release-", "")} (see PAIGRAM.md, Upstream)`);
}
process.exit(pending ? 1 : 0);
