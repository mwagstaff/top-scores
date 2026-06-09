"use strict";

const { getAllLeagues } = require("./thesportsdb_client");

async function fetchSoccerLeagues(options = {}) {
  const data = await getAllLeagues({
    initiator: options.initiator || "scheduler",
    trigger: options.trigger || "midnight",
  });

  // TSDB v2 /all/leagues returns { all: [...] }
  const all = Array.isArray(data && data.all) ? data.all : [];

  return all.filter(
    (league) => league && String(league.strSport || "").toLowerCase() === "soccer"
  );
}

module.exports = { fetchSoccerLeagues };
