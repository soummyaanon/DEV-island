#!/usr/bin/env node
// Safely merge (or remove) Agent Island's Claude Code hooks in a settings.json.
//
//   node merge-claude-settings.mjs install   --settings PATH --url URL --token TOK [--dry-run]
//   node merge-claude-settings.mjs uninstall --settings PATH [--dry-run]
//
// Guarantees:
//  - Never touches keys other than `hooks`.
//  - Never removes or reorders the user's own hooks — only our own handlers,
//    identified by the "/events/claude/" URL fragment.
//  - Idempotent: re-running install replaces our handlers instead of duplicating.
//  - Writes a timestamped backup of the original before modifying it.
//
// Exit codes: 0 ok, 1 usage/error.

import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUR_MARKER = "/events/claude/";
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const opts = { command, settings: null, url: "http://localhost:7433", token: "", dryRun: false };
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (arg === "--dry-run") opts.dryRun = true;
    else if (arg === "--settings") opts.settings = rest[++i];
    else if (arg === "--url") opts.url = rest[++i];
    else if (arg === "--token") opts.token = rest[++i];
    else {
      console.error(`unknown argument: ${arg}`);
      process.exit(1);
    }
  }
  return opts;
}

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function isOurHandler(handler) {
  return (
    handler &&
    handler.type === "http" &&
    typeof handler.url === "string" &&
    handler.url.includes(OUR_MARKER)
  );
}

/** Strip our handlers from a list of matcher-groups, dropping emptied groups. */
function stripOurHandlers(groups) {
  return (Array.isArray(groups) ? groups : [])
    .map((group) => ({
      ...group,
      hooks: (Array.isArray(group.hooks) ? group.hooks : []).filter((h) => !isOurHandler(h)),
    }))
    .filter((group) => group.hooks.length > 0);
}

function loadSettings(path) {
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    fail(`could not parse ${path}: ${err.message}`);
  }
}

function loadTemplate(url, token) {
  const raw = readFileSync(join(SCRIPT_DIR, "claude-hooks.json"), "utf8")
    .replaceAll("{{DAEMON_URL}}", url)
    .replaceAll("{{TOKEN}}", token);
  return JSON.parse(raw);
}

function backup(path) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dest = `${path}.agent-island-bak.${stamp}`;
  copyFileSync(path, dest);
  return dest;
}

function write(path, settings, dryRun) {
  const out = `${JSON.stringify(settings, null, 2)}\n`;
  if (dryRun) {
    console.log("--- dry run: resulting settings.json ---");
    console.log(out);
    return;
  }
  writeFileSync(path, out);
}

function install(opts) {
  if (!opts.settings) fail("--settings is required");
  if (!opts.token) fail("--token is required");

  const settings = loadSettings(opts.settings);
  const template = loadTemplate(opts.url, opts.token);
  settings.hooks = settings.hooks && typeof settings.hooks === "object" ? settings.hooks : {};

  for (const [event, ourGroups] of Object.entries(template)) {
    const preserved = stripOurHandlers(settings.hooks[event]);
    settings.hooks[event] = [...preserved, ...ourGroups];
  }

  if (existsSync(opts.settings) && !opts.dryRun) {
    console.log(`backed up original -> ${backup(opts.settings)}`);
  }
  write(opts.settings, settings, opts.dryRun);
  if (!opts.dryRun) {
    console.log(`installed Agent Island hooks into ${opts.settings}`);
    console.log("restart running 'claude' sessions to pick them up (config is snapshotted at start).");
  }
}

function uninstall(opts) {
  if (!opts.settings) fail("--settings is required");
  if (!existsSync(opts.settings)) {
    console.log(`nothing to do: ${opts.settings} does not exist`);
    return;
  }

  const settings = loadSettings(opts.settings);
  if (!settings.hooks || typeof settings.hooks !== "object") {
    console.log("nothing to do: no hooks block");
    return;
  }

  for (const event of Object.keys(settings.hooks)) {
    const preserved = stripOurHandlers(settings.hooks[event]);
    if (preserved.length > 0) settings.hooks[event] = preserved;
    else delete settings.hooks[event];
  }
  if (Object.keys(settings.hooks).length === 0) delete settings.hooks;

  if (!opts.dryRun) console.log(`backed up original -> ${backup(opts.settings)}`);
  write(opts.settings, settings, opts.dryRun);
  if (!opts.dryRun) console.log(`removed Agent Island hooks from ${opts.settings}`);
}

const opts = parseArgs(process.argv.slice(2));
if (opts.command === "install") install(opts);
else if (opts.command === "uninstall") uninstall(opts);
else fail("first argument must be 'install' or 'uninstall'");
