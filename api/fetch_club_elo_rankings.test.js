const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { fetchClubEloRankings, __private: { parseRankingPage } } = require('./fetch_club_elo_rankings');
const date = new Date().toISOString().slice(0, 10);
const row = (name, score) => `<tr><td><span class="Ast">${name}</span></td><td>${score}</td></tr>`;
const page = (rows, published = date) => `<div class="accordion-major-item"><a>${published}</a></div>
<div class="accordion-item"><div class="accordion-header"><a href="ENG">England</a></div>
<div class="accordion-content"><table><tr><td><i>Level 1 (3 teams)</i></td></tr>${rows}</table></div></div>`;
const response = body => ({ headers: { 'content-type': 'text/html' }, body });
const options = { minRows: 1, minBytes: 1 };
test('reads complete country tables and prefers precise chart ratings without running scripts', () => {
  const body = page(row('Arsenal', '2045') + row('Other &amp; United', '1600') + row('Provisional', '1554p')) +
    '<script>const vegaJson = {"datasets":{"empty":[],"ratings":[{"Name":"Arsenal","FedURL":"ENG","Elo":2045.39}]}};</script>' +
    '<script>throw new Error("must not execute")</script>';
  const result = parseRankingPage(response(body), { ...options, minRows: 2 });
  assert.equal(result.rows.length, 2);
  assert.equal(result.rows[0].Elo, 2045.39);
  assert.equal(result.rows[0].Level, 1);
  assert.equal(result.rows[0].From, date);
  assert.equal(result.rows[1].Club, 'Other & United');
});
test('rejects truncated, stale and non-HTML responses', () => {
  assert.throws(() => parseRankingPage(response(page(row('Arsenal', '2045'))), { ...options, minRows: 600 }), /too few/);
  assert.throws(() => parseRankingPage(response(page(row('Arsenal', '2045'), '2020-01-01')), options), /stale/);
  assert.throws(() => parseRankingPage({ headers: {}, body: 'Fixtures API deactivated' }, options), /not HTML/);
});
test('deduplicates ambiguous same-country names using the strongest rating', () => {
  const result = parseRankingPage(response(page(row('United', '1600') + row('United', '1400'))), options);
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].Elo, 1600);
});
test('fetches the website ranking route and returns ranked importer-compatible teams', async t => {
  const server = http.createServer((req, res) => {
    assert.equal(req.url, '/Ranking');
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(page(row('Second', '1600') + row('First', '2000')));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const result = await fetchClubEloRankings({ ...options, baseUrl: `http://127.0.0.1:${server.address().port}` });
  assert.equal(result.teams[0].Name, 'First');
  assert.equal(result.teams[0].Rank, 1);
  assert.equal(result.date, date);
});

test('preserves the legacy Inter identity used by manual matching', () => {
  const result = parseRankingPage(response(page(row('Internazionale', '1942'))), options);
  assert.equal(result.rows[0].Club, 'Inter');
});

test('migrates an existing retired CSV host override', () => {
  const { buildClubEloUrl } = require('./fetch_club_elo_rankings').__private;
  assert.equal(buildClubEloUrl('http://api.clubelo.com/'), 'https://clubelo.com/Ranking');
});
