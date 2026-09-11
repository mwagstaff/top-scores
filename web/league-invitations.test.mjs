import test from "node:test";
import assert from "node:assert/strict";
import { associationDocument, invitationCode, invitationPage, registerLeagueInvitationRoutes } from "./league-invitations.mjs";

test("links only accept the invitation alphabet", () => {
  assert.equal(invitationCode("abcdefgh2345"), "ABCDEFGH2345");
  for (const value of [null, "ABCD0123IOL5", "ABCDEFGH2345/members", '<script>alert(1)</script>']) assert.equal(invitationCode(value), null);
});

test("public preview does not fetch private data or automatically join", () => {
  const page = invitationPage("ABCDEFGH2345", "testNonce");
  assert.match(page, /topscores:\/\/invite\/ABCDEFGH2345/);
  assert.match(page, /id6502705973/);
  assert.match(page, /My Leagues/);
  assert.doesNotMatch(page, /fetch\(|XMLHttpRequest|playerId|standings|leagueName|window.location/);
  const invalid = invitationPage('<script>alert(1)</script>', "testNonce");
  assert.doesNotMatch(invalid, /alert\(1\)|topscores:\/\/invite/);
});

test("AASA scopes links to invitations and correct app", () => {
  const details = associationDocument().applinks.details;
  assert.deepEqual(details[0].appIDs, ["SJ8X4DLAN9.topscores.dev.skynolimit"]);
  assert.equal(details[0].components[0]["/"], "/invite/*");
});

test("preview routes have privacy headers and no mutation route", () => {
  const routes = new Map();
  registerLeagueInvitationRoutes({ get: (path, handler) => routes.set(path, handler) });
  assert.equal(routes.size, 2);
  let status, body; const headers = {};
  const response = {
    set(values) { Object.assign(headers, values); return this; },
    status(value) { status = value; return this; },
    type() { return this; },
    send(value) { body = value; return this; },
  };
  routes.get("/invite/:code")({ params: { code: "ABCDEFGH2345" } }, response);
  assert.equal(status, 200);
  assert.equal(headers["Cache-Control"], "no-store, private");
  assert.equal(headers["Referrer-Policy"], "no-referrer");
  assert.match(headers["Content-Security-Policy"], /frame-ancestors 'none'/);
  assert.match(body, /Your crowd/);
  routes.get("/invite/:code")({ params: { code: "invalid" } }, response);
  assert.equal(status, 404);
});
