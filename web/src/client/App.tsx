import { Route, Routes } from "react-router-dom";
import { lazy, Suspense, type ComponentType } from "react";
import { AppShell } from "./components/AppShell";
import { MatchesScreen } from "./components/MatchesScreen";
const PreferencesScreen = lazy(() =>
  import("./components/PreferencesScreen").then((module) => ({
    default: module.PreferencesScreen,
  })),
);
const TablesScreen = lazy(() =>
  import("./components/TablesScreen").then((module) => ({
    default: module.TablesScreen,
  })),
);
const MatchPage = lazy(() => import("./components/MatchPage"));
const CompetitionPage = lazy(() => import("./components/CompetitionPage"));

interface Pages {
  MatchPage: ComponentType;
  CompetitionPage: ComponentType;
  TablesScreen: ComponentType;
  PreferencesScreen: ComponentType;
}
const defaultPages = {
  MatchPage,
  CompetitionPage,
  TablesScreen,
  PreferencesScreen,
};
export default function App({ pages = defaultPages }: { pages?: Pages }) {
  const { MatchPage, CompetitionPage, TablesScreen, PreferencesScreen } = pages;
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
          <Route path="/fixtures" element={<MatchesScreen mode="fixtures" />} />
          <Route path="/results" element={<MatchesScreen mode="results" />} />
          <Route path="/tv" element={<MatchesScreen tv />} />
          <Route path="/matches/:id" element={<MatchPage />} />
          <Route path="/competitions/:name" element={<CompetitionPage />} />
          <Route path="/tables" element={<TablesScreen />} />
          <Route path="/preferences" element={<PreferencesScreen />} />
          <Route
            path="*"
            element={
              <div className="football-empty">
                <h1>Page not found</h1>
                <a href="/fixtures">Back to football</a>
              </div>
            }
          />
        </Routes>
      </Suspense>
    </AppShell>
  );
}
