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
