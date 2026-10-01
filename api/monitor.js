require("./runtime_logging").installTimestampedConsole();
const { startMonitorRuntime, installRuntimeSignalHandlers } = require("./server");

startMonitorRuntime();
installRuntimeSignalHandlers();
