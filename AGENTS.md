# Agent Instructions

- Do not run Xcode builds (`xcodebuild`) in this repository.
- The user runs builds manually in Xcode.
- For admin pages and API URLs, always account for proxy routing. Derive an `API_BASE_PREFIX` from the current pathname so deployed URLs resolve under `/top-scores` when served via `api.skynolimit.dev`.
