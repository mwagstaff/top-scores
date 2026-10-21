import { useEffect, useState } from "react";
import {
  loadStadiumCatalog,
  selectStadium,
  type StadiumAsset,
} from "../stadium";

export function StadiumBackdrop({
  teamName,
  teamId,
  selectionKey,
  ready = true,
}: {
  teamName?: string;
  teamId?: string | null;
  selectionKey?: string;
  ready?: boolean;
}) {
  const [asset, setAsset] = useState<StadiumAsset>();
  const [loaded, setLoaded] = useState("");
  useEffect(() => {
    let cancelled = false;
    setAsset(undefined);
    if (!ready) return;
    const timer = window.setTimeout(() => {
      void loadStadiumCatalog()
        .then((catalog) => {
          if (!cancelled)
            setAsset(selectStadium(catalog, teamName, teamId, selectionKey));
        })
        .catch(() => {});
    }, 700);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [teamName, teamId, selectionKey, ready]);
  if (!asset) return null;
  return (
    <>
      <picture>
        <source
          media="(max-width: 600px)"
          srcSet={`/artwork/${asset.sha256}/480.webp 1x, /artwork/${asset.sha256}/960.webp 2x`}
        />
        <img
          className={`stadium-backdrop${loaded === asset.sha256 ? " is-loaded" : ""}`}
          key={asset.sha256}
          src={`/artwork/${asset.sha256}/960.webp`}
          srcSet={`/artwork/${asset.sha256}/480.webp 480w, /artwork/${asset.sha256}/960.webp 960w, /artwork/${asset.sha256}/1440.webp 1440w`}
          sizes="(max-width: 600px) 100vw, (max-width: 1200px) 80vw, 1100px"
          alt=""
          aria-hidden="true"
          decoding="async"
          fetchPriority="low"
          onLoad={() => setLoaded(asset.sha256)}
          style={{
            objectPosition: asset.focal_point
              ? `${asset.focal_point.x * 100}% ${asset.focal_point.y * 100}%`
              : "center 50%",
          }}
        />
      </picture>
      {loaded === asset.sha256 && asset.credit?.attribution && (
        <details className="artwork-credit">
          <summary aria-label="Stadium image credit">Photo credit</summary>
          <p>
            {asset.stadium && <strong>{asset.stadium}. </strong>}
            {asset.credit.attribution}
          </p>
        </details>
      )}
    </>
  );
}
