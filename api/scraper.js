require("./runtime_logging").installTimestampedConsole();
const { startScraperRuntime, installRuntimeSignalHandlers } = require("./server");

startScraperRuntime();
installRuntimeSignalHandlers();
