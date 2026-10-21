import { useLayoutEffect, useRef } from "react";
import { useLocation, useNavigationType } from "react-router-dom";
const positions = new Map<string, number>();
export function ScrollPosition() {
  const location = useLocation();
  const navigation = useNavigationType();
  const previousPath = useRef(location.pathname);
  useLayoutEffect(() => {
    if (navigation === "POP")
      window.scrollTo(0, positions.get(location.key) || 0);
    else if (previousPath.current !== location.pathname) {
      window.scrollTo(0, 0);
      document.getElementById("main-content")?.focus({ preventScroll: true });
    }
    previousPath.current = location.pathname;
    return () => {
      positions.set(location.key, window.scrollY);
      if (positions.size > 50) positions.delete(positions.keys().next().value!);
    };
  }, [location.key, location.pathname, navigation]);
  return null;
}
