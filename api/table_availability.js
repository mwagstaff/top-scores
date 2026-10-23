"use strict";
// Canonical eligibility rule, formerly maintained by the iOS client.
const excluded = new Set([
  '39', 'facup', 'englishfacup', '40', 'eflcup', 'englishleaguecup', 'carabaocup',
  '41', 'copadelrey', '43', 'dfbpokal', '42', 'coppaitalia', '44', 'coupedefrance',
  '90', 'uefasupercup', '31', 'internationalfriendly', 'internationalfriendlies', 'friendlies',
]);
function supportsTable(id, name, aliases = []) {
  return ![id, name, ...aliases].filter(Boolean).some(value => excluded.has(String(value).toLowerCase().replace(/[^a-z0-9]/g, '')));
}
function eligibleTables(tables) {
  return tables.filter(table => supportsTable(table.league_id, table.league_name));
}
module.exports = { supportsTable, eligibleTables };
