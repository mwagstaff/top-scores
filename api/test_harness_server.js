#!/usr/bin/env node
/* eslint-disable no-console */

const express = require("express");
const path = require("path");
const http = require("http");

const PORT = Number(process.env.TEST_HARNESS_PORT || 3001);
const MAIN_API_PORT = Number(process.env.PORT || 3000);

const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Helper function to proxy requests to main API
function proxyToMainAPI(path, method = "GET", body = null) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: "localhost",
      port: MAIN_API_PORT,
      path: path,
      method: method,
      headers: {
        "Content-Type": "application/json",
      },
    };

    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => {
        data += chunk;
      });
      res.on("end", () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(data) });
        } catch (e) {
          resolve({ status: res.statusCode, data: data });
        }
      });
    });

    req.on("error", (err) => {
      reject(err);
    });

    if (body) {
      req.write(JSON.stringify(body));
    }

    req.end();
  });
}

// Serve the HTML UI
app.get("/", (_req, res) => {
  res.sendFile(path.join(__dirname, "test_harness_ui.html"));
});

// Get available competitions (fetch from main API's competitions endpoint)
app.get("/api/competitions", async (_req, res) => {
  try {
    const mainApiPort = process.env.PORT || 3000;
    const http = require("http");

    const options = {
      hostname: "localhost",
      port: mainApiPort,
      path: "/api/v1/competitions",
      method: "GET",
    };

    const request = http.request(options, (response) => {
      let data = "";

      response.on("data", (chunk) => {
        data += chunk;
      });

      response.on("end", () => {
        try {
          const parsed = JSON.parse(data);
          res.json(parsed);
        } catch (parseErr) {
          console.error("Failed to parse competitions response:", parseErr);
          res.status(500).json({ error: "Failed to parse competitions" });
        }
      });
    });

    request.on("error", (err) => {
      console.error("Failed to fetch competitions:", err.message);
      res.status(500).json({ error: "Failed to fetch competitions. Is the main API server running on port 3000?" });
    });

    request.setTimeout(5000, () => {
      request.destroy();
      console.error("Request to fetch competitions timed out");
      res.status(500).json({ error: "Request timed out" });
    });

    request.end();
  } catch (err) {
    console.error("Failed to fetch competitions:", err);
    res.status(500).json({ error: "Failed to fetch competitions" });
  }
});

// Get current test match state
app.get("/api/test-match", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to get test match:", err);
    res.status(500).json({ error: "Failed to get test match" });
  }
});

// Create a new test match
app.post("/api/test-match/create", async (req, res) => {
  try {
    const params = {
      kickoffNow: req.body.kickoffNow === true || req.body.kickoffNow === "true",
      kickoffTime: req.body.kickoffTime,
      league: req.body.league || "Premier League",
      leagueSubcategory: req.body.leagueSubcategory || null,
      homeTeam: req.body.homeTeam || "Home Team",
      awayTeam: req.body.awayTeam || "Away Team",
      homeScore: parseInt(req.body.homeScore) || 0,
      awayScore: parseInt(req.body.awayScore) || 0,
      matchSpeedMs: req.body.matchSpeedMs != null ? parseInt(req.body.matchSpeedMs) : 10000,
      homeExpectedGoals: parseFloat(req.body.homeExpectedGoals) || 2,
      awayExpectedGoals: parseFloat(req.body.awayExpectedGoals) || 2,
      firstHalfStoppageTime:
        req.body.firstHalfStoppageTime !== undefined &&
        req.body.firstHalfStoppageTime !== ""
          ? parseInt(req.body.firstHalfStoppageTime)
          : undefined,
      secondHalfStoppageTime:
        req.body.secondHalfStoppageTime !== undefined &&
        req.body.secondHalfStoppageTime !== ""
          ? parseInt(req.body.secondHalfStoppageTime)
          : undefined,
      simulateExtraTime:
        req.body.simulateExtraTime === true ||
        req.body.simulateExtraTime === "true",
      simulatePenalties:
        req.body.simulatePenalties === true ||
        req.body.simulatePenalties === "true",
    };

    const result = await proxyToMainAPI("/api/v1/test-harness/match/create", "POST", params);
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to create test match:", err);
    res.status(500).json({ error: err.message });
  }
});

// Start the simulation
app.post("/api/test-match/start", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/start", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to start simulation:", err);
    res.status(500).json({ error: err.message });
  }
});

// Pause the simulation
app.post("/api/test-match/pause", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/pause", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to pause simulation:", err);
    res.status(500).json({ error: err.message });
  }
});

// Resume the simulation
app.post("/api/test-match/resume", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/resume", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to resume simulation:", err);
    res.status(500).json({ error: err.message });
  }
});

// Add a goal
app.post("/api/test-match/add-goal", async (req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/add-goal", "POST", req.body);
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to add goal:", err);
    res.status(500).json({ error: err.message });
  }
});

// Add a red card
app.post("/api/test-match/add-red-card", async (req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/add-red-card", "POST", req.body);
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to add red card:", err);
    res.status(500).json({ error: err.message });
  }
});

// Simulate a goal being disallowed by VAR
app.post("/api/test-match/simulate-var-disallowed-goal", async (req, res) => {
  try {
    const result = await proxyToMainAPI(
      "/api/v1/test-harness/match/simulate-var-disallowed-goal",
      "POST",
      req.body
    );
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to simulate VAR-disallowed goal:", err);
    res.status(500).json({ error: err.message });
  }
});

// Jump to half time
app.post("/api/test-match/jump-to-ht", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/jump-to-ht", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to jump to half time:", err);
    res.status(500).json({ error: err.message });
  }
});

// Jump to full time
app.post("/api/test-match/jump-to-ft", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/jump-to-ft", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to jump to full time:", err);
    res.status(500).json({ error: err.message });
  }
});

// Restart the match
app.post("/api/test-match/restart", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/restart", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to restart match:", err);
    res.status(500).json({ error: err.message });
  }
});

// Set match speed
app.post("/api/test-match/set-speed", async (req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/set-speed", "POST", req.body);
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to set match speed:", err);
    res.status(500).json({ error: err.message });
  }
});

// Delete the match
app.post("/api/test-match/delete", async (_req, res) => {
  try {
    const result = await proxyToMainAPI("/api/v1/test-harness/match/delete", "POST");
    res.status(result.status).json(result.data);
  } catch (err) {
    console.error("Failed to delete match:", err);
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`\n🧪 Test Harness Server running at http://localhost:${PORT}`);
  console.log(`   Open the URL above to access the match simulator control panel\n`);
});
