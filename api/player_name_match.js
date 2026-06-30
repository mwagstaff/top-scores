"use strict";

// ---------------------------------------------------------------------------
// Player-name fuzzy matching shared by the match-details player enrichment in
// server.js and the BSD<->TSDB player-id mapping job. Handles abbreviated
// names ("A. Gunn") against full names ("Angus Gunn") and strips diacritics.
// ---------------------------------------------------------------------------

const COMBINING_MARKS = /[̀-ͯ]/g;

function lineupPlayerNameLookup(name) {
  const tokens = String(name || "")
    .normalize("NFD")
    .replace(COMBINING_MARKS, "")
    .replace(/\(c\)/gi, "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
  const first = tokens[0] || "";
  const last = tokens[tokens.length - 1] || "";
  return {
    full: tokens.join(" "),
    initialAndLast: first && last ? `${first[0]} ${last}` : tokens.join(" "),
    last,
  };
}

// Score 0 (no match) … 4 (exact). 3 = initial+surname match ("A. Gunn" vs
// "Angus Gunn"); 2 = shared surname; 1 = one name is a suffix of the other.
function lineupPlayerNameMatchScore(left, right) {
  if (!left.full || !right.full) return 0;
  if (left.full === right.full) return 4;
  if (left.initialAndLast && left.initialAndLast === right.initialAndLast) return 3;
  if (left.last && left.last === right.last) return 2;
  if (left.full.length >= 3 && right.full.endsWith(` ${left.full}`)) return 1;
  if (right.full.length >= 3 && left.full.endsWith(` ${right.full}`)) return 1;
  return 0;
}

// Convenience: score two raw name strings directly.
function playerNamesMatchScore(nameA, nameB) {
  return lineupPlayerNameMatchScore(lineupPlayerNameLookup(nameA), lineupPlayerNameLookup(nameB));
}

module.exports = {
  lineupPlayerNameLookup,
  lineupPlayerNameMatchScore,
  playerNamesMatchScore,
};
