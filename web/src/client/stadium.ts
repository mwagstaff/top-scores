export interface StadiumAsset {
  id: string;
  sha256: string;
  role: string;
  team_ids: string[];
  stadium?: string;
  focal_point?: { x: number; y: number };
  credit?: { attribution?: string; source_page?: string; author?: string };
}
export interface StadiumCatalog {
  teams: Record<
    string,
    {
      name: string;
      aliases: string[];
      source_team_ids: string[];
      bsd_team_id?: string;
    }
  >;
  assets: StadiumAsset[];
}
const normalized = (name: string) =>
  name
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
export function selectStadium(
  catalog: StadiumCatalog,
  name?: string,
  teamId?: string | null,
  selectionKey = "top-scores",
): StadiumAsset | undefined {
  const keys = Object.keys(catalog.teams).sort();
  const team =
    (teamId &&
      keys.find(
        (key) =>
          key === teamId ||
          catalog.teams[key].bsd_team_id === teamId ||
          catalog.teams[key].source_team_ids?.includes(teamId),
      )) ||
    (name &&
      keys.find((key) =>
        [catalog.teams[key].name, ...(catalog.teams[key].aliases || [])].some(
          (alias) => normalized(alias) === normalized(name),
        ),
      )) ||
    undefined;
  let assets = team
    ? catalog.assets.filter(
        (asset) => asset.role === "team" && asset.team_ids.includes(team),
      )
    : [];
  if (!assets.length)
    assets = catalog.assets.filter(
      (asset) => asset.role === (name ? "generic_match" : "generic_backdrop"),
    );
  assets.sort((a, b) => a.id.localeCompare(b.id));
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(name || selectionKey))
    hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  return assets[hash % assets.length];
}
let catalogPromise: Promise<StadiumCatalog> | undefined;
export function loadStadiumCatalog(): Promise<StadiumCatalog> {
  return (catalogPromise ||= fetch("/artwork/catalog", {
    signal: AbortSignal.timeout(10_000),
  })
    .then((response) => {
      if (!response.ok) throw new Error("Artwork unavailable");
      return response.json();
    })
    .catch((error) => {
      catalogPromise = undefined;
      throw error;
    }));
}
