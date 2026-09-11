import { randomBytes } from "node:crypto";

const invitationPattern = /^[A-HJ-NP-Z2-9]{12}$/;
const appStoreURL = "https://apps.apple.com/app/top-scores/id6502705973";

export function invitationCode(value) {
  const code = typeof value === "string" ? value.toUpperCase() : "";
  return invitationPattern.test(code) ? code : null;
}

export function associationDocument(appID = "SJ8X4DLAN9.topscores.dev.skynolimit") {
  return {
    applinks: {
      details: [{ appIDs: [appID], components: [{ "/": "/invite/*", comment: "Open private league invitation previews in Top Scores." }] }],
    },
  };
}

// This public page deliberately never looks up a league or redeems an invitation.
// Messaging-app previews, crawlers and people without membership see only generic copy.
export function invitationPage(code, nonce) {
  const valid = invitationCode(code);
  const formatted = valid?.match(/.{4}/g).join(" – ");
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive"><meta name="referrer" content="no-referrer">
<meta name="theme-color" content="#071321"><meta property="og:title" content="You're invited · Top Scores">
<meta property="og:description" content="Your people. Your predictions. Your league.">
<title>${valid ? "You're invited" : "Invitation not found"} · Top Scores</title>
<style nonce="${nonce}">
*{box-sizing:border-box}html{color-scheme:dark}body{margin:0;background:#071321;color:#f3f7fc;font-family:ui-rounded,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;min-height:100svh;display:grid;place-items:center;padding:clamp(24px,5vw,64px)}
main{width:min(100%,960px)}.brand{display:flex;align-items:center;gap:10px;font-weight:750;letter-spacing:.03em;margin-bottom:clamp(48px,10vh,100px)}.brand span{color:#ffd15b}.layout{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(280px,.9fr);gap:clamp(32px,6vw,80px);align-items:center}.eyebrow{color:#ffd15b;font-size:.8rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase}h1{font-size:clamp(2.8rem,6vw,4.8rem);line-height:1.02;letter-spacing:-.035em;margin:18px 0 24px;font-weight:850}p{color:#b9ccdf;font-size:1.12rem;line-height:1.6;margin:0 0 22px}.ticket{border:1px solid #294258;border-radius:24px;overflow:hidden;background:#0e2132}.pitch{height:154px;background:repeating-linear-gradient(90deg,#123c30 0 12.5%,#153f33 12.5% 25%);position:relative;display:grid;place-items:center;border-bottom:1px solid #294258}.pitch:before{content:"";position:absolute;inset:17px;border:1px solid #8ac8a84d;border-radius:2px}.pitch:after{content:"";position:absolute;inset:17px 50%;border-left:1px solid #8ac8a84d}.ball{font-size:4.3rem;position:relative;z-index:1;filter:drop-shadow(0 7px 4px #001e1480)}.ticket-body{padding:28px}.code-label{font-size:.75rem;letter-spacing:.13em;text-transform:uppercase;color:#b9ccdf;font-weight:700}.code{display:block;font-size:clamp(1.1rem,2.6vw,1.45rem);font-weight:750;letter-spacing:.12em;margin:12px 0 20px;font-variant-numeric:tabular-nums;user-select:all}a,button{font:inherit}a{text-decoration:none}button{cursor:pointer}.primary{display:block;width:100%;padding:16px;border:0;border-radius:14px;background:#167cf3;color:#f3f7fc;text-align:center;font-weight:750;min-height:52px}.secondary{display:block;color:#cfe3fa;text-align:center;padding:14px 8px;min-height:48px}.copy{padding:0;border:0;background:none;color:#ffd15b;font-size:.92rem;min-height:44px;text-align:left}.small{font-size:.86rem;line-height:1.55;margin:18px 0 0}.footer{margin-top:clamp(40px,8vh,72px);font-size:.86rem;color:#8ca6bd}a:focus-visible,button:focus-visible{outline:3px solid #ffd15b;outline-offset:4px}@media(max-width:660px){.layout{grid-template-columns:1fr}.brand{margin-bottom:40px}.pitch{height:115px}h1{max-width:10ch}.ticket-body{padding:24px}.footer{margin-top:32px}}@media(prefers-reduced-motion:no-preference){.primary{transition:background .15s}.primary:hover{background:#086ad8}}
</style></head><body><main>
<div class="brand"><span aria-hidden="true">⚽</span> TOP SCORES</div>
<div class="layout"><section><div class="eyebrow">Invitation-only mini-leagues</div>
<h1>${valid ? "Your crowd.<br>Your league." : "This invite<br>missed the target."}</h1>
<p>${valid ? "A little football knowledge. A lot of bragging rights. Predict the scores and take on your friends in a league of your own." : "Check the link or ask your league owner to share a fresh invitation."}</p>
<p class="small">Same matches. Same scoring. Your predictions count across every eligible league.</p></section>
<section class="ticket" aria-label="League invitation"><div class="pitch" aria-hidden="true"><span class="ball">⚽</span></div><div class="ticket-body">
${valid ? `<div class="code-label">Your invitation code</div><strong class="code" id="invite-code">${formatted}</strong><a class="primary" href="topscores://invite/${valid}">Open in Top Scores ↗</a><button class="copy" id="copy-code" type="button">Copy invitation code</button><span id="copy-status" role="status" aria-live="polite"></span><p class="small">New here? Get the app, then enter this code in <strong>Beat the AI → My Leagues → Join League</strong>. Game Center takes care of sign-in.</p>` : `<p>The invitation code in this link isn't valid.</p>`}
<a class="secondary" href="${appStoreURL}" rel="noreferrer">Get Top Scores on the App Store ↗</a>
</div></section></div><p class="footer">Your league stays private. Invitation links expire after 7 days and can be revoked by the owner.</p>
</main>${valid ? `<script nonce="${nonce}">document.getElementById("copy-code").addEventListener("click",async()=>{const s=document.getElementById("copy-status");try{await navigator.clipboard.writeText("${valid}");s.textContent=" Copied!";}catch{s.textContent=" Select the code above to copy it.";}});</script>` : ""}</body></html>`;
}

export function registerLeagueInvitationRoutes(app, options = {}) {
  const appID = options.appID || process.env.TOP_SCORES_ASSOCIATED_APP_ID || "SJ8X4DLAN9.topscores.dev.skynolimit";
  if (!/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(appID)) throw new Error("Invalid associated app identifier");
  app.get("/.well-known/apple-app-site-association", (_req, res) => {
    res.set("Cache-Control", "public, max-age=3600").type("application/json").json(associationDocument(appID));
  });
  app.get("/invite/:code", (req, res) => {
    const code = invitationCode(req.params.code);
    const nonce = randomBytes(18).toString("base64");
    res.set({
      "Cache-Control": "no-store, private",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex, nofollow, noarchive",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
    }).status(code ? 200 : 404).type("html").send(invitationPage(code, nonce));
  });
}
