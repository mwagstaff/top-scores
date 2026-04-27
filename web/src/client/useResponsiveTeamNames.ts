import { useEffect, useState } from "react";

const SHORT_TEAM_NAMES_QUERY = "(max-width: 640px), (max-height: 480px), (pointer: coarse) and (max-width: 900px)";

export function useShouldUseShortTeamNames(): boolean {
  const [shouldUseShortNames, setShouldUseShortNames] = useState(() => shouldUseShortTeamNames());

  useEffect(() => {
    const media = window.matchMedia(SHORT_TEAM_NAMES_QUERY);
    const update = () => setShouldUseShortNames(shouldUseShortTeamNames(media));

    update();
    media.addEventListener("change", update);
    window.addEventListener("resize", update, { passive: true });
    return () => {
      media.removeEventListener("change", update);
      window.removeEventListener("resize", update);
    };
  }, []);

  return shouldUseShortNames;
}

function shouldUseShortTeamNames(media?: MediaQueryList): boolean {
  if (typeof window === "undefined" || typeof navigator === "undefined") {
    return false;
  }

  return Boolean(media?.matches ?? window.matchMedia(SHORT_TEAM_NAMES_QUERY).matches) || isMobileDevice();
}

function isMobileDevice(): boolean {
  const nav = navigator as Navigator & { userAgentData?: { mobile?: boolean } };
  if (nav.userAgentData?.mobile) {
    return true;
  }

  return /Android|iPhone|iPad|iPod|IEMobile|Mobile|Opera Mini/i.test(navigator.userAgent);
}
