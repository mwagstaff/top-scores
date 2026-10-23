// Mirrors iOS TableCompetitionOrdering in Views/TablesView.swift.
const key = (value: string) => value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");
const englishDomesticKeys = new Set(["premierleague", "englishpremierleague", "facup", "englishfacup", "englishleaguecup", "eflcup", "carabaocup", "championship", "englishleaguechampionship", "leagueone", "eflleagueone", "englishleague1", "leaguetwo", "eflleaguetwo", "englishleague2", "nationalleague", "englishnationalleague", "enterprisenationalleague"]);
const otherEuropeanLeagueKeys = new Set(["laliga", "spanishlaliga", "bundesliga", "germanbundesliga", "seriea", "italianseriea", "ligue1", "frenchligue1", "dutcheredivisie", "eredivisie"]);
const otherEuropeanCupKeys = new Set(["copadelrey", "dfbpokal", "germansupercup", "dflsupercup", "coppaitalia", "coupedefrance"]);
const europeanClubKeys = new Set(["uefachampionsleague", "championsleague", "uefaeuropaleague", "europaleague", "uefaconferenceleague", "uefaeuropaconferenceleague", "conferenceleague", "uefasupercup"]);
const internationalKeys = new Set(["fifaworldcup2026", "fifaworldcup", "uefanationsleague", "nationsleague", "internationalfriendly", "internationalfriendlies", "worldcupqualifyinguefa", "worldcupqualifyingconcacaf", "worldcupqualifyingconmebol", "worldcupqualifyingofc"]);
const fallback: Record<string, number> = {"Premier League": 100.0, "UEFA Champions League": 90.0, "FIFA World Cup 2026": 85.0, "UEFA Europa League": 80.0, "UEFA Conference League": 70.0, "UEFA Nations League": 69.0, "UEFA Super Cup": 68.0, "FA Cup": 65.0, "English League Cup": 60.0, "Copa del Rey": 49.0, "La Liga": 50.0, "Bundesliga": 48.0, "DFB-Pokal": 47.5, "DFL-Supercup": 47.0, "German Super Cup": 47.0, "Serie A": 45.0, "Coppa Italia": 44.5, "Ligue 1": 44.0, "Coupe de France": 43.0, "Dutch Eredivisie": 40.0, "Championship": 40.0, "EFL Cup": 60.0, "Scottish Premiership": 30.0, "Scottish Championship": 25.0, "Scottish League One": 20.0, "Scottish League Two": 15.0, "League One": 14.0, "League Two": 12.0, "National League": 11.0, "International Friendly": 10.0};
export interface OrderedCompetition { id: string; name: string; weight?: number }
function worldCupOrder(item: OrderedCompetition): number | undefined {
  const keys = [key(item.id), key(item.name)];
  const regions = [['58','uefa'], ['59','conmebol'], ['62','concacaf'], ['60','caf'], ['61','afc'], ['63','ofc']];
  const region = regions.findIndex(([id, name]) => item.id === id || keys.some(value => value.includes('worldcupqual') && value.endsWith(name)));
  if (region >= 0) return region + 1;
  if (item.id === '27' || keys.some(value => value.includes('worldcup') && !value.includes('qual'))) return 0;
}
function tier(item: OrderedCompetition) {
  if (worldCupOrder(item) !== undefined) return 7;
  const keys = [key(item.id), key(item.name)];
  if (keys.some(value => englishDomesticKeys.has(value))) return 0;
  if (keys.some(value => value.includes('scottish'))) return 1;
  if (keys.some(value => otherEuropeanLeagueKeys.has(value))) return 2;
  if (keys.some(value => otherEuropeanCupKeys.has(value))) return 3;
  if (keys.some(value => europeanClubKeys.has(value))) return 4;
  if (keys.some(value => internationalKeys.has(value))) return 6;
  return 5;
}
export function compareCompetitions(a: OrderedCompetition, b: OrderedCompetition) {
  return tier(a) - tier(b)
    || (tier(a) === 7 ? (worldCupOrder(a) ?? 0) - (worldCupOrder(b) ?? 0) : 0)
    || (b.weight ?? fallback[b.name] ?? 0) - (a.weight ?? fallback[a.name] ?? 0)
    || a.name.localeCompare(b.name, 'en', { sensitivity: 'base' });
}
