# Agent Instructions

- Do not run Xcode builds (`xcodebuild`) in this repository.
- The user runs builds manually in Xcode.
- For admin pages and API URLs, always account for proxy routing. Derive an `API_BASE_PREFIX` from the current pathname so deployed URLs resolve under `/top-scores` when served via `api.skynolimit.dev`.
- Live Activity widget code must stay highly performant: keep render bodies synchronous and cheap, do not add `.task`/async calls, network calls, file I/O, resolver scans, or runtime asset discovery in the Live Activity render path.
