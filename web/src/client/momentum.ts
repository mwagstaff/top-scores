export interface MomentumPoint { minute: number; value: number }
export interface MomentumSegment { id: string; side: "home" | "away"; points: MomentumPoint[] }
export interface MomentumAnnotation {
  id: string; minute: number; time: string; side: "home" | "away";
  kind: "goal" | "red_card" | "penalty_missed" | "disallowed_goal"; label: string;
}
export interface MatchMomentum {
  status: string; segments: MomentumSegment[]; annotations: MomentumAnnotation[];
  end_minute: number; scale: number; ticks: { minute: number; label: string }[];
  updated_at: string | null; refresh_after_seconds: number | null;
}

export function normalizeMomentum(value: unknown): MatchMomentum | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as MatchMomentum;
  const validMinute = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n) && n >= 0 && n <= 150;
  if (!validMinute(raw.end_minute) || raw.end_minute === 0 || !Number.isFinite(raw.scale) || raw.scale <= 0 ||
      !Array.isArray(raw.segments) || !Array.isArray(raw.annotations) || !Array.isArray(raw.ticks)) return null;
  return { ...raw,
    segments: raw.segments.filter(s => s && typeof s.id === "string" && ["home", "away"].includes(s.side) &&
      Array.isArray(s.points) && s.points.length >= 2 && s.points.every(p => p && validMinute(p.minute) &&
        typeof p.value === "number" && Number.isFinite(p.value))),
    annotations: raw.annotations.filter(a => a && typeof a.id === "string" && validMinute(a.minute) &&
      ["home", "away"].includes(a.side) && ["goal", "red_card", "penalty_missed", "disallowed_goal"].includes(a.kind) &&
      typeof a.label === "string" && typeof a.time === "string"),
    ticks: raw.ticks.filter(t => t && validMinute(t.minute) && typeof t.label === "string"),
  };
}

export function annotationLanes(annotations: MomentumAnnotation[], side: "home" | "away", width: number, end: number) {
  const lastPositions: number[] = [];
  return annotations.filter(a => a.side === side).sort((a, b) => a.minute - b.minute).map(annotation => {
    const x = Math.min(width, annotation.minute / end * width);
    let lane = lastPositions.findIndex(last => x - last >= 44);
    if (lane < 0) lane = lastPositions.length;
    lastPositions[lane] = x;
    return { annotation, x, lane };
  });
}

export function momentumPath(segment: MomentumSegment, end: number, scale: number) {
  const x = (minute: number) => minute / end * 1000;
  return `M ${x(segment.points[0].minute)} 70 ` +
    segment.points.map(p => `L ${x(p.minute)} ${70 - p.value / scale * 64}`).join(" ") +
    ` L ${x(segment.points.at(-1)!.minute)} 70 Z`;
}

export const momentumSymbol = (kind: MomentumAnnotation["kind"]) =>
  ({ goal: "⚽", red_card: "▮", penalty_missed: "P×", disallowed_goal: "⚽×" })[kind];

// The website is dark. Prefer the team's alternate colour when its primary
// disappears into the chart surface, and separate unknown/identical identities.
export function momentumColors(home: { background: string; foreground: string }, away: { background: string; foreground: string }) {
  const rgb = (hex: string) => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255);
  const luminance = (hex: string) => rgb(hex).map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
    .reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i], 0);
  const visible = (colors: typeof home) => luminance(colors.background) >= 0.12 ? colors.background : colors.foreground;
  const distance = (a: string, b: string) => Math.sqrt(rgb(a).reduce((sum, c, i) => sum + (c - rgb(b)[i]) ** 2, 0));
  const homeColor = visible(home);
  let awayColor = visible(away);
  if (distance(homeColor, awayColor) < 0.35) awayColor = distance(homeColor, "#2aa8ff") > 0.35 ? "#2aa8ff" : "#efb43c";
  return { home: { background: homeColor, foreground: "#f2f5fa" }, away: { background: awayColor, foreground: "#f2f5fa" } };
}
