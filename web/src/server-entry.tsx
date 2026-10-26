import { renderToString } from "react-dom/server";
import { StaticRouter } from "react-router-dom";
import App from "./client/App";
import { SeedContext, type Seed } from "./client/bootstrap";
import TeamPage from "./client/components/TeamPage";
import MatchPage from "./client/components/MatchPage";
import CompetitionPage from "./client/components/CompetitionPage";
import { TablesScreen } from "./client/components/TablesScreen";

const ServerCompetitionPage = () => (
  <CompetitionPage TablesComponent={TablesScreen} />
);
const pages = {
  TeamPage,
  MatchPage,
  CompetitionPage: ServerCompetitionPage,
  TablesScreen,
};

// Use the same components and request-scoped data on both sides of hydration.
export function render(url: string, seed: Seed) {
  return renderToString(
    <StaticRouter location={url}>
      <SeedContext.Provider value={seed}>
        <App pages={pages} />
      </SeedContext.Provider>
    </StaticRouter>,
  );
}
