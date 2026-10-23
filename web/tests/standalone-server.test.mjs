import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

test("bundled broadcast rules work without a sibling API checkout", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "top-scores-standalone-"));
  try {
    for (const name of ["broadcast_priorities.cjs", "tv_provider_priorities.json"]) {
      await fs.copyFile(new URL(`../server-shared/${name}`, import.meta.url), path.join(directory, name));
    }
    const { default: rules } = await import(pathToFileURL(path.join(directory, "broadcast_priorities.cjs")));
    try {
      assert.deepEqual(rules.broadcastPriorities.order(["HBO Max", "TNT Sports 2"]), ["TNT Sports 2", "HBO Max"]);
      assert.equal(await fs.readFile(new URL("../server-shared/broadcast_priorities.cjs", import.meta.url), "utf8"),
        await fs.readFile(new URL("../../api/broadcast_priorities.js", import.meta.url), "utf8"));
    } finally { rules.broadcastPriorities.close(); }
  } finally { await fs.rm(directory, { recursive: true, force: true }); }
});
