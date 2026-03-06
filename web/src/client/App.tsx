import { Navigate, Route, Routes } from "react-router-dom";
import { AppShell } from "./components/AppShell";
import { MatchesScreen } from "./components/MatchesScreen";
import { PreferencesScreen } from "./components/PreferencesScreen";

export default function App() {
  return (
    <AppShell>
      <Routes>
        <Route path="/" element={<Navigate to="/fixtures" replace />} />
        <Route path="/fixtures" element={<MatchesScreen mode="fixtures" />} />
        <Route path="/results" element={<MatchesScreen mode="results" />} />
        <Route path="/preferences" element={<PreferencesScreen />} />
      </Routes>
    </AppShell>
  );
}
