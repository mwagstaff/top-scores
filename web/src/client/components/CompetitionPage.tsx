import { Suspense, lazy, type ComponentType } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { MatchesScreen } from "./MatchesScreen";
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
  const section = params.get("section") || "fixtures";
  return (
    <>
      <PageMeta
        title={name}
        description={`${name} fixtures, results, standings and UK TV coverage on Top Scores.`}
      />
      <div className="breadcrumbs">
        <Link to="/fixtures">← All football</Link>
      </div>
      <header className="football-heading competition-hero">
        <StadiumBackdrop selectionKey={name} />
        <div className="heading-copy">
          <span className="eyebrow">Competition centre</span>
          <h1>{name}</h1>
          <p>The fixtures, the results, the race.</p>
        </div>
      </header>
      <nav className="competition-tabs" aria-label="Competition sections">
        {["fixtures", "results", "table"].map((value) => (
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
