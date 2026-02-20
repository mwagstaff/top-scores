# Claude Code Instructions

## Build System

- **Never run `xcodebuild` commands** - The user will always run Xcode builds themselves
- Do not attempt to compile or build the iOS/watchOS projects
- Focus on code changes and let the user verify builds in Xcode
- **Never try and start the node API server**, e.g. by running `npm start` or `node server.js` - The user will always start the server themselves
