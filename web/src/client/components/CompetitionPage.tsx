import { loadCompetitions } from "../catalog";
import { Suspense, lazy, useEffect, useState, type ComponentType } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { MatchesScreen } from "./MatchesScreen";
import { competitionLogo } from "../competitionLogos";
import { PageMeta } from "./PageMeta";
import { StadiumBackdrop } from "./StadiumBackdrop";
const Tables = lazy(() =>
  import("./TablesScreen").then((module) => ({ default: module.TablesScreen })),
);

export default function CompetitionPage({
  TablesComponent = Tables,
}: {
  TablesComponent?: ComponentType<{ competition?: string }>;
}) {
  const { name = "" } = useParams();
  const [params, setParams] = useSearchParams();
  const [supportsTable, setSupportsTable] = useState(false);
  useEffect(() => { let active = true; setSupportsTable(false); loadCompetitions().then(items => { if (active) setSupportsTable(items.find(item => item.name === name || item.aliases.includes(name))?.supports_table === true); }).catch(() => {}); return () => { active = false; }; }, [name]);
  const requestedSection = params.get("section") || "fixtures";
  const section = requestedSection === 'table' && !supportsTable ? 'fixtures' : requestedSection;
  return (
    <>
      <PageMeta
        title={name}
        description={`${name} fixtures, results, standings and UK TV coverage on Top Scores.`}
      />
      <div className="breadcrumbs">
        <Link to="/">← All football</Link>
      </div>
      <header className="football-heading competition-hero">
        {section !== "table" && <StadiumBackdrop selectionKey={name} />}
        <div className="heading-copy">
          <h1 className="competition-title">{competitionLogo("", name) && <img src={competitionLogo("", name)} width="64" height="64" alt="" />}<span>{name}</span></h1>
        </div>
      </header>
      <nav className="competition-tabs" aria-label="Competition sections">
        {(supportsTable ? ["fixtures", "results", "table"] : ["fixtures", "results"]).map((value) => (
          <button
            key={value}
            aria-current={section === value ? "page" : undefined}
            onClick={() => setParams({ section: value })}
          >
            {value === "table"
              ? "Standings"
              : value[0].toUpperCase() + value.slice(1)}
          </button>
        ))}
      </nav>
      {section === "table" ? (
        <Suspense
          fallback={<div className="football-empty">Loading standings…</div>}
        >
          <TablesComponent key={name} competition={name} />
        </Suspense>
      ) : (
        <MatchesScreen
          key={`${name}:${section}`}
          mode={section === "results" ? "results" : "fixtures"}
          competition={name}
        />
      )}
    </>
  );
}
