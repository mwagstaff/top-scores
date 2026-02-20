#!/usr/bin/env node
/* eslint-disable no-console */

// Test script to verify subcategory extraction is working
// Usage: node test_subcategory.js [date]
// Example: node test_subcategory.js 2026-02-17

const { fetchBbcScoresFixturesByDate } = require("./fetch_bbc_scores");

async function main() {
  const date = process.argv[2] || "2026-02-17";

  console.log(`\n${"=".repeat(80)}`);
  console.log(`Testing subcategory extraction for ${date}`);
  console.log(`${"=".repeat(80)}\n`);

  try {
    const matches = await fetchBbcScoresFixturesByDate(date);

    console.log(`✓ Found ${matches.length} total matches\n`);

    // Count matches with subcategories
    const withSubcategory = matches.filter(m => m.league_subcategory);
    const withoutSubcategory = matches.filter(m => !m.league_subcategory);

    console.log(`📊 Statistics:`);
    console.log(`   - With subcategory: ${withSubcategory.length}`);
    console.log(`   - Without subcategory: ${withoutSubcategory.length}\n`);

    // Show unique competitions with their subcategories
    const competitionMap = new Map();
    matches.forEach(match => {
      const key = match.league;
      if (!competitionMap.has(key)) {
        competitionMap.set(key, new Set());
      }
      if (match.league_subcategory) {
        competitionMap.get(key).add(match.league_subcategory);
      }
    });

    console.log(`🏆 Competitions and their subcategories:\n`);
    Array.from(competitionMap.entries())
      .sort((a, b) => a[0].localeCompare(b[0]))
      .forEach(([league, subcategories]) => {
        if (subcategories.size > 0) {
          console.log(`   ${league}:`);
          Array.from(subcategories).forEach(sub => {
            console.log(`      → ${sub}`);
          });
        } else {
          console.log(`   ${league}: (no subcategory)`);
        }
      });

    // Show first 5 matches with subcategories
    if (withSubcategory.length > 0) {
      console.log(`\n📋 Sample matches WITH subcategory:\n`);
      withSubcategory.slice(0, 5).forEach((match, i) => {
        console.log(`   ${i + 1}. ${match.league} → ${match.league_subcategory}`);
        console.log(`      ${match.home_team} vs ${match.away_team} (${match.time})`);
      });
    }

    // Show first 3 matches without subcategories
    if (withoutSubcategory.length > 0) {
      console.log(`\n📋 Sample matches WITHOUT subcategory:\n`);
      withoutSubcategory.slice(0, 3).forEach((match, i) => {
        console.log(`   ${i + 1}. ${match.league}`);
        console.log(`      ${match.home_team} vs ${match.away_team} (${match.time})`);
      });
    }

    // Show full JSON for first match with subcategory
    if (withSubcategory.length > 0) {
      console.log(`\n📄 Full JSON for first match with subcategory:\n`);
      console.log(JSON.stringify(withSubcategory[0], null, 2));
    }

    console.log(`\n${"=".repeat(80)}`);
    console.log(`✓ Test completed successfully`);
    console.log(`${"=".repeat(80)}\n`);

  } catch (err) {
    console.error(`\n❌ Error:`, err.message || err);
    console.error(err.stack);
    process.exit(1);
  }
}

main();
