# Claude Code Instructions

## Overview

- `Top Scores` consists of an API, iOS app and website
- A top quality user experience is paramount
- All pages/screens on both website and app should load as quickly as possible, with data load times measured in milliseconds

## Server logs

- The default production server is `sky`, reachable by passwordless SSH, e.g. `ssh sky`
- Server logs can be found under `/home/mwagstaff/dev/top-scores`, e.g.: `top-scores.error.log`
- System architecture is described in `ARCHITECTURE_OVERVIEW.md`

## Build System

- Run `xcodebuild` as needed to compile and test the iOS/watchOS projects after code changes. Use it to identify and resolve build errors before handing work back.
- Do not launch or install the app on a physical device unless the user explicitly asks.
- **Never try and start the node API server**, e.g. by running `npm start` or `node server.js` - The user will always start the server themselves

## Secrets

When testing locally, use .env.local for secrets
# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


# BSD API

BSD is the sole upstream sports-data provider for fixtures, results, live scores, match details, standings, teams, players, broadcasts, and predictions.

## Implementation approach

- Call BSD APIs and save output to Mongo using collections with a `bsd_` prefix
- Data should be upserted as needed
- All collections should include an internal timestamp to reflect the time the data was last updated
- The `limit` parameter for all API calls should be set to 200 (max allowed)
- Handle API pagination with the `offset` parameter as needed
- Example API responses under .helper_files/bsd_api
- Key APIs:
 - https://sports.bzzoiro.com/api/v2/leagues - returns a collection of leagues/competitions, e.g. `.helper_files/bsd_api/leagues.json`
 - https://sports.bzzoiro.com/api/v2/leagues/:id - returns data for a given league competition, .e.g: `.helper_files/bsd_api/leagues_id.json`
 - https://sports.bzzoiro.com/api/v2/leagues/:id/standings - returns the league table or group standings for a given league competition, e.g. `.helper_files/bsd_api/leagues_id_standings.json`
 - https://sports.bzzoiro.com/api/v2/teams/:id - maps team IDs to names, e.g. `.helper_files/bsd_api/teams_id.json` - note for competitions such as the World Cup where future fixtures are not yet determined, they may not represent real teams (e.g. `W101`)
 - https://sports.bzzoiro.com/api/v2/events?league_id=:league_id&status=:status - gets matches (called `events` in BSD speak) by the given league ID (e.g. 27 for World Cup) and status (`notstarted` for upcoming fixtures, `finished` for results), e.g. `.helper_files/bsd_api/events.json`
 - https://sports.bzzoiro.com/api/v2/events/live - live matches in progress, e.g. `.helper_files/bsd_api/events_live.json` - should be polled regularly when matches are in progress, e.g. every 10s
 - https://sports.bzzoiro.com/api/v2/events/:id - information on a given match, e.g. `.helper_files/bsd_api/events_id.json`
 - https://sports.bzzoiro.com/api/v2/events/:id/incidents - match details such as goal scorers, cards, assists, etc, e.g. `.helper_files/bsd_api/events_id_incidents.json` and `.helper_files/bsd_api/events_id_incidents_2.json` - should be polled regularly when matches are in progress, e.g. every 30s
 - https://sports.bzzoiro.com/api/v2/events/:id/lineups - player lineups for a given match, e.g. `.helper_files/bsd_api/events_id_lineups.json`
 - https://sports.bzzoiro.com/api/v2/players/:id - details on a given player, e.g. `.helper_files/bsd_api/players_id.json`

An MCP is available here for implementation questions and information: https://sports.bzzoiro.com/mcp

Standard HTTP response codes will indicate the success or failure of calls, including HTTP 429 responses for rate limiting. This should be catered for with a strategy around exponential backoff + retry logic.

## API authentication

This header should be added to every request:
`Authorization: Token BSD_API_KEY`

In Production, the `BSD_API_KEY` environment variable will be used to determine the value of `BSD_API_KEY`

### Match details

Match details are populated using the events/:id/incidents API, e.g.: https://sports.bzzoiro.com/api/v2/events/8324/incidents

Example goal with assist:

```json
{
    "type": "goal",
    "assist": "M. Araújo",
    "minute": 45,
    "player": "A. Canobbio",
    "is_home": true,
    "goal_type": "regular",
    "player_id": 2908,
    "added_time": 6,
    "away_score": 1,
    "home_score": 2
}
```

Example yellow card:

```json
{
    "type": "card",
    "minute": 33,
    "player": "S. Ezatolahi",
    "is_home": false,
    "card_type": "yellow",
    "player_id": 53951,
    "added_time": null
}
```

Example red card:

```json
{
    "type": "card",
    "minute": 67,
    "player": "N. Ngoy",
    "is_home": true,
    "card_type": "red",
    "player_id": 1447,
    "added_time": null
}
```

Example VAR decision of goal being disallowed:

```json
{
    "type": "varDecision",
    "minute": 25,
    "player": "M. Taremi",
    "is_home": false,
    "decision": "goalAwarded",
    "confirmed": false,
    "player_id": 3487
}
```

Example of player substitution:

```json
{
    "type": "substitution",
    "minute": 46,
    "is_home": false,
    "player_in": "A. Jahanbakhsh",
    "added_time": null,
    "player_out": "S. Hardani",
    "player_in_id": 7605,
    "player_out_id": 16837
}
```
