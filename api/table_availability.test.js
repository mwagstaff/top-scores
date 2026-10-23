const test = require('node:test');
const assert = require('node:assert/strict');
const { supportsTable, eligibleTables } = require('./table_availability');
test('canonical rule excludes knockout-only cups by BSD IDs, names and aliases', () => {
 for (const [id,name] of [['39','FA Cup'],['40','EFL Cup'],['41','Copa del Rey'],['43','DFB-Pokal'],['42','Coppa Italia'],['44','Coupe de France'],['90','UEFA Super Cup'],['31','International Friendly']]) {
  assert.equal(supportsTable(id,''),false); assert.equal(supportsTable(null,name),false);
 }
 assert.equal(supportsTable('english-league-cup','Other',['Carabao Cup']),false);
 assert.equal(supportsTable('fa-cup','English FA Cup'),false);
});
test('group-stage competitions remain available and filtering does not mutate source data', () => {
 const retained = [['1','Premier League'],['7','UEFA Champions League'],['8','UEFA Europa League'],['83','UEFA Conference League'],['27','FIFA World Cup 2026'],['64','UEFA Nations League']].map(([league_id,league_name])=>({league_id,league_name}));
 const all = [...retained,{league_id:'39',league_name:'FA Cup',rows:[{team:'Misleading upstream row'}]}];
 assert.deepEqual(eligibleTables(all),retained); assert.equal(all.length,7);
});

test('competition catalogue exposes the canonical eligibility decision', () => {
 const catalog = require('./server').__private.buildCompetitionCatalog();
 for (const entry of catalog) assert.equal(entry.supports_table, supportsTable(entry.id,entry.name,entry.aliases));
 assert.equal(catalog.find(entry => entry.name === 'FA Cup').supports_table,false);
 assert.equal(catalog.find(entry => entry.name === 'Premier League').supports_table,true);
});
