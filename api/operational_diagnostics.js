"use strict";

// Shared context links Redis reads to their calling refresh/reconciliation.
module.exports = require("./bsd_diagnostics").createDiagnostics({
  write: (record) => console.info(`[operational-diagnostics] ${JSON.stringify(record)}`),
});
