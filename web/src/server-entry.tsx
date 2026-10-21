import { renderToString } from "react-dom/server";
import { StaticRouter } from "react-router-dom";
import App from "./client/App";
import { PreferencesProvider } from "./client/preferences";
import { SeedContext, type Seed } from "./client/bootstrap";
import MatchPage from "./client/components/MatchPage";
import CompetitionPage from "./client/components/CompetitionPage";
import { TablesScreen } from "./client/components/TablesScreen";
import { PreferencesScreen } from "./client/components/PreferencesScreen";

const ServerCompetitionPage = () => (
  <CompetitionPage TablesComponent={TablesScreen} />
);
const pages = {
  MatchPage,
  CompetitionPage: ServerCompetitionPage,
  TablesScreen,
  PreferencesScreen,
};

// Use the same components and request-scoped data on both sides of hydration.
export function render(url: string, seed: Seed) {
  return renderToString(
    <StaticRouter location={url}>
      <SeedContext.Provider value={seed}>
        <PreferencesProvider>
          <App pages={pages} />
        </PreferencesProvider>
      </SeedContext.Provider>
    </StaticRouter>,
  );
}
