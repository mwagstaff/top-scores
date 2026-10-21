import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { PreferencesProvider } from "./preferences";
import { warmTeamBadges } from "./api";
import "./football.css";
import { initialSeed } from "./bootstrap";

void warmTeamBadges();

const application = (
  <React.StrictMode>
    <BrowserRouter>
      <PreferencesProvider>
        <App />
      </PreferencesProvider>
    </BrowserRouter>
  </React.StrictMode>
);
const root = document.getElementById("root")!;
if (initialSeed?.rendered) ReactDOM.hydrateRoot(root, application);
else ReactDOM.createRoot(root).render(application);
