import { createContext, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type PropsWithChildren } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { competitionPath, localDate } from "./football";
import { loadCompetitions, type Competition } from "./catalog";
import type { MatchScope } from "./matchViewPreferences";

export type MatchKeyboardView = {
  date: string;
  scope: MatchScope;
  query: string;
  changeDate: (step: number) => boolean;
  setScope?: (scope: MatchScope) => void;
  toggleDetails?: () => void;
  openTV: () => void;
  openSearch: () => void;
};
const KeyboardContext = createContext<(view: MatchKeyboardView) => () => void>(() => () => {});

export function useMatchKeyboard(view: MatchKeyboardView) {
  const register = useContext(KeyboardContext);
  useLayoutEffect(() => register(view));
}

export function KeyHint({ children }: { children: string }) {
  return <kbd className="key-hint" aria-hidden="true">{children}</kbd>;
}

function editingTarget(target: EventTarget | null) {
  return target instanceof HTMLElement && Boolean(target.isContentEditable || target.closest('input, textarea, select, [contenteditable="true"], [role="slider"], [role="tablist"], [role="menu"], [role="listbox"], [role="combobox"], [role="spinbutton"]'));
}

export function KeyboardNavigation({ children }: PropsWithChildren) {
  const location = useLocation();
  const navigate = useNavigate();
  const view = useRef<MatchKeyboardView | null>(null);
  const home = useRef({ url: "/", query: "", match: "" });
  const previousScopes = useRef(new Map<string, MatchScope>());
  const selection = useRef({ href: "", index: 0, key: "" });
  const restoreMatch = useRef("");
  const [letters, setLetters] = useState(true);
  const [overlay, setOverlay] = useState<"help" | "competitions" | null>(null);
  const [competitions, setCompetitions] = useState<Competition[]>([]);
  const [catalogError, setCatalogError] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const locationRef = useRef(location);
  locationRef.current = location;
  const register = useMemo(() => (next: MatchKeyboardView) => {
    view.current = next;
    const current = locationRef.current;
    if (next.setScope) {
      for (const target of ["all", "top", "epl"] as const) {
        if (next.scope !== target) previousScopes.current.set(`${current.pathname}:${target}`, next.scope);
      }
    }
    if (current.pathname === "/") {
      const params = new URLSearchParams(current.search);
      params.set("date", next.date);
      params.set("scope", next.scope);
      home.current = { ...home.current, url: `/?${params}`, query: next.query };
    }
    return () => { if (view.current === next) view.current = null; };
  }, []);

  useEffect(() => {
    try { setLetters(localStorage.getItem("top-scores.keyboard-letters") !== "off"); } catch { /* Session defaults remain usable. */ }
  }, []);
  useEffect(() => {
    if (!overlay) return;
    returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialog.current?.showModal();
    return () => { dialog.current?.close(); };
  }, [overlay]);
  useEffect(() => {
    if (overlay !== "competitions") return;
    let active = true;
    setCatalogError(false);
    loadCompetitions().then(items => { if (active) setCompetitions(items); }).catch(() => { if (active) setCatalogError(true); });
    return () => { active = false; };
  }, [overlay]);
  useEffect(() => {
    if (overlay === "competitions" && competitions.length) dialog.current?.querySelector<HTMLAnchorElement>(".keyboard-competition-list a")?.focus();
  }, [overlay, competitions]);

  useEffect(() => {
    const links = () => [...document.querySelectorAll<HTMLAnchorElement>('.scores-primary .fixture-details-link')];
    const clearSelection = () => document.querySelectorAll('[data-keyboard-selected]').forEach(row => row.removeAttribute('data-keyboard-selected'));
    const select = (link: HTMLAnchorElement, index: number) => {
      clearSelection();
      link.closest('.fixture-row')?.setAttribute('data-keyboard-selected', 'true');
      link.focus({ preventScroll: true });
      link.closest('.fixture-row')?.scrollIntoView({ block: 'nearest' });
      selection.current = { href: link.getAttribute('href') || '', index, key: `${locationRef.current.pathname}:${view.current?.date}:${view.current?.scope}:${view.current?.query}` };
      if (locationRef.current.pathname === '/') home.current.match = selection.current.href;
    };
    const reconcile = () => {
      const rows = links();
      const pending = restoreMatch.current;
      if (pending && locationRef.current.pathname === '/' && rows.length) {
        const index = Math.max(0, rows.findIndex(row => row.getAttribute('href') === pending));
        restoreMatch.current = '';
        select(rows[index], index);
      } else if (selection.current.href && document.activeElement === document.body && rows.length && selection.current.key === `${locationRef.current.pathname}:${view.current?.date}:${view.current?.scope}:${view.current?.query}`) {
        const found = rows.findIndex(row => row.getAttribute('href') === selection.current.href);
        const index = found < 0 ? Math.min(selection.current.index, rows.length - 1) : found;
        select(rows[index], index);
      }
    };
    const observer = new MutationObserver(reconcile);
    const main = document.getElementById('main-content');
    if (main) observer.observe(main, { childList: true, subtree: true });
    reconcile();
    const pointer = () => { clearSelection(); selection.current.href = ''; };
    const goHome = () => {
      setOverlay(null);
      document.querySelectorAll<HTMLDialogElement>('dialog[open]').forEach(item => item.close());
      restoreMatch.current = home.current.match;
      navigate(home.current.url, { state: { restoredMatchQuery: home.current.query, keyboardReturn: true } });
      window.requestAnimationFrame(reconcile);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.altKey || event.ctrlKey || event.metaKey) return;
      if (event.key === 'Escape' && !event.repeat && !event.shiftKey) {
        event.preventDefault();
        // Other popovers may also listen for Escape; they can close normally.
        goHome();
        return;
      }
      if (editingTarget(event.target)) return;
      if (event.key === '?' && !event.repeat && letters && overlay !== 'competitions') {
        event.preventDefault();
        setOverlay(current => current === 'help' ? null : 'help');
        if (overlay === 'help') returnFocus.current?.focus();
        return;
      }
      if (event.shiftKey) return;
      const target = event.target instanceof HTMLElement ? event.target : null;
      const rail = target?.closest('.league-rail, .keyboard-competition-list');
      if (rail && event.key.startsWith('Arrow')) {
        event.preventDefault();
        const items = [...rail.querySelectorAll<HTMLAnchorElement>('a')];
        const index = items.indexOf(document.activeElement as HTMLAnchorElement);
        const step = event.key === 'ArrowUp' || event.key === 'ArrowLeft' ? -1 : 1;
        items[Math.max(0, Math.min(items.length - 1, index + step))]?.focus();
        return;
      }
      if (overlay || target?.closest('dialog, [role="dialog"]')) return;
      const activeView = view.current;
      if (activeView && (event.key === 'ArrowLeft' || event.key === 'ArrowRight')) {
        if (activeView.changeDate(event.key === 'ArrowLeft' ? -1 : 1)) {
          event.preventDefault();
          clearSelection(); selection.current.href = '';
        }
        return;
      }
      if (activeView && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) {
        const rows = links();
        if (!rows.length) return;
        event.preventDefault();
        const focused = rows.findIndex(row => row === document.activeElement || row.closest('.fixture-row')?.contains(document.activeElement));
        const index = focused < 0 ? (event.key === 'ArrowDown' ? 0 : rows.length - 1) : Math.max(0, Math.min(rows.length - 1, focused + (event.key === 'ArrowDown' ? 1 : -1)));
        select(rows[index], index);
        return;
      }
      if (!letters || event.repeat) return;
      const key = event.key.toLowerCase();
      if (!['/', 'a', 'o', 'p', 'd', 'v', 't', 'r', 'f', 'c', 's'].includes(key)) return;
      if ((['a', 'o', 'p'].includes(key) && !activeView?.setScope) || (key === 'd' && !activeView?.toggleDetails)) return;
      event.preventDefault();
      if (['a', 'o', 'p'].includes(key)) {
        const scope: MatchScope = key === 'a' ? 'all' : key === 'o' ? 'top' : 'epl';
        const previous = previousScopes.current.get(`${locationRef.current.pathname}:${scope}`) || (scope === 'all' ? 'top' : 'all');
        activeView!.setScope!(activeView!.scope === scope ? previous : scope);
      } else if (key === '/') {
        if (activeView) activeView.openSearch();
        else navigate(home.current.url, { state: { restoredMatchQuery: home.current.query, keyboardReturn: true, keyboardSearch: true } });
      } else if (key === 's') navigate('/');
      else if (key === 'd') activeView!.toggleDetails!();
      else if (key === 'v') {
        if (activeView) activeView.openTV();
        else {
          const date = new URLSearchParams(locationRef.current.search).get('date') || localDate();
          navigate(`/tv?date=${date < localDate() ? localDate() : date}&scope=all`);
        }
      } else if (key === 'c') {
        clearSelection(); selection.current.href = '';
        const rail = document.querySelector<HTMLElement>('.league-rail');
        if (rail && rail.getClientRects().length && rail.querySelector('a')) (rail.querySelector<HTMLAnchorElement>('a.selected') || rail.querySelector<HTMLAnchorElement>('a'))?.focus();
        else setOverlay('competitions');
      } else navigate({ t: '/tables', r: '/results', f: '/fpl' }[key as 't' | 'r' | 'f']);
    };
    window.addEventListener('keydown', onKey);
    document.addEventListener('pointerdown', pointer);
    return () => { observer.disconnect(); window.removeEventListener('keydown', onKey); document.removeEventListener('pointerdown', pointer); };
  }, [navigate, letters, overlay]);

  return <KeyboardContext.Provider value={register}>
    <div className="keyboard-navigation" data-letter-shortcuts={letters ? 'on' : 'off'}>
      {children}
      <button className="keyboard-help-launcher" onClick={() => setOverlay('help')} aria-keyshortcuts="?" aria-haspopup="dialog"><KeyHint>?</KeyHint> Keyboard help</button>
      <dialog ref={dialog} className="keyboard-dialog" aria-labelledby="keyboard-dialog-title" onCancel={event => event.preventDefault()}>
        <div className="keyboard-dialog-heading"><h2 id="keyboard-dialog-title">{overlay === 'competitions' ? 'Competitions' : 'Keyboard help'}</h2><button onClick={() => { setOverlay(null); returnFocus.current?.focus(); }} aria-label="Close">×</button></div>
        {overlay === 'competitions' ? <>
          <p className="keyboard-description">Arrow keys to move · Enter to open · Esc to return home</p>
          {catalogError && <p role="alert">Competitions unavailable. Close and try again.</p>}
          {!catalogError && !competitions.length && <p role="status">Loading competitions…</p>}
          <nav className="keyboard-competition-list" aria-label="Choose competition">{competitions.map(item => <Link key={item.id} to={`${competitionPath(item.name)}?date=${view.current?.date || new URLSearchParams(location.search).get('date') || localDate()}`} onClick={() => setOverlay(null)}>{item.name}</Link>)}</nav>
        </> : <>
          <dl className="keyboard-help-list">{[['← →', 'Previous / next date'], ['↑ ↓', 'Previous / next match'], ['Enter', 'Open selected match'], ['/', 'Search matches'], ['S', 'Scores & fixtures'], ['A', 'Toggle All competitions'], ['O', 'Toggle Top teams'], ['P', 'Toggle Premier League teams'], ['D', 'Toggle match details'], ['V', 'TV guide for selected date'], ['T', 'Tables'], ['R', 'Results'], ['F', 'FPL'], ['C', 'Focus competitions; arrows then Enter'], ['Esc', 'Return to your previous homepage view'], ['?', 'Keyboard help']].map(([key, label]) => <div key={key}><dt><kbd>{key}</kbd></dt><dd>{label}</dd></div>)}</dl>
          <label className="keyboard-preference"><input type="checkbox" checked={letters} onChange={event => { setLetters(event.target.checked); try { localStorage.setItem('top-scores.keyboard-letters', event.target.checked ? 'on' : 'off'); } catch { /* Keep the session choice. */ } }} />Single-letter shortcuts</label>
          <p className="keyboard-description">Shortcuts pause while typing. Tab navigation always works. Details and filters apply where their controls are available.</p>
        </>}
      </dialog>
    </div>
  </KeyboardContext.Provider>;
}
