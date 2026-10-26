import { Navigate, useLocation, Route, Routes } from "react-router-dom";
import { lazy, Suspense, type ComponentType } from "react";
import { AppShell } from "./components/AppShell";
import { MatchesScreen } from "./components/MatchesScreen";
const TablesScreen = lazy(() =>
  import("./components/TablesScreen").then((module) => ({
    default: module.TablesScreen,
  })),
);
const MatchPage = lazy(() => import("./components/MatchPage"));
const CompetitionPage = lazy(() => import("./components/CompetitionPage"));

const TeamPage = lazy(() => import("./components/TeamPage"));

interface Pages {
  TeamPage: ComponentType;
  MatchPage: ComponentType;
  CompetitionPage: ComponentType;
  TablesScreen: ComponentType;
}
const defaultPages = {
  TeamPage,
  MatchPage,
  CompetitionPage,
  TablesScreen,
};
function FixturesRedirect() {
  const location = useLocation();
  return <Navigate replace to={`/${location.search}${location.hash}`} />;
}

export default function App({ pages = defaultPages }: { pages?: Pages }) {
  const { MatchPage, CompetitionPage, TablesScreen, TeamPage } = pages;
  return (
    <AppShell>
      <Suspense
        fallback={
          <div className="football-empty" role="status">
            Loading football…
          </div>
        }
      >
        <Routes>
          <Route path="/" element={<MatchesScreen mode="fixtures" />} />
          <Route path="/fixtures" element={<FixturesRedirect />} />
          <Route path="/results" element={<MatchesScreen mode="results" />} />
          <Route path="/tv" element={<MatchesScreen tv />} />
          <Route path="/teams/:name" element={<TeamPage />} />
          <Route path="/matches/:id" element={<MatchPage />} />
          <Route path="/competitions/:name" element={<CompetitionPage />} />
          <Route path="/tables" element={<TablesScreen />} />
          <Route
            path="*"
            element={
              <div className="football-empty">
                <h1>Page not found</h1>
                <a href="/">Back to football</a>
              </div>
            }
          />
        </Routes>
      </Suspense>
    </AppShell>
  );
}
