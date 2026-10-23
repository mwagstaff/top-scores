# Top Scores Web

React + Express web client for the existing Top Scores API.

## Run

```bash
cd /Users/mwagstaff/dev/top-scores/web
npm install
npm run dev
```

The web server defaults to `http://localhost:3011/api/v1`.

If you want a different backend:

```bash
TOP_SCORES_API_BASE_URL=https://api.skynolimit.dev/top-scores/api/v1 npm run dev
```

## Screens

- `Fixtures`
- `Results`
- `Preferences`

Preferences are stored in local browser storage under `top-scores.web.preferences.v1`.


## Redesign and production build

See [the frontend design contract](../docs/FRONTEND_DESIGN.md) for colour, layout, interaction and performance requirements.

Routes: `/fixtures`, `/tv`, `/results`, `/tables`, `/preferences`, `/matches/:id`, and `/competitions/:name`. Dates and competition sections are linkable query parameters. All football times use Europe/London.

`npm run build` creates both the client `dist/` and the React server bundle `dist-server/`. Deploy both alongside `server.mjs`, `page-document.mjs`, `artwork.mjs` and `team-logos.mjs`; do not deploy only `dist/`. `sharp` is a production dependency for bounded, cached artwork variants. The test runner uses native TypeScript/module hooks; use Node 26, as used for validation.

Run `npm run check` and `npm test` before building. `npm start` starts the website, using the existing API; never start the Node API as part of website testing. Public initial fixture data has a bounded 10-second server cache. Browser preferences remain private to local storage. Set `TOP_SCORES_WEB_ORIGIN` when the canonical production origin changes.
