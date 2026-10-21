import { useEffect, useState } from "react";
import { fetchMatchCommentary } from "../api";
import type { MatchCommentary as CommentaryPayload } from "../types";

export function MatchCommentary({ matchId, isLive }: { matchId: string; isLive: boolean }) {
  const [payload, setPayload] = useState<CommentaryPayload | null>(null);
  const [error, setError] = useState(false);
  const [retry, setRetry] = useState(0);
  const [importantOnly, setImportantOnly] = useState(false);
  const [showAll, setShowAll] = useState(false);

  useEffect(() => {
    let disposed = false;
    let timer: number | undefined;
    let controller: AbortController | undefined;
    async function load() {
      if (disposed || document.hidden) return;
      controller?.abort();
      const request = new AbortController();
      controller = request;
      let delay: number | null = 15;
      try {
        const result = await fetchMatchCommentary(matchId, request.signal);
        if (disposed || request.signal.aborted) return;
        setPayload(result);
        setError(false);
        delay = result.refresh_after_seconds;
      } catch {
        if (disposed || request.signal.aborted) return;
        setError(true);
        delay = 30;
      }
      if (!disposed && delay !== null) {
        timer = window.setTimeout(() => void load(), Math.max(15, delay) * 1000);
      }
    }
    function visibilityChanged() {
      window.clearTimeout(timer);
      controller?.abort();
      if (!document.hidden) void load();
    }
    void load();
    document.addEventListener("visibilitychange", visibilityChanged);
    return () => {
      disposed = true;
      window.clearTimeout(timer);
      controller?.abort();
      document.removeEventListener("visibilitychange", visibilityChanged);
    };
  }, [matchId, isLive, retry]);

  const entries = [...(payload?.commentary ?? [])].reverse().filter(line => !importantOnly || line.important);
  const visible = showAll ? entries : entries.slice(0, 10);
  const waiting = ["notstarted", "not_started", "upcoming"].includes(payload?.status ?? "");
  return (
    <section className="match-commentary" aria-label="Match commentary">
      <div className="commentary-toolbar">
        <span className="commentary-caption">Newest first</span>
        <button type="button" className="commentary-filter" aria-pressed={importantOnly}
          onClick={() => { setImportantOnly(value => !value); setShowAll(false); }}>
          Key moments
        </button>
      </div>
      <div role="status" className="commentary-caption">
        {error ? (payload ? "Commentary couldn’t refresh. Showing the last available updates." : "Commentary is temporarily unavailable.")
          : payload?.stale ? "Updates may be delayed. Showing the latest available commentary." : !payload ? "Loading commentary…" : null}
      </div>
      {error && <button type="button" className="commentary-more" onClick={() => setRetry(value => value + 1)}>Retry</button>}
      {payload && entries.length === 0 && (
        <p className="commentary-empty">
          {importantOnly && payload.commentary.length ? "No key moments yet. Turn off the filter to see all commentary."
            : waiting ? "Commentary will appear here once the match starts."
            : "Commentary isn’t available for this match yet."}
        </p>
      )}
      <ol className="commentary-list">
        {visible.map(line => (
          <li key={line.id} className={`commentary-entry${line.important ? " is-important" : ""}`}>
            <span className="commentary-minute">
              {line.minute}{line.added_time ? `+${line.added_time}` : ""}′
            </span>
            <div className="commentary-copy">
              {line.important && <span className="commentary-key-label">Key moment</span>}
              <p>{line.text}</p>
            </div>
          </li>
        ))}
      </ol>
      {entries.length > 10 && (
        <button type="button" className="commentary-more" aria-expanded={showAll}
          onClick={() => setShowAll(value => !value)}>
          {showAll ? "Show recent updates" : `Show all ${entries.length} updates`}
        </button>
      )}
    </section>
  );
}
