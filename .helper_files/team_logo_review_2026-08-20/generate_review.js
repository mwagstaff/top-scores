#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const outputDirectory = __dirname;
const imagesDirectory = path.join(outputDirectory, "images");
const missingLogosURL =
  "https://api.skynolimit.dev/top-scores/api/v1/audit/missing-team-logos";
const badgeCatalogURL =
  "https://api.skynolimit.dev/top-scores/api/v1/teams/badges";

const aliasTargets = {
  "AC Sparta Praha": "Sparta Prague",
  "AD Ceuta": "Ceuta",
  "AGF": "AGF Aarhus",
  "Albacete Balompié": "Albacete",
  "Baník Ostrava": "Baník Ostrava",
  "Betis C.F.": "Real Betis",
  "Breidablik Kópavogur": "Breidablik",
  "BSC Young Boys": "Young Boys",
  "Burgos Club de Fútbol": "Burgos",
  "Caudal Deportivo": "Caudal",
  "CD Alberite": "Alberite",
  "CD Atlético Baleares": "Atlético Baleares",
  "CD Castellón": "Castellón",
  "CD Cieza": "Cieza",
  "CD Ciudad de Lucena": "Ciudad de Lucena",
  "CD Ebro": "Ebro",
  "CD Eldense": "Eldense",
  "CD Estepona": "Estepona",
  "CD Extremadura": "Extremadura",
  "CD Getxo": "Getxo",
  "CD Lourdes": "Lourdes",
  "CD Quintanar Del Rey": "Quintanar del Rey",
  "CD Roda": "Roda",
  "CD Sant Jordi": "Sant Jordi",
  "CD Tenerife": "Tenerife",
  "CD Teruel": "Teruel",
  "CD Toledo": "Toledo",
  "CD Tropezón": "Tropezón",
  "CD Yuncos": "Yuncos",
  "CDA Navalcarnero": "Navalcarnero",
  "CE Constància": "Constància",
  "CE Sabadell": "Sabadell",
  "CF Talavera": "Talavera de la Reina",
  "CFR 1907 Cluj": "CFR Cluj",
  "Club Deportivo Azuaga": "Azuaga",
  "CP Cacereño": "Cacereño",
  "Deportivo de La Coruña": "Deportivo de A Coruña",
  "ETO FC Győr": "Győri ETO",
  "FC Internazionale Milano": "Inter Milan",
  "FC København": "Copenhagen",
  "FC La Union Atletico": "La Unión Atlético",
  "FC Prishtina": "Prishtina",
  "FC St. Gallen 1879": "St. Gallen",
  "FCI Levadia Tallinn": "Levadia Tallinn",
  "FK Aktobe": "Aktobe",
  "FK Budućnost Podgorica": "Budućnost",
  "FK Sutjeska Nikšić": "Sutjeska",
  "FK Vardar Skopje": "Vardar",
  "Fredrikstad FK": "Fredrikstad",
  "Gimnàstic de Tarragona": "Gimnàstic",
  "HNK Rijeka": "Rijeka",
  "Hemel Hempstead": "Hemel Hempstead Town",
  "IF Vestri": "Vestri",
  "Julio Suarez Universitario CF": "Universitario FC",
  "KF Egnatia": "Egnatia",
  "KF Shkëndija": "Shkëndija",
  "Klaksvíkar Ítróttarfelag": "KÍ Klaksvík",
  "Kuopion Palloseura": "KuPS",
  "Lillestrøm SK": "Lillestrøm",
  "Liverpool Reds": "Liverpool",
  "Malmö FF": "Malmö",
  "Mérida AD": "Mérida",
  "Mjällby AIF": "Mjällby",
  "ML Vitebsk": "Maxline Vitebsk",
  "MŠK Žilina": "Žilina",
  "Naxara CD": "Náxara",
  "NK Aluminij Kidričevo": "Aluminij",
  "OFI Crete": "OFI",
  "Paksi FC": "Paks",
  "RC Lens": "Lens",
  "Real Avilés": "Real Avilés Industrial",
  "Real Racing Club": "Racing de Santander",
  "Ried": "SV Ried",
  "Royale Union Saint-Gilloise": "Union Saint-Gilloise",
  "RSC Anderlecht": "Anderlecht",
  "RSD Alcalá": "Alcalá",
  "Sabah FK": "Sabah Baku",
  "Salerm Puente Genil": "Puente Genil",
  "SD Negreira": "Negreira",
  "SD Ponferradina": "Ponferradina",
  "SD Tarazona": "Tarazona",
  "SD Textil Escudo": "Textil Escudo",
  "Sigma Olomouc": "Sigma Olomouc",
  "Sint Maarten": "St Maarten",
  "Sint-Truidense VV": "Sint-Truiden",
  "SK Brann": "Brann",
  "SK Sigma Olomouc": "Sigma Olomouc",
  "SK Slavia Praha": "Slavia Prague",
  "Sport Lisboa e Benfica": "Benfica",
  "Sporting Clube de Portugal": "Sporting CP",
  "Sporting de Ceuta": "Sporting Ceuta",
  "SS Virtus": "Virtus",
  "Stade Brestois": "Brest",
  "Stade Rennais": "Rennes",
  "SV 07 Elversberg": "Elversberg",
  "Tromsø IL": "Tromsø",
  "UD Ibiza": "Ibiza",
  "UD Maracena": "Maracena",
  "UD Poblense": "Poblense",
  "UD Samano": "Sámano",
  "UE Sant Andreu": "Sant Andreu",
  "Unión Deportiva Ourense": "UD Ourense",
  "UP Langreo": "Langreo",
};

const discoveredCandidates = {
  "Albirex Niigata": ["Albirex Niigata", "139881", "https://r2.thesportsdb.com/images/media/team/badge/l16fvz1590070788.png"],
  "Athletico Paranaense": ["Athletico Paranaense", "134297", "https://r2.thesportsdb.com/images/media/team/badge/irzu1u1554237406.png"],
  "Atlético Mineiro": ["Atlético Mineiro", "134299", "https://r2.thesportsdb.com/images/media/team/badge/x5lixs1743742872.png"],
  "Bahia": ["Bahia", "134293", "https://r2.thesportsdb.com/images/media/team/badge/xuvtsv1473539308.png"],
  "Baník Ostrava": ["Baník Ostrava", "136684", "https://r2.thesportsdb.com/images/media/team/badge/y1pij41691419087.png"],
  "Botafogo": ["Botafogo", "134285", "https://r2.thesportsdb.com/images/media/team/badge/bs5mbw1733004596.png"],
  "Breidablik Kópavogur": ["Breiðablik", "134347", "https://r2.thesportsdb.com/images/media/team/badge/fkbtng1512142899.png"],
  "BSC Young Boys": ["Young Boys", "134001", "https://r2.thesportsdb.com/images/media/team/badge/9mxdoo1534784569.png"],
  "Chapecoense": ["Chapecoense", "134464", "https://r2.thesportsdb.com/images/media/team/badge/wy0e1i1765900601.png"],
  "CODM Meknès": ["CODM de Meknès", "136417", "https://r2.thesportsdb.com/images/media/team/badge/fp6qrh1580335119.png"],
  "Corinthians": ["Corinthians", "134284", "https://r2.thesportsdb.com/images/media/team/badge/vvuvps1473538042.png"],
  "Coritiba": ["Coritiba", "134298", "https://r2.thesportsdb.com/images/media/team/badge/ywwsyu1473538050.png"],
  "Cruzeiro": ["Cruzeiro", "134294", "https://r2.thesportsdb.com/images/media/team/badge/upsvvu1473538059.png"],
  "FC Prishtina": ["Prishtina", "140101", "https://r2.thesportsdb.com/images/media/team/badge/34hhvh1753897677.png"],
  "FK Aktobe": ["Aktobe", "140520", "https://r2.thesportsdb.com/images/media/team/badge/tt0rtn1751479739.png"],
  "FK Budućnost Podgorica": ["Budućnost Podgorica", "133983", "https://r2.thesportsdb.com/images/media/team/badge/kckpa11579467122.png"],
  "Fluminense": ["Fluminense", "134296", "https://r2.thesportsdb.com/images/media/team/badge/stvvwp1473538082.png"],
  "Fredrikstad FK": ["Fredrikstad", "134749", "https://r2.thesportsdb.com/images/media/team/badge/9se6qv1690695269.png"],
  "Grêmio": ["Grêmio", "134288", "https://r2.thesportsdb.com/images/media/team/badge/uvpwyt1473538089.png"],
  "Hartberg": ["TSV Hartberg", "137805", "https://r2.thesportsdb.com/images/media/team/badge/72c0xg1578833261.png"],
  "Internacional": ["Internacional", "134281", "https://r2.thesportsdb.com/images/media/team/badge/yprvxx1473538097.png"],
  "Mirassol": ["Mirassol", "141181", "https://r2.thesportsdb.com/images/media/team/badge/pw8uo11765900737.png"],
  "Malmö FF": ["Malmö", "134166", "https://r2.thesportsdb.com/images/media/team/badge/429jzd1779940315.png"],
  "Naxara CD": ["Náxara", "144226", "https://r2.thesportsdb.com/images/media/team/badge/jx701u1710993218.png"],
  "Palmeiras": ["Palmeiras", "134465", "https://r2.thesportsdb.com/images/media/team/badge/vsqwqp1473538105.png"],
  "Remo": ["Remo", "137818", "https://r2.thesportsdb.com/images/media/team/badge/u36jfy1579341655.png"],
  "Ried": ["SV Ried", "133993", "https://r2.thesportsdb.com/images/media/team/badge/c1bxyq1583516636.png"],
  "Santos": ["Santos", "134286", "https://r2.thesportsdb.com/images/media/team/badge/j8xk9g1679447486.png"],
  "São Paulo": ["São Paulo", "134291", "https://r2.thesportsdb.com/images/media/team/badge/sxpupx1473538135.png"],
  "Sigma Olomouc": ["Sigma Olomouc", "136677", "https://r2.thesportsdb.com/images/media/team/badge/cbcg021578836711.png"],
  "SK Sigma Olomouc": ["Sigma Olomouc", "136677", "https://r2.thesportsdb.com/images/media/team/badge/cbcg021578836711.png"],
  "Vasco da Gama": ["Vasco da Gama", "134282", "https://r2.thesportsdb.com/images/media/team/badge/ynqlxo1630521109.png"],
  "Vitória": ["Vitória", "134280", "https://r2.thesportsdb.com/images/media/team/badge/tysrrx1473538156.png"],
};

const officialCandidates = {
  "Blau-Weiß Linz": {
    canonical_name: "FC Blau-Weiß Linz",
    candidate_url: "https://upload.wikimedia.org/wikipedia/commons/5/59/FC_Blau-Wei%C3%9F_Linz_%28logo%29.svg",
    source_page: "https://commons.wikimedia.org/wiki/File:FC_Blau-Wei%C3%9F_Linz_%28logo%29.svg",
    source: "Wikimedia Commons / Austrian Bundesliga verification",
  },
  "RB Bragantino": {
    canonical_name: "Red Bull Bragantino",
    candidate_url: "https://img.redbullbragantino.com/images/c_limit,w_4000/e_trim:1:transparent/c_limit,w_512,h_512/bo_5px_solid_rgb:00000000/q_auto:best,f_png/2026/2/9/i1izmjn6ic5ctfogarvs/bragantino-logo",
    source_page: "https://www.redbullbragantino.com/br-pt/",
    source: "Official club website",
  },
  "FC La Union Atletico": {
    canonical_name: "FC La Unión Atlético",
    candidate_url: "https://upload.wikimedia.org/wikipedia/en/b/be/FC_La_Uni%C3%B3n_Atl%C3%A9tico.png",
    source_page: "https://en.wikipedia.org/wiki/File:FC_La_Uni%C3%B3n_Atl%C3%A9tico.png",
    source: "Wikipedia non-free club badge; club ceased activity in July 2026",
    confidence: "review",
  },
  "Yongin City FC": {
    canonical_name: "Yongin FC",
    candidate_url: "https://yonginfc.co.kr/assets/header/logo/yongin-fc-mark.svg",
    source_page: "https://yonginfc.co.kr/",
    source: "Official current Yongin FC website; review mapping from provider name 'Yongin City FC'",
    confidence: "review",
  },
  "Zanzibar": {
    canonical_name: "Zanzibar national football team",
    candidate_url: "https://upload.wikimedia.org/wikipedia/commons/d/d4/Flag_of_Zanzibar.svg",
    source_page: "https://en.wikipedia.org/wiki/Zanzibar_national_football_team",
    source: "Wikimedia flag used by the national-team page; no distinct crest verified",
    confidence: "review",
  },
};

const duplicateCanonicalNames = {
  "Albacete Balompié": "Albacete",
  "Burgos Club de Fútbol": "Burgos",
  "Deportivo de La Coruña": "Deportivo de A Coruña",
  "FC Noah": "Noah",
  "KF Shkëndija": "Shkendija",
  "NK Celje": "Celje",
  "Real Racing Club": "Racing de Santander",
  "SK Sigma Olomouc": "Sigma Olomouc",
};

function normalizedName(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function catalogKey(value) {
  const stopWords = new Set([
    "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
    "club", "de", "the", "and", "atletico", "athletic", "sporting",
  ]);
  return normalizedName(value)
    .split(/\s+/)
    .filter(Boolean)
    .filter((token) => !stopWords.has(token))
    .join("");
}

function escaped(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function safeFileName(value) {
  return normalizedName(value).replace(/\s+/g, "-") || "candidate";
}

async function fetchJSON(url) {
  const response = await fetch(url, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return response.json();
}

async function downloadCandidate(row, index) {
  if (!row.candidate_url) return null;
  const parsedURL = new URL(row.candidate_url);
  const sourceExtension = path.extname(parsedURL.pathname).toLowerCase();
  const extension = [".png", ".svg", ".jpg", ".jpeg", ".webp"].includes(sourceExtension)
    ? sourceExtension
    : ".png";
  const fileName = `${String(index + 1).padStart(3, "0")}-${safeFileName(row.reported_name)}${extension}`;
  const destination = path.join(imagesDirectory, fileName);
  try {
    const response = await fetch(row.candidate_url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    fs.writeFileSync(destination, Buffer.from(await response.arrayBuffer()));
    return `images/${fileName}`;
  } catch (error) {
    row.download_error = String(error.message || error);
    return row.candidate_url;
  }
}

async function main() {
  fs.mkdirSync(imagesDirectory, { recursive: true });
  const [missingNames, badgePayload] = await Promise.all([
    fetchJSON(missingLogosURL),
    fetchJSON(badgeCatalogURL),
  ]);
  const badgeEntries = Object.entries(badgePayload.teams || {}).map(([id, value]) => ({
    id,
    name: value.name,
    badge_url: value.badge_url,
  }));
  const badgesByName = new Map();
  const badgesByKey = new Map();
  for (const badge of badgeEntries) {
    badgesByName.set(normalizedName(badge.name), badge);
    const key = catalogKey(badge.name);
    if (!badgesByKey.has(key)) badgesByKey.set(key, badge);
  }

  const rows = missingNames.map((reportedName) => {
    if (reportedName === "TBC") {
      return {
        reported_name: reportedName,
        canonical_name: "TBC",
        status: "placeholder",
        confidence: "not-applicable",
        candidate_url: null,
        source: "Not a real team",
        source_page: null,
      };
    }

    if (officialCandidates[reportedName]) {
      return {
        reported_name: reportedName,
        status: "candidate",
        confidence: "high",
        ...officialCandidates[reportedName],
      };
    }

    if (discoveredCandidates[reportedName]) {
      const [canonicalName, id, candidateURL] = discoveredCandidates[reportedName];
      return {
        reported_name: reportedName,
        canonical_name: duplicateCanonicalNames[reportedName] || canonicalName,
        status: duplicateCanonicalNames[reportedName] ? "duplicate-alias" : "candidate",
        confidence: "high",
        candidate_url: candidateURL,
        source: "TheSportsDB search result",
        source_page: `https://www.thesportsdb.com/api/v1/json/3/lookupteam.php?id=${id}`,
        source_team_id: id,
      };
    }

    const targetName = aliasTargets[reportedName] || reportedName;
    const badge =
      badgesByName.get(normalizedName(targetName)) ||
      badgesByKey.get(catalogKey(targetName));
    if (!badge || !badge.badge_url) {
      return {
        reported_name: reportedName,
        canonical_name: duplicateCanonicalNames[reportedName] || targetName,
        status: "unresolved",
        confidence: "none",
        candidate_url: null,
        source: null,
        source_page: null,
      };
    }
    return {
      reported_name: reportedName,
      canonical_name: duplicateCanonicalNames[reportedName] || badge.name,
      status: duplicateCanonicalNames[reportedName] ? "duplicate-alias" : "candidate",
      confidence: "high",
      candidate_url: badge.badge_url,
      source: "Live TheSportsDB badge catalog",
      source_page: `https://www.thesportsdb.com/api/v1/json/3/lookupteam.php?id=${badge.id}`,
      source_team_id: badge.id,
    };
  });

  let nextIndex = 0;
  const workerCount = 12;
  async function worker() {
    while (nextIndex < rows.length) {
      const index = nextIndex++;
      rows[index].preview_path = await downloadCandidate(rows[index], index);
    }
  }
  await Promise.all(Array.from({ length: workerCount }, () => worker()));

  const canonicalRealTeams = new Set(
    rows
      .filter((row) => row.status !== "placeholder")
      .map((row) => normalizedName(row.canonical_name))
  );
  const summary = {
    generated_at: new Date().toISOString(),
    audit_last_updated: "2026-08-17T16:06:43.005Z",
    reported_names: rows.length,
    placeholder_names: rows.filter((row) => row.status === "placeholder").length,
    duplicate_aliases: rows.filter((row) => row.status === "duplicate-alias").length,
    canonical_real_teams: canonicalRealTeams.size,
    candidate_rows: rows.filter((row) => row.candidate_url).length,
    unresolved_rows: rows.filter((row) => row.status === "unresolved").length,
    downloaded_previews: rows.filter((row) => row.preview_path?.startsWith("images/")).length,
  };

  fs.writeFileSync(
    path.join(outputDirectory, "manifest.json"),
    `${JSON.stringify({ summary, teams: rows }, null, 2)}\n`
  );
  const csv = [
    ["reported_name", "canonical_name", "status", "confidence", "candidate_url", "source_page"],
    ...rows.map((row) => [
      row.reported_name,
      row.canonical_name,
      row.status,
      row.confidence,
      row.candidate_url || "",
      row.source_page || "",
    ]),
  ]
    .map((values) => values.map((value) => `"${String(value).replace(/"/g, '""')}"`).join(","))
    .join("\n");
  fs.writeFileSync(path.join(outputDirectory, "missing-team-logos.csv"), `${csv}\n`);

  const cards = rows.map((row) => `
    <article class="card" data-status="${escaped(row.status)}" data-search="${escaped(`${row.reported_name} ${row.canonical_name}`.toLowerCase())}">
      <div class="image-wrap">
        ${row.preview_path ? `<img loading="lazy" src="${escaped(row.preview_path)}" alt="Candidate logo for ${escaped(row.reported_name)}">` : `<div class="no-image">No logo needed</div>`}
      </div>
      <div class="content">
        <h2>${escaped(row.reported_name)}</h2>
        ${row.canonical_name !== row.reported_name ? `<p class="canonical">Canonical: ${escaped(row.canonical_name)}</p>` : ""}
        <span class="status ${escaped(row.status)}">${escaped(row.status)}</span>
        <p class="source">${escaped(row.source || "No candidate")}</p>
        ${row.source_page ? `<a href="${escaped(row.source_page)}" target="_blank" rel="noreferrer">Open source ↗</a>` : ""}
        ${row.download_error ? `<p class="error">Preview download failed: ${escaped(row.download_error)}</p>` : ""}
      </div>
    </article>`).join("");

  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Top Scores — missing team logo review</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #080d16; color: #f4f7fb; }
    header { position: sticky; top: 0; z-index: 3; padding: 20px clamp(18px, 4vw, 48px); background: rgba(8,13,22,.94); border-bottom: 1px solid #263247; backdrop-filter: blur(16px); }
    h1 { margin: 0 0 6px; font-size: clamp(25px, 4vw, 42px); }
    .summary { margin: 0 0 16px; color: #9ca9bd; }
    .controls { display: flex; flex-wrap: wrap; gap: 10px; }
    input, button { border: 1px solid #34425a; background: #111a29; color: #f4f7fb; border-radius: 10px; padding: 10px 12px; font: inherit; }
    input { flex: 1 1 260px; }
    button.active { border-color: #4b98ff; background: #173964; }
    main { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 14px; padding: 20px clamp(18px, 4vw, 48px) 60px; }
    .card { min-width: 0; overflow: hidden; border: 1px solid #263247; border-radius: 16px; background: #101827; }
    .image-wrap { display: grid; place-items: center; height: 170px; padding: 20px; background: linear-gradient(145deg, #eef2f8, #cdd6e4); }
    img { display: block; max-width: 100%; max-height: 100%; object-fit: contain; }
    .no-image { color: #4c586a; font-weight: 700; }
    .content { padding: 16px; }
    h2 { margin: 0 0 6px; font-size: 18px; }
    p { margin: 6px 0; }
    .canonical, .source { color: #aeb9ca; font-size: 14px; }
    .status { display: inline-block; margin: 6px 0; padding: 4px 8px; border-radius: 999px; background: #163860; color: #77b6ff; font-size: 12px; font-weight: 700; }
    .status.duplicate-alias { background: #3a2e12; color: #f3c75b; }
    .status.placeholder { background: #30333a; color: #c4c9d2; }
    .status.unresolved { background: #501f28; color: #ff93a4; }
    a { color: #71b3ff; }
    .error { color: #ff93a4; font-size: 12px; }
    .hidden { display: none; }
  </style>
</head>
<body>
  <header>
    <h1>Missing team logo review</h1>
    <p class="summary">${summary.reported_names} reported names · ${summary.canonical_real_teams} canonical real teams · ${summary.candidate_rows} rows with candidates · ${summary.unresolved_rows} unresolved · generated ${escaped(summary.generated_at)}</p>
    <div class="controls">
      <input id="search" type="search" placeholder="Search reported or canonical team name">
      <button class="active" data-filter="all">All</button>
      <button data-filter="candidate">Candidates</button>
      <button data-filter="duplicate-alias">Duplicate aliases</button>
      <button data-filter="placeholder">Placeholders</button>
      <button data-filter="unresolved">Unresolved</button>
    </div>
  </header>
  <main>${cards}</main>
  <script>
    const cards = [...document.querySelectorAll('.card')];
    const search = document.querySelector('#search');
    const buttons = [...document.querySelectorAll('button[data-filter]')];
    let filter = 'all';
    function applyFilters() {
      const query = search.value.trim().toLowerCase();
      for (const card of cards) {
        const statusMatches = filter === 'all' || card.dataset.status === filter;
        const queryMatches = !query || card.dataset.search.includes(query);
        card.classList.toggle('hidden', !(statusMatches && queryMatches));
      }
    }
    search.addEventListener('input', applyFilters);
    for (const button of buttons) button.addEventListener('click', () => {
      filter = button.dataset.filter;
      for (const peer of buttons) peer.classList.toggle('active', peer === button);
      applyFilters();
    });
  </script>
</body>
</html>`;
  fs.writeFileSync(path.join(outputDirectory, "review.html"), html);
  console.log(JSON.stringify(summary, null, 2));
  const unresolved = rows.filter((row) => row.status === "unresolved");
  if (unresolved.length) {
    console.error(`Unresolved: ${unresolved.map((row) => row.reported_name).join(", ")}`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
