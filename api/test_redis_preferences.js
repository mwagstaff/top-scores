#!/usr/bin/env node
/**
 * Test script for Redis preferences sync
 * Run with: node test_redis_preferences.js
 */

const {
  saveUserPreferences,
  getUserPreferences,
  getAllUserPreferences,
  deleteUserPreferences,
  closeRedisConnection,
} = require("./redis_client");

const TEST_DEVICE_TOKEN = "test-device-12345-abcde";

async function runTests() {
  console.log("=".repeat(60));
  console.log("Redis User Preferences Test Suite");
  console.log("=".repeat(60));

  try {
    // Test 1: Save preferences
    console.log("\n[Test 1] Saving user preferences...");
    const testPreferences = {
      selectedLeagues: ["Premier League", "UEFA Champions League"],
      selectedChannels: ["Sky Sports (all)", "TNT Sports (all)"],
      competitionFilterEnabled: true,
      channelFilterEnabled: true,
      englishPremierLeagueTeamsOnly: false,
      apiBaseURL: "http://localhost:3000/api/v1",
      refreshIntervalMinutes: 10,
      showAllMatches: false,
    };

    const saved = await saveUserPreferences(TEST_DEVICE_TOKEN, testPreferences);
    console.log("✅ Saved successfully:");
    console.log(JSON.stringify(saved, null, 2));

    // Test 2: Retrieve preferences
    console.log("\n[Test 2] Retrieving user preferences...");
    const retrieved = await getUserPreferences(TEST_DEVICE_TOKEN);
    console.log("✅ Retrieved successfully:");
    console.log(JSON.stringify(retrieved, null, 2));

    // Verify data matches
    if (JSON.stringify(retrieved.preferences) === JSON.stringify(testPreferences)) {
      console.log("✅ Data verification passed - preferences match!");
    } else {
      console.error("❌ Data verification failed - preferences don't match!");
    }

    // Test 3: Update preferences
    console.log("\n[Test 3] Updating user preferences...");
    const updatedPreferences = {
      ...testPreferences,
      selectedLeagues: ["Premier League", "La Liga", "Serie A"],
      refreshIntervalMinutes: 5,
    };

    await saveUserPreferences(TEST_DEVICE_TOKEN, updatedPreferences);
    const updated = await getUserPreferences(TEST_DEVICE_TOKEN);
    console.log("✅ Updated successfully:");
    console.log(`   Leagues: ${updated.preferences.selectedLeagues.join(", ")}`);
    console.log(`   Refresh interval: ${updated.preferences.refreshIntervalMinutes} min`);

    // Test 4: Save another device's preferences
    console.log("\n[Test 4] Saving preferences for second device...");
    const secondDevice = "test-device-67890-fghij";
    await saveUserPreferences(secondDevice, {
      selectedLeagues: ["Bundesliga"],
      selectedChannels: ["Amazon Prime Video"],
      competitionFilterEnabled: true,
      channelFilterEnabled: true,
      englishPremierLeagueTeamsOnly: true,
      apiBaseURL: "http://localhost:3000/api/v1",
      refreshIntervalMinutes: 15,
      showAllMatches: true,
    });
    console.log("✅ Second device preferences saved");

    // Test 5: Get all preferences
    console.log("\n[Test 5] Retrieving all user preferences...");
    const allPrefs = await getAllUserPreferences();
    console.log(`✅ Found ${allPrefs.length} device(s) with preferences:`);
    allPrefs.forEach((pref, index) => {
      console.log(`   ${index + 1}. Device: ${pref.deviceToken.substring(0, 20)}...`);
      console.log(`      Leagues: ${pref.preferences.selectedLeagues.join(", ")}`);
      console.log(`      Updated: ${pref.updatedAt}`);
    });

    // Test 6: Delete preferences
    console.log("\n[Test 6] Deleting test preferences...");
    const deleted1 = await deleteUserPreferences(TEST_DEVICE_TOKEN);
    const deleted2 = await deleteUserPreferences(secondDevice);

    if (deleted1 && deleted2) {
      console.log("✅ Both test devices' preferences deleted successfully");
    } else {
      console.error("❌ Failed to delete some preferences");
    }

    // Verify deletion
    const afterDelete = await getUserPreferences(TEST_DEVICE_TOKEN);
    if (afterDelete === null) {
      console.log("✅ Deletion verified - preferences no longer exist");
    } else {
      console.error("❌ Deletion verification failed - preferences still exist!");
    }

    console.log("\n" + "=".repeat(60));
    console.log("All tests completed successfully! ✅");
    console.log("=".repeat(60));
  } catch (error) {
    console.error("\n❌ Test failed with error:");
    console.error(error);
    process.exit(1);
  } finally {
    await closeRedisConnection();
    console.log("\nRedis connection closed.");
  }
}

runTests();
