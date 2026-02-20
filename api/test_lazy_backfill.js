#!/usr/bin/env node
/* eslint-disable no-console */
const http = require('http');

const PORT = process.env.PORT || 3000;
const MATCH_ID = 'c0ke3xj52ddt'; // West Brom vs Middlesbrough

function makeRequest(path) {
  return new Promise((resolve, reject) => {
    const req = http.get(`http://localhost:${PORT}${path}`, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: JSON.parse(data)
          });
        } catch (err) {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: data
          });
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(60000);
  });
}

async function test() {
  console.log('Testing lazy backfill for match:', MATCH_ID);
  console.log('');

  console.log('1. Fetching match details (first request, should trigger backfill)...');
  const response = await makeRequest(`/api/v1/matches/${MATCH_ID}`);

  console.log(`   Status: ${response.statusCode}`);
  console.log(`   Last-Updated: ${response.headers['x-last-updated']}`);

  if (response.statusCode === 200) {
    const match = response.body;
    console.log('');
    console.log('2. Match details:');
    console.log(`   ${match.home_team} ${match.home_score || '?'} - ${match.away_score || '?'} ${match.away_team}`);
    console.log(`   Date: ${match.date} ${match.time || ''}`);
    console.log(`   Status: ${match.score_status || 'N/A'}`);
    console.log('');
    console.log('3. Event arrays:');
    console.log(`   Home scorers: ${match.home_goal_scorers?.length || 0}`);
    console.log(`   Away scorers: ${match.away_goal_scorers?.length || 0}`);
    console.log(`   Home assists: ${match.home_assists?.length || 0}`);
    console.log(`   Away assists: ${match.away_assists?.length || 0}`);
    console.log(`   Home red cards: ${match.home_red_cards?.length || 0}`);
    console.log(`   Away red cards: ${match.away_red_cards?.length || 0}`);
    console.log('');

    if (match.home_goal_scorers?.length > 0 || match.away_goal_scorers?.length > 0) {
      console.log('✓ SUCCESS: Match details were enriched!');
      console.log('');
      console.log('Sample scorers:');
      if (match.home_goal_scorers?.length > 0) {
        match.home_goal_scorers.slice(0, 2).forEach(scorer => {
          console.log(`   ${match.home_team}: ${scorer.player} (${scorer.goal_times?.join(', ') || '?'})`);
        });
      }
      if (match.away_goal_scorers?.length > 0) {
        match.away_goal_scorers.slice(0, 2).forEach(scorer => {
          console.log(`   ${match.away_team}: ${scorer.player} (${scorer.goal_times?.join(', ') || '?'})`);
        });
      }
    } else {
      console.log('⚠ WARNING: No goal scorers found (may need manual verification)');
    }
  } else {
    console.log('✗ FAILED:', response.body);
  }
}

test().catch(err => {
  console.error('Test error:', err.message || err);
  process.exit(1);
});
