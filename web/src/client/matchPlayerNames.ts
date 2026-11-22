export interface MatchPlayerNameLookup { full: string; initialAndLast: string; last: string; }

export function buildPlayerNameLookup(name: string): MatchPlayerNameLookup {
  const cleaned    = name.replace(/\(c\)/gi, "");
  const normalized = cleaned.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  const tokens     = normalized.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const first      = tokens[0] ?? "";
  const last       = tokens.at(-1) ?? "";
  return {
    full:           tokens.join(" "),
    initialAndLast: first && last ? `${first[0]} ${last}` : tokens.join(" "),
    last,
  };
}

export function matchPlayerNameLookup(left: MatchPlayerNameLookup, right: MatchPlayerNameLookup) {
  if (!left.full || !right.full)                                         return 0;
  if (left.full === right.full)                                          return 3;
  if (left.initialAndLast && left.initialAndLast === right.initialAndLast) return 2;
  if (left.last && left.last === right.last)                             return 1;
  return 0;
}
