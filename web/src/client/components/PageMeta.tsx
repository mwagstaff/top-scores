import { useEffect } from "react";
import { useLocation } from "react-router-dom";

export function PageMeta({
  title,
  description,
}: {
  title: string;
  description: string;
}) {
  const location = useLocation();
  useEffect(() => {
    document.title = `${title} · Top Scores`;
    for (const [selector, key, value] of [
      ['meta[name="description"]', "name", "description"],
      ['meta[property="og:description"]', "property", "og:description"],
      ['meta[property="og:title"]', "property", "og:title"],
      ['meta[property="og:url"]', "property", "og:url"],
    ]) {
      let node = document.querySelector<HTMLMetaElement>(selector);
      if (!node) {
        node = document.createElement("meta");
        node.setAttribute(key, value);
        document.head.append(node);
      }
      node.content =
        value === "og:title"
          ? document.title
          : value === "og:url"
            ? `${window.location.origin}${location.pathname}`
            : description;
    }
    let canonical = document.querySelector<HTMLLinkElement>(
      'link[rel="canonical"]',
    );
    if (!canonical) {
      canonical = document.createElement("link");
      canonical.rel = "canonical";
      document.head.append(canonical);
    }
    const date = new URLSearchParams(location.search).get("date");
    const suffix =
      date &&
      /^\d{4}-\d{2}-\d{2}$/.test(date) &&
      !location.pathname.startsWith("/matches/")
        ? `?date=${date}`
        : "";
    canonical.href = `${window.location.origin}${location.pathname}${suffix}`;
  }, [title, description, location.pathname, location.search]);
  return null;
}
