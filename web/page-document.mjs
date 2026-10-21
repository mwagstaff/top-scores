const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ],
  );
const todayUK = () =>
  new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
const validDate = (value) =>
  /^\d{4}-\d{2}-\d{2}$/.test(value || "") &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;
const ukChannels = (match) => [
  ...new Set(
    (match.tv_channels || [])
      .filter(
        (channel) =>
          /^(GB|UK)$/i.test(channel.countryCode || "") ||
          /^(United Kingdom|UK)$/i.test(channel.country || "") ||
          (!channel.countryCode &&
            !channel.country &&
            /\b(bbc|itv|sky sports|tnt sports|premier sports|uk)\b/i.test(
              channel.name || "",
            )),
      )
      .map((channel) => channel.name.replace(/\s*\(UK\)$/i, "")),
  ),
];
const ukRelevant = (match) =>
  ukChannels(match).length ||
  /^(UEFA (?:Champions|Europa|Conference) League|FIFA World Cup|UEFA European Championship|Premier League|(?:EFL )?Championship|(?:EFL )?League (?:One|Two)|FA Cup|EFL Cup|Carabao Cup|Scottish |Women.s Super League|WSL|National League)/i.test(
    match.league || "",
  ) ||
  /^(England|Scotland|Wales|Northern Ireland)(?: Women)?$/i.test(
    match.home_team || "",
  ) ||
  /^(England|Scotland|Wales|Northern Ireland)(?: Women)?$/i.test(
    match.away_team || "",
  );
const matchLink = (match) =>
  `/matches/${encodeURIComponent(match.match_details_id || [match.date, match.time, match.league, match.home_team, match.away_team].join("|"))}?date=${match.date}`;

// A bounded, short-lived cache serves public HTML and its matching client seed.
// Preferences stay in the browser and never enter a shared server cache.
export function createPageRenderer(apiBaseUrl, renderContent) {
  const cache = new Map();
  const pending = new Map();
  async function data(path) {
    const cached = cache.get(path);
    if (cached && Date.now() - cached.time < 10_000) return cached;
    if (pending.has(path)) return pending.get(path);
    const work = (async () => {
      const response = await fetch(`${apiBaseUrl}${path}`, {
        signal: AbortSignal.timeout(1800),
      });
      if (!response.ok)
        return cached && (response.status >= 500 || response.status === 429)
          ? { ...cached, stale: true }
          : { status: response.status };
      const value = {
        value: await response.json(),
        status: 200,
        time: Date.now(),
        hasMore: response.headers.get("X-Has-More") === "true",
        lastUpdated: response.headers.get("X-Last-Updated"),
      };
      cache.delete(path);
      cache.set(path, value);
      while (cache.size > 64) cache.delete(cache.keys().next().value);
      return value;
    })()
      .catch(() => (cached ? { ...cached, stale: true } : { status: 503 }))
      .finally(() => pending.delete(path));
    pending.set(path, work);
    return work;
  }
  return async function render(template, originalUrl, origin) {
    const url = new URL(originalUrl, origin);
    let title = "Live scores & fixtures",
      description =
        "Football scores, fixtures and where to watch live in the UK. Follow today’s football with Top Scores.";
    let content = "",
      seed = null,
      status = 200;
    const date = validDate(url.searchParams.get("date"))
      ? url.searchParams.get("date")
      : url.pathname === "/results" ||
          (url.pathname.startsWith("/competitions/") &&
            url.searchParams.get("section") === "results")
        ? new Date(Date.parse(`${todayUK()}T12:00:00Z`) - 86400000)
            .toISOString()
            .slice(0, 10)
        : todayUK();
    const matchRoute = /^\/matches\/([^/]+)$/.exec(url.pathname);
    const competitionRoute = /^\/competitions\/([^/]+)$/.exec(url.pathname);
    if (matchRoute) {
      const id = decodeURIComponent(matchRoute[1]);
      let result;
      if (id.includes("|") && validDate(id.split("|")[0])) {
        const day = id.split("|")[0];
        const payload = await data(
          `/matches?${new URLSearchParams({ start: day, end: day, time_zone: "Europe/London", page_size: "200", page: "1", sort: "asc" })}`,
        );
        const match = payload.value?.find?.(
          (match) =>
            [
              match.date,
              match.time,
              match.league,
              match.home_team,
              match.away_team,
            ].join("|") === id,
        );
        result = match
          ? { ...payload, value: match }
          : { status: payload.status === 200 ? 404 : payload.status };
      } else
        result = await data(
          `/matches/${encodeURIComponent(id)}?time_zone=Europe%2FLondon`,
        );
      if (result.value) {
        const match = result.value;
        seed = { match, fetchedAt: result.time };
        title = `${match.home_team} v ${match.away_team}`;
        description = `${title}: ${match.league}, ${match.date} at ${match.time} UK. Scores, match updates and UK TV coverage.`;
        content = `<p><a href="/fixtures?date=${escape(match.date)}">← Back to matches</a></p><h1>${escape(title)}</h1><p>${escape(match.league)} · ${escape(match.date)} · ${escape(match.time)} UK</p><h2>${match.home_score != null ? `${escape(match.home_score)} – ${escape(match.away_score)}` : escape(match.time)}</h2><p>${escape(match.score_status || "Upcoming")}</p><h2>Where to watch in the UK</h2><p>${escape(ukChannels(match).join(" · ") || "No UK broadcast confirmed.")}</p>`;
      } else {
        title = "Match unavailable";
        content =
          "<h1>Match unavailable</h1><p>Return to the fixtures or try again shortly.</p>";
        status = result.status === 404 || result.status === 400 ? 404 : 503;
      }
    } else if (
      ["/", "/fixtures", "/tv", "/results"].includes(url.pathname) ||
      competitionRoute
    ) {
      const competition = competitionRoute
        ? decodeURIComponent(competitionRoute[1])
        : null;
      title =
        competition ||
        (url.pathname === "/tv"
          ? "Football on UK TV"
          : url.pathname === "/results"
            ? "Football results"
            : title);
      description = `${title}. Fixtures, results and UK broadcast information on Top Scores.`;
      const query = new URLSearchParams({
        start: date,
        end: date,
        time_zone: "Europe/London",
        page_size: "200",
        page: "1",
        sort: "asc",
      });
      const result = await data(`/matches?${query}`);
      content = `<h1>${escape(title)}</h1><p>${escape(date)} · All times UK</p>`;
      if (Array.isArray(result.value)) {
        seed = {
          date,
          matches: result.value,
          fetchedAt: result.time,
          hasMore: result.hasMore,
          lastUpdated: result.lastUpdated,
        };
        const matches = result.value.filter(
          (match) =>
            (competition
              ? match.league === competition
              : url.searchParams.get("scope") === "all" || ukRelevant(match)) &&
            (url.pathname !== "/tv" || ukChannels(match).length) &&
            (url.pathname !== "/results" ||
              ["FT", "AET", "PENS"].includes(match.score_status)),
        );
        let league = "";
        for (const match of matches) {
          if (match.league !== league) {
            league = match.league;
            content += `<h2><a href="/competitions/${encodeURIComponent(league)}">${escape(league)}</a></h2>`;
          }
          content += `<a class="server-fixture" href="${escape(matchLink(match))}"><time>${escape(match.score_status || match.time)}</time><strong>${escape(match.home_team)} ${match.home_score != null ? `${escape(match.home_score)} – ${escape(match.away_score)}` : "v"} ${escape(match.away_team)}</strong><span>${escape(ukChannels(match).join(" · "))}</span></a>`;
        }
        if (!matches.length)
          content +=
            "<p>No matches for this selection. Choose another date in the fixture list.</p>";
      } else
        content +=
          "<p>Scores are temporarily unavailable. Please try again.</p>";
    } else if (url.pathname === "/tables") {
      title = "League tables";
      content = "<h1>League tables</h1><p>Standings and live positions.</p>";
    } else if (url.pathname === "/preferences") {
      title = "Preferences";
      content =
        "<h1>Preferences</h1><p>Choose your teams, competitions and channels.</p>";
    } else {
      title = "Page not found";
      content =
        "<h1>Page not found</h1><a href='/fixtures'>Back to football</a>";
      status = 404;
    }
    const canonical = `${origin}${url.pathname === "/" ? "/fixtures" : url.pathname}${validDate(url.searchParams.get("date")) && !matchRoute ? `?date=${date}` : ""}`;
    const head = `<link rel="canonical" href="${escape(canonical)}"><meta property="og:title" content="${escape(title)} · Top Scores"><meta property="og:description" content="${escape(description)}"><meta property="og:url" content="${escape(canonical)}"><meta property="og:image" content="${escape(origin)}/generated-assets/apple-touch-icon.png">${status !== 200 ? '<meta name="robots" content="noindex">' : ""}`;
    let root = `<div class="server-page"><a class="wordmark" href="/fixtures">top scores.</a><nav aria-label="Primary"><a href="/fixtures">Scores & fixtures</a><a href="/tv">On UK TV</a><a href="/results">Results</a><a href="/tables">Tables</a></nav><main>${content}</main></div>`;
    if (renderContent && status === 200) {
      seed = {
        ...seed,
        fetchedAt: seed?.fetchedAt || Date.now(),
        rendered: true,
      };
      root = await renderContent(originalUrl, seed);
    }
    const html = template
      .replace(
        /<title>.*?<\/title>/s,
        `<title>${escape(title)} · Top Scores</title>`,
      )
      .replace(
        /(<meta\s+name="description"\s+content=")[^"]*/s,
        `$1${escape(description)}`,
      )
      .replace("</head>", `${head}</head>`)
      .replace(
        '<div id="root"></div>',
        `<div id="root">${root}</div><script id="football-seed" type="application/json">${JSON.stringify(seed).replace(/</g, "\\u003c")}</script>`,
      );
    return { html, status };
  };
}
