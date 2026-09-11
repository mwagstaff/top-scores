"use strict";
// Mongo contract fake reused by private-league permission and recovery tests.
function database(initial = {}, now = () => Date.now()) {
  const tables = new Map(Object.entries(initial).map(([name, rows]) => [name, rows.map((row) => structuredClone(row))]));
  const get = (row, key) => key.split(".").reduce((value, part) => value?.[part], row);
  function compare(actual, expected) {
    if (expected == null) return actual == null;
    if (typeof expected !== "object" || expected instanceof Date) return expected instanceof Date ? +actual === +expected : Array.isArray(actual) ? actual.some((item) => item === expected) : actual === expected;
    return Object.entries(expected).every(([operator, value]) => {
      if (operator === "$exists") return (actual !== undefined) === value;
      if (operator === "$in") return value.some((v) => Array.isArray(actual) ? actual.some((item) => compare(item, v)) : compare(actual, v));
      if (operator === "$ne") return !compare(actual, value);
      if (operator === "$lt") return actual < value;
      if (operator === "$lte") return actual <= value;
      if (operator === "$gt") return actual > value;
      if (operator === "$gte") return actual >= value;
      throw Error(`Unsupported test query ${operator}`);
    });
  }
  function matches(row, filter) {
    return Object.entries(filter).every(([key, value]) => {
      if (key === "$or") return value.some((clause) => matches(row, clause));
      if (key === "$expr") return now() < +value.$lt[1];
      return compare(get(row, key), value);
    });
  }
  return {
    tables,
    collection(name) {
      if (!tables.has(name)) tables.set(name, []);
      const rows = tables.get(name);
      const collection = {
        async findOne(filter) { return structuredClone(rows.find((row) => matches(row, filter)) || null); },
        find(filter = {}) {
          let found = rows.filter((row) => matches(row, filter)).map((row) => structuredClone(row));
          const cursor = {
            sort(order) { found.sort((a, b) => { for (const [key, direction] of Object.entries(order)) { if (a[key] < b[key]) return -direction; if (a[key] > b[key]) return direction; } return 0; }); return cursor; },
            limit(size) { found = found.slice(0, size); return cursor; },
            skip(size) { found = found.slice(size); return cursor; },
            batchSize() { return cursor; },
            async toArray() { return found; },
            async *[Symbol.asyncIterator]() { for (const row of found) yield row; },
          };
          return cursor;
        },
        async countDocuments(filter) { return rows.filter((row) => matches(row, filter)).length; },
        async insertOne(row) {
          if (rows.some((r) => r._id === row._id)) throw Object.assign(Error("duplicate"), { code: 11000 });
          rows.push(structuredClone(row)); return { insertedId: row._id };
        },
        async updateOne(filter, update, options = {}) {
          if (filter.$expr && options.upsert) throw Error("$expr is not allowed in the query predicate for an upsert");
          let row = rows.find((r) => matches(r, filter)); const existed = Boolean(row);
          if (!row && options.upsert) {
            row = Object.fromEntries(Object.entries(filter).filter(([, value]) => typeof value !== "object" || value === null));
            await collection.insertOne(row); row = rows.at(-1);
          }
          if (!row) return { matchedCount: 0, modifiedCount: 0, upsertedCount: 0 };
          if (!existed) Object.assign(row, structuredClone(update.$setOnInsert || {}));
          Object.assign(row, structuredClone(update.$set || {}));
          for (const [key, amount] of Object.entries(update.$inc || {})) row[key] = (row[key] || 0) + amount;
          return { matchedCount: existed ? 1 : 0, modifiedCount: existed ? 1 : 0, upsertedCount: existed ? 0 : 1 };
        },
        async updateMany(filter, update) { for (const row of rows.filter((r) => matches(r, filter))) await collection.updateOne({ _id: row._id }, update); },
        async deleteOne(filter) { const index = rows.findIndex((r) => matches(r, filter)); if (index >= 0) rows.splice(index, 1); },
      };
      return collection;
    },
  };
}

module.exports = { database };
