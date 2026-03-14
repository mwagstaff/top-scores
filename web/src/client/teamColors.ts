import { useEffect, useSyncExternalStore } from "react";

interface TeamColorEntry {
  name: string;
  aliases?: string[];
  primary: string;
  secondary: string;
  scheme?: string | null;
  isFallback?: boolean;
}

interface TeamColorCatalogPayload {
  updatedAt?: string;
  default: {
    primary: string;
    secondary: string;
    scheme?: string | null;
  };
  teams: TeamColorEntry[];
  identity_groups?: TeamIdentityGroup[];
}

interface TeamIdentityGroup {
  name: string;
  aliases?: string[];
}

export interface ResolvedTeamColors {
  background: string;
  foreground: string;
  scheme: string | null;
  outlineColor: string | null;
}

class TeamColorCatalogStore {
  private readonly listeners = new Set<() => void>();
  private readonly fallbackEntry: TeamColorEntry = {
    name: "Default",
    aliases: [],
    primary: "#111111",
    secondary: "#FFFFFF",
    scheme: "default-dark",
    isFallback: true,
  };
  private readonly exactByKey = new Map<string, TeamColorEntry>();
  private readonly canonicalNameByKey = new Map<string, string>();
  private readonly namesByCanonicalKey = new Map<string, string[]>();
  private readonly exactIdentityToCanonicalKey = new Map<string, string>();
  private version = 0;
  private loadPromise: Promise<void> | null = null;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  snapshot = (): number => this.version;

  async ensureLoaded(): Promise<void> {
    if (this.loadPromise) {
      return this.loadPromise;
    }

    this.loadPromise = fetch("/api/v1/team-colors", { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`Failed to load team colors: ${response.status}`);
        }
        return response.json() as Promise<TeamColorCatalogPayload>;
      })
      .then((payload) => {
        this.apply(payload);
      })
      .catch((error) => {
        console.warn("[TeamColors]", error);
      })
      .finally(() => {
        this.loadPromise = null;
      });

    return this.loadPromise;
  }

  lineupColors(
    teamName: string,
    opponentTeamName: string | null | undefined,
    side: "home" | "away"
  ): ResolvedTeamColors {
    const entry = this.resolve(teamName) ?? this.fallbackEntry;
    const opponent = opponentTeamName ? this.resolve(opponentTeamName) : null;
    const invert = side === "away" && shouldInvert(entry, opponent);
    const background = invert ? entry.secondary : entry.primary;
    const preferredForeground = invert ? entry.primary : entry.secondary;
    const foreground = accessibleForegroundColor(background, preferredForeground);

    return {
      background,
      foreground,
      scheme: entry.scheme ?? null,
      outlineColor: foreground.toUpperCase() === preferredForeground.toUpperCase()
        ? outlineColorForText(background, foreground)
        : null,
    };
  }

  private apply(payload: TeamColorCatalogPayload): void {
    this.exactByKey.clear();
    this.canonicalNameByKey.clear();
    this.namesByCanonicalKey.clear();
    this.exactIdentityToCanonicalKey.clear();

    const normalizedDefault = {
      ...this.fallbackEntry,
      primary: payload.default.primary || this.fallbackEntry.primary,
      secondary: payload.default.secondary || this.fallbackEntry.secondary,
      scheme: payload.default.scheme ?? this.fallbackEntry.scheme,
      isFallback: true,
    };
    this.fallbackEntry.primary = normalizedDefault.primary;
    this.fallbackEntry.secondary = normalizedDefault.secondary;
    this.fallbackEntry.scheme = normalizedDefault.scheme;

    for (const team of payload.teams ?? []) {
      const entry: TeamColorEntry = {
        name: team.name,
        aliases: team.aliases ?? [],
        primary: team.primary || normalizedDefault.primary,
        secondary: team.secondary || normalizedDefault.secondary,
        scheme: team.scheme ?? null,
      };

      const names = [entry.name, ...(entry.aliases ?? [])];
      for (const name of names) {
        const key = normalizedTeamKey(name);
        if (key && !this.exactByKey.has(key)) {
          this.exactByKey.set(key, entry);
        }
      }

      this.registerIdentity(entry.name, entry.aliases ?? []);
    }

    for (const group of payload.identity_groups ?? []) {
      this.registerIdentity(group.name, group.aliases ?? []);
    }

    this.version += 1;
    this.listeners.forEach((listener) => listener());
  }

  private resolve(teamName: string): TeamColorEntry | null {
    const key = normalizedTeamKey(teamName);
    if (!key) {
      return null;
    }
    const direct = this.exactByKey.get(key);
    if (direct) {
      return direct;
    }

    const canonical = this.canonicalTeamName(teamName);
    if (!canonical) {
      return null;
    }
    return this.exactByKey.get(normalizedTeamKey(canonical)) ?? null;
  }

  canonicalTeamName(teamName: string): string | null {
    const key = normalizedTeamKey(teamName);
    if (!key) {
      return null;
    }
    const canonicalKey = this.exactIdentityToCanonicalKey.get(key);
    if (!canonicalKey) {
      return null;
    }
    return this.canonicalNameByKey.get(canonicalKey) ?? null;
  }

  identityNames(teamName: string): string[] {
    const trimmed = teamName.trim();
    if (!trimmed) {
      return [];
    }

    const key = normalizedTeamKey(trimmed);
    const canonicalKey = this.exactIdentityToCanonicalKey.get(key);
    if (!canonicalKey) {
      return [trimmed];
    }

    return Array.from(
      new Set([
        this.canonicalNameByKey.get(canonicalKey) ?? trimmed,
        ...(this.namesByCanonicalKey.get(canonicalKey) ?? []),
        trimmed,
      ].filter(Boolean))
    );
  }

  private registerIdentity(name: string, aliases: string[]): void {
    const canonicalKey = normalizedTeamKey(name);
    if (!canonicalKey) {
      return;
    }

    if (!this.canonicalNameByKey.has(canonicalKey)) {
      this.canonicalNameByKey.set(canonicalKey, name);
    }

    const names = this.namesByCanonicalKey.get(canonicalKey) ?? [];
    for (const candidate of [name, ...aliases]) {
      const trimmed = candidate.trim();
      if (!trimmed) {
        continue;
      }
      if (!names.includes(trimmed)) {
        names.push(trimmed);
      }
      const key = normalizedTeamKey(trimmed);
      if (key && !this.exactIdentityToCanonicalKey.has(key)) {
        this.exactIdentityToCanonicalKey.set(key, canonicalKey);
      }
    }
    this.namesByCanonicalKey.set(canonicalKey, names);
  }
}

function shouldInvert(entry: TeamColorEntry, opponent: TeamColorEntry | null): boolean {
  if (!opponent) {
    return false;
  }

  if (entry.isFallback || opponent.isFallback) {
    return false;
  }

  if (entry.scheme && opponent.scheme && entry.scheme.toLowerCase() === opponent.scheme.toLowerCase()) {
    return true;
  }

  if (areColorsSimilar(entry.primary, opponent.primary)) {
    return true;
  }

  return (
    entry.primary.toLowerCase() === opponent.primary.toLowerCase() &&
    entry.secondary.toLowerCase() === opponent.secondary.toLowerCase()
  );
}

function normalizedTeamKey(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/'/g, "")
    .replace(/[._-]/g, " ")
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .join("");
}

function accessibleForegroundColor(background: string, preferredForeground: string): string {
  if (contrastRatio(background, preferredForeground) >= 4.5) {
    return preferredForeground;
  }

  const whiteContrast = contrastRatio(background, "#FFFFFF");
  const blackContrast = contrastRatio(background, "#000000");
  return whiteContrast >= blackContrast ? "#FFFFFF" : "#000000";
}

function outlineColorForText(background: string, foreground: string): string | null {
  const contrast = contrastRatio(background, foreground);
  if (contrast >= 4) {
    return null;
  }

  const whiteScore = Math.min(
    contrastRatio(background, "#FFFFFF"),
    contrastRatio(foreground, "#FFFFFF")
  );
  const blackScore = Math.min(
    contrastRatio(background, "#000000"),
    contrastRatio(foreground, "#000000")
  );

  return whiteScore >= blackScore ? "#FFFFFF" : "#000000";
}

function contrastRatio(left: string, right: string): number {
  const leftRgb = parseHexColor(left);
  const rightRgb = parseHexColor(right);
  if (!leftRgb || !rightRgb) {
    return Number.POSITIVE_INFINITY;
  }

  const leftLuminance = relativeLuminance(leftRgb);
  const rightLuminance = relativeLuminance(rightRgb);
  const lighter = Math.max(leftLuminance, rightLuminance);
  const darker = Math.min(leftLuminance, rightLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function parseHexColor(value: string): { r: number; g: number; b: number } | null {
  const normalized = normalizeHex(value);
  if (!normalized) {
    return null;
  }

  const raw = normalized.slice(1);
  return {
    r: Number.parseInt(raw.slice(0, 2), 16),
    g: Number.parseInt(raw.slice(2, 4), 16),
    b: Number.parseInt(raw.slice(4, 6), 16),
  };
}

function areColorsSimilar(left: string, right: string): boolean {
  const leftRgb = parseHexColor(left);
  const rightRgb = parseHexColor(right);
  if (!leftRgb || !rightRgb) {
    return false;
  }

  const redDelta = leftRgb.r / 255 - rightRgb.r / 255;
  const greenDelta = leftRgb.g / 255 - rightRgb.g / 255;
  const blueDelta = leftRgb.b / 255 - rightRgb.b / 255;
  const distance = Math.sqrt(
    redDelta * redDelta +
    greenDelta * greenDelta +
    blueDelta * blueDelta
  );

  return distance <= 0.28;
}

function normalizeHex(value: string): string | null {
  const normalized = value.trim().toUpperCase();
  return /^#[0-9A-F]{6}$/.test(normalized) ? normalized : null;
}

function relativeLuminance({ r, g, b }: { r: number; g: number; b: number }): number {
  const [red, green, blue] = [r, g, b].map((channel) => {
    const normalized = channel / 255;
    return normalized <= 0.03928
      ? normalized / 12.92
      : ((normalized + 0.055) / 1.055) ** 2.4;
  });

  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

const teamColorCatalog = new TeamColorCatalogStore();
void teamColorCatalog.ensureLoaded();

export function useTeamColorCatalog(): TeamColorCatalogStore {
  useSyncExternalStore(teamColorCatalog.subscribe, teamColorCatalog.snapshot);

  useEffect(() => {
    void teamColorCatalog.ensureLoaded();
  }, []);

  return teamColorCatalog;
}

export function teamIdentityNames(teamName: string): string[] {
  return teamColorCatalog.identityNames(teamName);
}

export function teamIdentityKeys(teamName: string): string[] {
  return Array.from(
    new Set(
      teamColorCatalog
        .identityNames(teamName)
        .map((name) => normalizedTeamKey(name))
        .filter(Boolean)
    )
  );
}

export { normalizedTeamKey };
