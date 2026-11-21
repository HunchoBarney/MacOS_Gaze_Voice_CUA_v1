import { useSyncExternalStore, type AnchorHTMLAttributes, type MouseEvent } from "react";

const listeners = new Set<() => void>();
const notify = () => listeners.forEach((listener) => listener());
window.addEventListener("popstate", notify);

export function navigate(to: string, { replace = false } = {}) {
  const url = new URL(to, location.href);
  if (url.href === location.href) return;
  history[replace ? "replaceState" : "pushState"](null, "", url.pathname + url.search + url.hash);
  notify();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useLocation() {
  const href = useSyncExternalStore(subscribe, () => location.pathname + location.search + location.hash);
  const url = new URL(href, location.origin);
  return { pathname: url.pathname, search: url.searchParams, hash: decodeURIComponent(url.hash.slice(1)), href };
}

export function Link({ href, onClick, ...rest }: AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) {
  function handle(event: MouseEvent<HTMLAnchorElement>) {
    onClick?.(event);
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (rest.target && rest.target !== "_self") return;
    event.preventDefault();
    navigate(href);
  }
  return <a href={href} onClick={handle} {...rest} />;
}
