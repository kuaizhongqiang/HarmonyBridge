#!/usr/bin/env node
/**
 * changelog.mjs -- generate RELEASE_NOTES.md from Conventional Commits.
 *
 * WHY THIS EXISTS (and why not GitHub's generator)
 * -------------------------------------------------
 * `.github/release.yml` configures GitHub's own release-notes generator, but
 * that generator categorises by **pull-request label** and can only list PRs.
 * This repository commits directly to `main`, so a release built from it would
 * come out with an empty changelog. This script reads the commit log instead,
 * which is the only record that actually exists here.
 *
 * It shares the release vocabulary with the pipeline through
 * `scripts/release-metadata.json` (tag pattern, type titles, artifact names):
 * one definition, so the workflow, the local release script and this generator
 * cannot drift apart.
 *
 * USAGE
 *   node scripts/changelog.mjs --tag v0.1.0                      # preview to stdout
 *   node scripts/changelog.mjs --tag v0.1.0 --output RELEASE_NOTES.md
 *   node scripts/changelog.mjs --tag v0.1.0 --validate-only      # version gate only
 *   node scripts/changelog.mjs --tag v0.1.0 --from v0.0.9 --to HEAD
 *
 * EXIT CODES  0 ok | 1 a check failed | 2 the script could not run
 *
 * Zero dependencies: Node standard library only. This repository has no
 * package.json and is not going to grow one for a changelog.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..');
const METADATA_PATH = join(HERE, 'release-metadata.json');
const FOOTER_PATH = join(HERE, 'release-notes-footer.md');

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const out = { tag: '', from: '', to: 'HEAD', output: '', validateOnly: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (value === undefined) fail(`missing value for ${arg}`, 2);
      return value;
    };
    switch (arg) {
      case '--tag': out.tag = next(); break;
      case '--from': out.from = next(); break;
      case '--to': out.to = next(); break;
      case '--output': out.output = next(); break;
      case '--validate-only': out.validateOnly = true; break;
      case '--help': case '-h': out.help = true; break;
      default: fail(`unknown argument: ${arg}`, 2);
    }
  }
  return out;
}

function fail(message, code) {
  process.stderr.write(`changelog: ${message}\n`);
  process.exit(code ?? 1);
}

function warn(message) {
  process.stderr.write(`changelog: warning: ${message}\n`);
}

// ---------------------------------------------------------------------------
// git helpers
// ---------------------------------------------------------------------------
function git(args, { optional = false } = {}) {
  try {
    return execFileSync('git', args, { cwd: REPO_ROOT, encoding: 'utf8' }).trim();
  } catch (error) {
    if (optional) return '';
    const detail = (error.stderr || error.message || '').toString().trim();
    fail(`git ${args.join(' ')} failed: ${detail}`, 2);
  }
}

/** All tags matching the configured pattern, newest first by semver precedence. */
function listTags(pattern) {
  const raw = git(['tag', '--list', pattern, '--sort=-v:refname'], { optional: true });
  if (!raw) return [];
  return raw.split('\n').map((line) => line.trim()).filter(Boolean);
}

// ---------------------------------------------------------------------------
// Conventional Commit parsing
// ---------------------------------------------------------------------------
const COMMIT_RE = /^(?<type>[a-zA-Z]+)(?:\((?<scope>[^()]*)\))?(?<bang>!)?:\s*(?<subject>.+)$/;

function parseCommit(subject) {
  const match = COMMIT_RE.exec(subject.trim());
  if (!match || !match.groups) return undefined;
  return {
    type: match.groups.type.toLowerCase(),
    scope: (match.groups.scope || '').trim(),
    bang: Boolean(match.groups.bang),
    subject: match.groups.subject.trim(),
  };
}

function collectCommits(range) {
  if (!range) return [];
  // Unit separator between fields, record separator between commits: commit
  // subjects are free text and may contain anything except these.
  const raw = git(['log', '--no-merges', '--format=%H%x1f%s%x1f%b%x1e', range], { optional: true });
  if (!raw) return [];

  const commits = [];
  for (const record of raw.split('\x1e')) {
    const trimmed = record.trim();
    if (!trimmed) continue;
    const [hash, subject, body = ''] = trimmed.split('\x1f');
    if (!hash || !subject) continue;
    commits.push({ hash: hash.trim(), subject, body });
  }
  return commits;
}

// ---------------------------------------------------------------------------
// Version gate
// ---------------------------------------------------------------------------
function readManifestVersion(metadata) {
  const path = join(REPO_ROOT, metadata.version.manifest);
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (error) {
    fail(`cannot read ${metadata.version.manifest}: ${error.message}`, 2);
  }
  const match = /"versionName"\s*:\s*"([^"]+)"/.exec(text);
  if (!match) fail(`versionName not found in ${metadata.version.manifest}`, 2);
  return match[1];
}

function validateVersion(tag, metadata) {
  const pattern = new RegExp(metadata.version.tagPattern);
  if (!pattern.test(tag)) {
    fail(`tag '${tag}' does not match ${metadata.version.tagPattern} (expected e.g. v1.2.3)`, 1);
  }
  const stripped = tag.startsWith(metadata.version.tagPrefix)
    ? tag.slice(metadata.version.tagPrefix.length)
    : tag;
  const manifestVersion = readManifestVersion(metadata);
  if (stripped !== manifestVersion) {
    fail(
      `tag ${tag} says ${stripped} but ${metadata.version.manifest} versionName is ` +
        `${manifestVersion}. ${metadata.version.agreementRule}`,
      1
    );
  }
  return { stripped, manifestVersion };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
function renderSection(title, entries) {
  const lines = [`### ${title}`, ''];
  for (const entry of entries) {
    const scope = entry.scope ? `**${entry.scope}**: ` : '';
    const short = entry.hash.slice(0, 7);
    lines.push(`- ${scope}${entry.subject} (\`${short}\`)`);
  }
  lines.push('');
  return lines.join('\n');
}

function renderNotes({ tag, previousTag, metadata, commits }) {
  const lines = [];
  lines.push(`# ${tag}`, '');

  if (previousTag) {
    lines.push(`变更范围：\`${previousTag}\` → \`${tag}\``);
  } else {
    lines.push(`首个版本（${metadata.changelog.unknownRefFallback}）。`);
  }
  lines.push('');

  const parsed = [];
  const unparsed = [];
  for (const commit of commits) {
    const conventional = parseCommit(commit.subject);
    if (conventional) {
      parsed.push({ ...commit, ...conventional });
    } else {
      unparsed.push(commit);
    }
  }

  // Breaking changes first: a caret-typed `feat!:` or a BREAKING CHANGE footer.
  const breaking = parsed.filter(
    (c) => c.bang || /^BREAKING[ -]CHANGE:/m.test(c.body || '')
  );
  if (breaking.length > 0) {
    lines.push(renderSection('⚠️ 破坏性变更', breaking));
  }

  const byType = new Map();
  for (const commit of parsed) {
    if (!byType.has(commit.type)) byType.set(commit.type, []);
    byType.get(commit.type).push(commit);
  }

  const orderedTypes = [
    ...metadata.changelog.types.filter((type) => byType.has(type)),
    ...[...byType.keys()].filter((type) => !metadata.changelog.types.includes(type)),
  ];

  for (const type of orderedTypes) {
    const title = metadata.changelog.titles[type] ?? `${type}（未分类类型）`;
    lines.push(renderSection(title, byType.get(type)));
  }

  if (unparsed.length > 0) {
    // Not hidden and not silently dropped: a non-conventional subject is a real
    // finding (the commit-msg hook exists precisely to prevent these), so it is
    // listed rather than swept into "其他变更".
    const items = unparsed.map((c) => ({ ...c, scope: '', subject: c.subject }));
    lines.push(renderSection('❓ 非规范提交（应修正）', items));
  }

  if (commits.length === 0) {
    lines.push('_本区间没有非合并提交。_', '');
  }

  return lines.join('\n');
}

function readFooter() {
  try {
    return readFileSync(FOOTER_PATH, 'utf8').trim();
  } catch {
    return '';
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    process.stdout.write(
      'usage: node scripts/changelog.mjs --tag v1.2.3 [--from TAG] [--to REF]\n' +
        '                                   [--output FILE] [--validate-only]\n'
    );
    return;
  }

  let metadata;
  try {
    metadata = JSON.parse(readFileSync(METADATA_PATH, 'utf8'));
  } catch (error) {
    fail(`cannot read ${METADATA_PATH}: ${error.message}`, 2);
  }

  let tag = args.tag;
  if (!tag) {
    // Fall back to the manifest so a bare invocation still does something
    // useful, and say so rather than guessing silently.
    const version = readManifestVersion(metadata);
    tag = `${metadata.version.tagPrefix}${version}`;
    warn(`no --tag given; deriving from the manifest: ${tag}`);
  }

  validateVersion(tag, metadata);

  if (args.validateOnly) {
    process.stdout.write(`changelog: ${tag} matches ${metadata.version.manifest}\n`);
    return;
  }

  const tags = listTags(`${metadata.version.tagPrefix}*`);
  const previousTag =
    args.from ||
    tags.find((candidate) => candidate !== tag) ||
    '';

  const range = previousTag ? `${previousTag}..${args.to}` : args.to;
  const commits = collectCommits(range);

  if (previousTag === '' && commits.length === 0) {
    warn(`no commits found for range '${range}'`);
  }

  let markdown = renderNotes({ tag, previousTag, metadata, commits });
  const footer = readFooter();
  if (footer) {
    markdown += `\n---\n\n${footer}\n`;
  }

  if (args.output) {
    const target = resolve(REPO_ROOT, args.output);
    writeFileSync(target, markdown, 'utf8');
    process.stdout.write(
      `changelog: wrote ${args.output} (${commits.length} commits, ` +
        `${previousTag ? `previous tag ${previousTag}` : 'first release'})\n`
    );
  } else {
    process.stdout.write(markdown);
  }
}

main();
