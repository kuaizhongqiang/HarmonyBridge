#!/usr/bin/env node
/**
 * JSON5 / JSON syntax validation for the HarmonyOS project manifests.
 *
 * Why this exists: `hvigor` only tells you a manifest is broken when you run a
 * full build, which needs DevEco Studio installed. A small hand-rolled JSON5
 * tokenizer lets plain `node` (which every developer and every ubuntu-latest
 * runner already has) parse the manifests in milliseconds and fail the PR with
 * a file:line:column instead of a wall of hvigor output.
 *
 * It is a *syntax* checker plus a handful of cross-file invariants that are
 * worth failing a build over; it is not a schema validator.
 *
 * Usage:
 *   node scripts/validate-json5.mjs                    # validate the known manifests
 *   node scripts/validate-json5.mjs path/a.json5 ...   # validate specific files
 *   node scripts/validate-json5.mjs --quiet f.json5
 *   node scripts/validate-json5.mjs --json
 *
 * Exit codes: 0 = all files parsed and sane, 1 = at least one failure, 2 = usage error.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..');

/** The manifests this project actually owns. Paths are repo-relative. */
export const DEFAULT_TARGETS = [
  'build-profile.json5',
  'oh-package.json5',
  'AppScope/app.json5',
  'entry/build-profile.json5',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/ohosTest/module.json5',
  'entry/src/mock/mock-config.json5',
  'code-linter.json5',
  'hvigor/hvigor-config.json5',
];

/** Directories that are generated or vendored, and must never be validated. */
const EXCLUDED_SEGMENTS = new Set([
  'node_modules',
  'oh_modules',
  'build',
  '.hvigor',
  '.idea',
  '.preview',
  'third_party',
]);

// ---------------------------------------------------------------------------
// JSON5 tokenizer / parser
// ---------------------------------------------------------------------------

export class Json5SyntaxError extends Error {
  constructor(message, line, column) {
    super(`${message} (line ${line}, column ${column})`);
    this.name = 'Json5SyntaxError';
    this.line = line;
    this.column = column;
  }
}

const WHITESPACE = new Set([' ', '\t', '\n', '\r', '\u000b', '\f', '\u00a0', '\ufeff', '\u2028', '\u2029']);
const IDENT_START = /[A-Za-z_$\u00aa-\uffdc]/;
const IDENT_PART = /[A-Za-z0-9_$\u00aa-\uffdc]/;
const DIGIT = /[0-9]/;
const HEX_DIGIT = /[0-9A-Fa-f]/;
const ESCAPES = { b: '\b', f: '\f', n: '\n', r: '\r', t: '\t', v: '\v', '0': '\0' };

class Parser {
  constructor(text) {
    this.text = text;
    this.pos = 0;
  }

  line() {
    let line = 1;
    for (let i = 0; i < this.pos && i < this.text.length; i += 1) {
      if (this.text.charCodeAt(i) === 10) line += 1;
    }
    return line;
  }

  column() {
    const lastNewline = this.text.slice(0, this.pos).lastIndexOf('\n');
    return this.pos - lastNewline;
  }

  fail(message) {
    throw new Json5SyntaxError(message, this.line(), this.column());
  }

  peek(offset = 0) {
    return this.text[this.pos + offset];
  }

  next() {
    const ch = this.text[this.pos];
    this.pos += 1;
    return ch;
  }

  eof() {
    return this.pos >= this.text.length;
  }

  /** Advance past whitespace, comments, and JSON5 trailing commas. */
  skipIgnorable() {
    for (;;) {
      const ch = this.peek();
      if (ch === undefined) return;
      if (WHITESPACE.has(ch)) {
        this.pos += 1;
        continue;
      }
      if (ch === '/' && this.peek(1) === '/') {
        while (!this.eof() && this.peek() !== '\n') this.pos += 1;
        continue;
      }
      if (ch === '/' && this.peek(1) === '*') {
        this.pos += 2;
        if (this.text.indexOf('*/', this.pos) === -1) this.fail('unterminated block comment');
        this.pos = this.text.indexOf('*/', this.pos) + 2;
        continue;
      }
      if (ch === ',') {
        // JSON5 allows a trailing comma: drop it when the next significant
        // character closes the current object or array.
        const probeEnd = this.probeAfterIgnorable(this.pos + 1);
        const probeChar = this.text[probeEnd];
        if (probeChar === '}' || probeChar === ']') {
          this.pos += 1;
          continue;
        }
      }
      return;
    }
  }

  /** Index of the next significant character at or after `from`. */
  probeAfterIgnorable(from) {
    let i = from;
    for (;;) {
      const ch = this.text[i];
      if (ch === undefined) return i;
      if (WHITESPACE.has(ch)) {
        i += 1;
        continue;
      }
      if (ch === '/' && this.text[i + 1] === '/') {
        while (i < this.text.length && this.text[i] !== '\n') i += 1;
        continue;
      }
      if (ch === '/' && this.text[i + 1] === '*') {
        i += 2;
        const end = this.text.indexOf('*/', i);
        i = end === -1 ? this.text.length : end + 2;
        continue;
      }
      return i;
    }
  }

  parse() {
    this.skipIgnorable();
    const value = this.parseValue();
    this.skipIgnorable();
    if (!this.eof()) this.fail(`unexpected trailing content: ${JSON.stringify(this.text.slice(this.pos, this.pos + 20))}`);
    return value;
  }

  parseValue() {
    this.skipIgnorable();
    if (this.eof()) this.fail('unexpected end of input, expected a value');
    const ch = this.peek();
    if (ch === '{') return this.parseObject();
    if (ch === '[') return this.parseArray();
    if (ch === '"' || ch === "'") return this.parseString();
    if (ch === '-' || ch === '+' || ch === '.' || DIGIT.test(ch)) return this.parseNumber();
    if (this.text.startsWith('true', this.pos)) {
      this.pos += 4;
      return true;
    }
    if (this.text.startsWith('false', this.pos)) {
      this.pos += 5;
      return false;
    }
    if (this.text.startsWith('Infinity', this.pos)) {
      this.pos += 8;
      return Infinity;
    }
    if (this.text.startsWith('NaN', this.pos)) {
      this.pos += 3;
      return NaN;
    }
    if (this.text.startsWith('null', this.pos)) {
      this.pos += 4;
      return null;
    }
    this.fail(`unexpected character ${JSON.stringify(ch)}`);
    return undefined;
  }

  parseObject() {
    this.pos += 1; // consume '{'
    const result = {};
    for (;;) {
      this.skipIgnorable();
      if (this.eof()) this.fail('unterminated object');
      if (this.peek() === '}') {
        this.pos += 1;
        return result;
      }
      const key = this.parseKey();
      this.skipIgnorable();
      if (this.peek() !== ':') this.fail(`expected ':' after object key ${JSON.stringify(key)}`);
      this.pos += 1;
      result[key] = this.parseValue();
      this.skipIgnorable();
      if (this.peek() === ',') {
        this.pos += 1;
        continue;
      }
      if (this.peek() === '}') {
        this.pos += 1;
        return result;
      }
      this.fail(`expected ',' or '}' in object, found ${JSON.stringify(this.peek())}`);
    }
  }

  parseKey() {
    const ch = this.peek();
    if (ch === '"' || ch === "'") return this.parseString();
    if (!IDENT_START.test(ch)) this.fail(`invalid object key starting with ${JSON.stringify(ch)}`);
    let key = '';
    while (!this.eof() && IDENT_PART.test(this.peek())) key += this.next();
    return key;
  }

  parseArray() {
    this.pos += 1; // consume '['
    const result = [];
    for (;;) {
      this.skipIgnorable();
      if (this.eof()) this.fail('unterminated array');
      if (this.peek() === ']') {
        this.pos += 1;
        return result;
      }
      result.push(this.parseValue());
      this.skipIgnorable();
      if (this.peek() === ',') {
        this.pos += 1;
        continue;
      }
      if (this.peek() === ']') {
        this.pos += 1;
        return result;
      }
      this.fail(`expected ',' or ']' in array, found ${JSON.stringify(this.peek())}`);
    }
  }

  parseString() {
    const quote = this.next();
    let value = '';
    for (;;) {
      if (this.eof()) this.fail('unterminated string');
      const ch = this.next();
      if (ch === quote) return value;
      if (ch === '\\') {
        const esc = this.next();
        if (esc === undefined) this.fail('unterminated escape sequence');
        if (esc === 'u' || esc === 'x') {
          const width = esc === 'u' ? 4 : 2;
          let hex = '';
          for (let i = 0; i < width; i += 1) {
            const digit = this.next();
            if (!HEX_DIGIT.test(digit || '')) this.fail(`invalid \\${esc} escape ${JSON.stringify(hex + (digit || ''))}`);
            hex += digit;
          }
          value += String.fromCharCode(parseInt(hex, 16));
          continue;
        }
        if (esc === '\n') continue; // line continuation
        if (Object.prototype.hasOwnProperty.call(ESCAPES, esc)) {
          value += ESCAPES[esc];
          continue;
        }
        value += esc;
        continue;
      }
      if (ch === '\n') this.fail('unescaped newline in string');
      value += ch;
    }
  }

  parseNumber() {
    const start = this.pos;
    if (this.peek() === '+' || this.peek() === '-') this.pos += 1;
    if (this.text.startsWith('Infinity', this.pos)) this.pos += 8;
    if (this.text.startsWith('NaN', this.pos)) this.pos += 3;
    while (!this.eof()) {
      const ch = this.peek();
      if (DIGIT.test(ch) || ch === '.' || ch === 'e' || ch === 'E' || ch === 'x' || ch === 'X' || ch === '+' || ch === '-') {
        this.pos += 1;
        continue;
      }
      break;
    }
    const raw = this.text.slice(start, this.pos).replace(/^\+/, '');
    if (raw === '' || raw === '-' || raw === '+') this.fail(`invalid number ${JSON.stringify(raw)}`);
    if (/^0[xX][0-9A-Fa-f]+$/.test(raw)) return parseInt(raw, 16);
    if (raw === 'Infinity' || raw === '-Infinity') return raw.startsWith('-') ? -Infinity : Infinity;
    if (raw === 'NaN' || raw === '-NaN') return NaN;
    if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(raw)) this.fail(`invalid number ${JSON.stringify(raw)}`);
    return Number(raw);
  }
}

/** Parse a JSON5 document, throwing Json5SyntaxError with line/column info. */
export function parseJson5(text) {
  return new Parser(text).parse();
}

// ---------------------------------------------------------------------------
// Cross-file invariants
// ---------------------------------------------------------------------------

function checkSemantics(files) {
  const problems = [];
  const record = (file, message) => problems.push({ file, message });

  const rootProfile = files.get('build-profile.json5');
  const appScope = files.get('AppScope/app.json5');
  const rootPackage = files.get('oh-package.json5');

  const productNames = new Set();

  if (rootProfile) {
    if (rootProfile === null || typeof rootProfile !== 'object' || Array.isArray(rootProfile)) {
      record('build-profile.json5', 'the document root must be an object');
    } else {
      const products = rootProfile.app && rootProfile.app.products;
      if (!Array.isArray(products) || products.length === 0) {
        record('build-profile.json5', 'app.products must be a non-empty array');
      } else {
        for (const product of products) {
          if (!product || typeof product.name !== 'string') {
            record('build-profile.json5', 'every app.products entry needs a string "name"');
            continue;
          }
          if (productNames.has(product.name)) record('build-profile.json5', `duplicate product name "${product.name}"`);
          productNames.add(product.name);
          if (typeof product.compatibleSdkVersion === 'undefined' && typeof product.targetSdkVersion === 'undefined') {
            record('build-profile.json5', `product "${product.name}" declares neither compatibleSdkVersion nor targetSdkVersion`);
          }
        }
      }

      const modules = rootProfile.modules;
      if (!Array.isArray(modules) || modules.length === 0) {
        record('build-profile.json5', 'modules must be a non-empty array');
      } else {
        for (const mod of modules) {
          if (!mod || typeof mod.name !== 'string') {
            record('build-profile.json5', 'every modules entry needs a string "name"');
            continue;
          }
          if (typeof mod.srcPath !== 'string') {
            record('build-profile.json5', `module "${mod.name}" has no "srcPath"`);
            continue;
          }
          const moduleProfilePath = `${mod.srcPath.replace(/^\.\//, '')}/build-profile.json5`;
          if (!files.has(moduleProfilePath)) {
            record('build-profile.json5', `module "${mod.name}" points at ${mod.srcPath} but ${moduleProfilePath} is missing`);
          }
          for (const target of mod.targets || []) {
            for (const product of (target && target.applyToProducts) || []) {
              if (!productNames.has(product)) {
                record('build-profile.json5', `module "${mod.name}" target "${target && target.name}" applies to unknown product "${product}"`);
              }
            }
          }
        }
      }
    }
  }

  if (appScope) {
    if (!appScope.app || typeof appScope.app.bundleName !== 'string' || appScope.app.bundleName.length === 0) {
      record('AppScope/app.json5', 'app.bundleName must be a non-empty string');
    }
    if (rootProfile && appScope.app && (typeof appScope.app.versionName !== 'string' || appScope.app.versionName.length === 0)) {
      record('AppScope/app.json5', 'app.versionName must be a non-empty string (the release workflow reads it)');
    }
  }

  if (rootPackage) {
    // The workspace root oh-package.json5 legitimately carries only
    // modelVersion/description/dependencies, so only check the fields that are
    // present -- an optional-but-wrong type is still a mistake.
    for (const field of ['name', 'version', 'modelVersion']) {
      if (typeof rootPackage[field] !== 'undefined' && typeof rootPackage[field] !== 'string') {
        record('oh-package.json5', `${field} must be a string when present`);
      }
    }
  }

  // Every module.json5 under a declared module must live inside that module's
  // srcPath. entry/src/main/module.json5 and entry/src/ohosTest/module.json5
  // both belong to the "entry" module, whose srcPath is ./entry.
  if (rootProfile && Array.isArray(rootProfile.modules)) {
    const declaredSrcPaths = rootProfile.modules
      .map((m) => (m && typeof m.srcPath === 'string' ? m.srcPath.replace(/^\.\//, '').replace(/\/+$/, '') : null))
      .filter(Boolean);
    for (const file of files.keys()) {
      if (!file.endsWith('module.json5')) continue;
      const insideDeclaredModule = declaredSrcPaths.some((src) => file === `${src}/module.json5` || file.startsWith(`${src}/`));
      if (!insideDeclaredModule) {
        record(file, `not inside any build-profile.json5 modules[].srcPath (declared: ${declaredSrcPaths.join(', ') || 'none'})`);
      }
    }
  }

  return problems;
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

export function run(argv) {
  let quiet = false;
  let asJson = false;
  const explicit = [];

  for (const arg of argv) {
    if (arg === '--quiet') quiet = true;
    else if (arg === '--json') asJson = true;
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write('usage: node scripts/validate-json5.mjs [--quiet] [--json] [file ...]\n');
      return 0;
    } else if (arg.startsWith('-')) {
      process.stderr.write(`validate-json5: unknown option ${arg}\n`);
      return 2;
    } else {
      explicit.push(arg);
    }
  }

  const targets = explicit.length > 0 ? explicit : DEFAULT_TARGETS;
  const files = new Map();
  const results = [];

  for (const target of targets) {
    const abs = path.isAbsolute(target) ? target : path.join(REPO_ROOT, target);
    const rel = path.relative(REPO_ROOT, abs).split(path.sep).join('/');

    if (rel.split('/').some((segment) => EXCLUDED_SEGMENTS.has(segment))) {
      results.push({ file: rel, status: 'skip', message: 'excluded (generated or vendored)' });
      continue;
    }
    if (!fs.existsSync(abs)) {
      // Only an explicitly requested file is required to exist; the built-in
      // list is a superset and may legitimately name not-yet-created files.
      const status = explicit.length > 0 ? 'fail' : 'skip';
      results.push({ file: rel, status, message: 'file does not exist' });
      continue;
    }

    const text = fs.readFileSync(abs, 'utf8');
    try {
      files.set(rel, parseJson5(text));
      results.push({ file: rel, status: 'ok', message: `${text.split('\n').length} lines` });
    } catch (error) {
      results.push({ file: rel, status: 'fail', message: error.message });
    }
  }

  const semanticProblems = checkSemantics(files);
  const semanticFiles = new Set(semanticProblems.map((p) => p.file));

  const failed = results.filter((r) => r.status === 'fail');
  const passed = results.filter((r) => r.status === 'ok');
  const skipped = results.filter((r) => r.status === 'skip');
  const clean = failed.length === 0 && semanticProblems.length === 0;

  if (asJson) {
    process.stdout.write(
      `${JSON.stringify(
        {
          repoRoot: REPO_ROOT,
          checked: passed.length,
          failed: failed.length,
          skipped: skipped.length,
          results,
          semanticProblems,
        },
        null,
        2,
      )}\n`,
    );
  } else {
    if (!quiet) process.stdout.write('\n  validate-json5: JSON/JSON5 syntax + manifest sanity\n');
    for (const result of results) {
      if (quiet && result.status === 'ok') continue;
      const label = result.status === 'ok' ? '[ OK ]' : result.status === 'skip' ? '[SKIP]' : '[FAIL]';
      process.stdout.write(`  ${label} ${result.file}  -- ${result.message}\n`);
    }
    if (semanticProblems.length > 0) {
      process.stdout.write('\n  semantic problems:\n');
      for (const problem of semanticProblems) process.stdout.write(`    - ${problem.file}: ${problem.message}\n`);
    }
    process.stdout.write(
      `\n  ${passed.length} parsed, ${failed.length} syntax failure(s), ${semanticFiles.size} manifest(s) with semantic problems, ${skipped.length} skipped\n`,
    );
    process.stdout.write(clean ? '  VERDICT: PASS\n\n' : '  VERDICT: FAIL\n\n');
  }

  return clean ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = run(process.argv.slice(2));
}
