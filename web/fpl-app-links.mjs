import { randomBytes } from 'node:crypto';

export function registerFantasyAppLinks(app) {
  app.get('/.well-known/apple-app-site-association', (_req, res) => {
    res.set('Cache-Control', 'public, max-age=3600').json({ applinks: { details: [{
      appIDs: ['SJ8X4DLAN9.topscores.dev.skynolimit'],
      components: [{ '/': '/fpl/connect', comment: 'Approve a website FPL pairing request in Top Scores.' }],
    }] } });
  });
  // Universal Links open the installed app. This page is the fallback when the
  // app is absent, outdated, or the user has chosen to open links in Safari.
  app.get('/fpl/connect', (_req, res) => {
    const nonce = randomBytes(16).toString('base64');
    res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
      'Content-Security-Policy': `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; base-uri 'none'; frame-ancestors 'none'` });
    res.type('html').send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Connect Top Scores</title><style nonce="${nonce}">body{margin:0;background:#04080c;color:#e8eef6;font:18px/1.6 system-ui}main{max-width:500px;margin:10vh auto;padding:24px}h1{font-size:30px}a{display:inline-block;color:#04080c;background:#2aa8ff;padding:12px 20px;border-radius:8px;text-decoration:none}p{color:#aebed0}[hidden]{display:none}</style></head><body><main><h1>Connect your FPL setup</h1><p id="message">Open Top Scores to approve the browser waiting on your other screen. The website will update automatically.</p><a id="open" hidden>Open Top Scores</a><p>Requires an app version with website pairing. If the app opens without a connection prompt, update it and scan the QR code again.</p></main><script nonce="${nonce}">const values=new URLSearchParams(location.hash.slice(1));const secret=values.get('pair');history.replaceState(null,'',location.pathname);if(secret&&/^[A-Za-z0-9_-]{43}$/.test(secret)){const link=document.getElementById('open');link.href='topscores://fpl-connect#pair='+encodeURIComponent(secret);link.hidden=false}else{document.getElementById('message').textContent='This pairing link is invalid. Generate a new QR code on the website.'}</script></body></html>`);
  });
}
