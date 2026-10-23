import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { homeStadiums, loadStadiumCatalog, randomStadium, requiresPhotoCredit, selectStadium, type StadiumAsset } from "../stadium";

export function StadiumBackdrop({ teamName, teamId, selectionKey, ready = true, homes }: {
  teamName?: string;
  teamId?: string | null;
  selectionKey?: string;
  ready?: boolean;
  homes?: { name: string; id?: string | null }[];
}) {
  const [layers, setLayers] = useState<StadiumAsset[]>([]);
  const [loaded, setLoaded] = useState("");
  const current = useRef<StadiumAsset | undefined>(undefined);
  // Scores poll frequently; restart rotation only when the home-team pool changes.
  const homesKey = homes ? JSON.stringify(homes.map(home => [home.name, home.id]).sort()) : "";
  useEffect(() => {
    let cancelled = false;
    if (!ready) return;
    const choose = async () => {
      if (document.visibilityState !== "visible") return;
      try {
        const catalog = await loadStadiumCatalog();
        const pool = homesKey ? homeStadiums(catalog, (JSON.parse(homesKey) as [string, string | null][]).map(([name, id]) => ({ name, id }))) : [];
        const next = homesKey ? randomStadium(pool, current.current?.sha256) : selectStadium(catalog, teamName, teamId, selectionKey);
        if (cancelled || !next || next.sha256 === current.current?.sha256) return;
        // Keep the last successfully loaded image behind the incoming layer.
        setLayers(current.current ? [current.current, next] : [next]);
      } catch { /* Keep the existing artwork on connection failures. */ }
    };
    const initial = window.setTimeout(choose, 100);
    const interval = homesKey ? window.setInterval(choose, 60_000) : undefined;
    return () => {
      cancelled = true;
      window.clearTimeout(initial);
      window.clearInterval(interval);
    };
  }, [teamName, teamId, selectionKey, ready, homesKey]);
  if (!layers.length) return null;
  const active = layers.find(asset => asset.sha256 === loaded);
  return <>
    {createPortal(
    <div className="page-stadium">
      {layers.map(asset => (
        <picture key={asset.sha256}>
        <source media="(max-width: 600px)" srcSet={`/artwork/${asset.sha256}/480.webp 1x, /artwork/${asset.sha256}/960.webp 2x`} />
        <img
          className={`page-stadium-image${layers.length === 1 ? " is-initial" : ""}${loaded === asset.sha256 ? " is-loaded" : ""}`}
          src={`/artwork/${asset.sha256}/960.webp`}
          srcSet={`/artwork/${asset.sha256}/480.webp 480w, /artwork/${asset.sha256}/960.webp 960w, /artwork/${asset.sha256}/1440.webp 1440w`}
          sizes="100vw" alt="" aria-hidden="true" decoding="async" fetchPriority="low"
          onLoad={() => { current.current = asset; setLoaded(asset.sha256); }}
          style={{ objectPosition: asset.focal_point ? `${asset.focal_point.x * 100}% ${asset.focal_point.y * 100}%` : "center" }}
        />
        </picture>
      ))}

    </div>, document.body)}
      {active && requiresPhotoCredit(active) && (
        <details className="artwork-credit">
          <summary aria-label="Stadium image credit">Photo credit</summary>
          <p>{active.stadium && <strong>{active.stadium}. </strong>}{active.credit?.attribution}</p>
        </details>
      )}
  </>;
}
