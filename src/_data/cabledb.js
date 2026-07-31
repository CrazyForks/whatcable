// Loads the generated cable dataset for the /cables page.
//
// The list comes from docs/cables.json (written by
// scripts/build-cable-db.swift, which runs before Eleventy in
// scripts/build-site.sh). The "updated" timestamp comes from
// src/_data/cablesmeta.json, written by that same script and
// committed alongside the data it describes.
//
// It used to read the mtime of data/known-cables.md, which was wrong
// on the deployed site: a git checkout stamps every file with the
// checkout time, so the public build reported its own deploy date and
// re-stamped the page on every unrelated deploy. Reading git history
// at build time would not fix it either, because the public Pages
// workflow clones at depth 1. Hence the committed value.
//
// If either file is missing (e.g. someone runs `bun run site:build`
// standalone on a fresh checkout before the Swift step), we fall
// back to an empty list and the markdown's mtime, then today's date,
// so the build still succeeds instead of blowing up.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const cablesPath = path.join(repoRoot, "docs", "cables.json");
const sourcePath = path.join(repoRoot, "data", "known-cables.md");
const updatedPath = path.join(__dirname, "cablesmeta.json");

function readList() {
  try {
    return JSON.parse(fs.readFileSync(cablesPath, "utf8"));
  } catch {
    return [];
  }
}

function readUpdated() {
  try {
    const { updated } = JSON.parse(fs.readFileSync(updatedPath, "utf8"));
    const parsed = new Date(updated);
    if (!Number.isNaN(parsed.getTime())) return parsed;
  } catch {
    // fall through to the mtime guess below
  }
  try {
    return fs.statSync(sourcePath).mtime;
  } catch {
    return new Date();
  }
}

const list = readList();

export default {
  list,
  count: list.length,
  updated: readUpdated(),
};
