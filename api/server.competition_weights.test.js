const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");

const {
  app,
  __private: {
    buildCompetitionCatalog,
    buildCompetitionWeightsPayload,
  },
} = require("./server");

test("competition weights payload mirrors the competition catalog name and weight pairs", () => {
  assert.deepEqual(buildCompetitionWeightsPayload(), buildCompetitionCatalog());
});

test("GET /api/v1/competitions/weights returns competition names and weights", async () => {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));

  try {
    const address = server.address();
    const response = await fetch(
      `http://127.0.0.1:${address.port}/api/v1/competitions/weights`
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("x-operational-source"), "server_config");
    assert.deepEqual(await response.json(), buildCompetitionWeightsPayload());
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve()))
    );
  }
});
