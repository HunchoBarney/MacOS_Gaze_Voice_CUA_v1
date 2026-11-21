import NumberFlow from "@number-flow/react";
import { useMemo } from "react";
import { SeverityChip, severityName } from "../components/Severity";
import { bySeverity, severityCounts } from "../data";
import { Link, navigate, useLocation } from "../router";
import type { Gallery, Severity } from "../types";
import { AREAS, SEVERITIES } from "../types";

export function Audit({ gallery }: { gallery: Gallery }) {
  const { pathname, search } = useLocation();
  const severities = (search.get("sev")?.split(",").filter((s): s is Severity => SEVERITIES.includes(s as Severity)) ?? []) as Severity[];
  const area = search.get("area") ?? "";
  const componentId = search.get("c") ?? "";

  const componentsById = useMemo(() => new Map(gallery.components.map((c) => [c.id, c])), [gallery]);
  const areas = AREAS.filter((a) => gallery.components.some((c) => c.area === a));
  const scoped = gallery.findings.filter((f) => {
    const component = componentsById.get(f.component);
    if (area && component?.area !== area) return false;
    if (componentId && f.component !== componentId) return false;
    return true;
  });
  const counts = severityCounts(scoped);
  const shown = scoped.filter((f) => severities.length === 0 || severities.includes(f.severity)).sort(bySeverity);
  const total = severityCounts(gallery.findings);

  function update(params: Record<string, string | null>) {
    const query = new URLSearchParams(search);
    for (const [key, value] of Object.entries(params)) {
      if (!value) query.delete(key);
      else query.set(key, value);
    }
    const qs = query.toString();
    navigate(pathname + (qs ? "?" + qs : ""), { replace: true });
  }

  function toggleSeverity(severity: Severity) {
    const next = severities.includes(severity) ? severities.filter((s) => s !== severity) : [...severities, severity];
    update({ sev: SEVERITIES.filter((s) => next.includes(s)).join(",") || null });
  }

  const filtered = severities.length > 0 || area || componentId;
  const max = Math.max(1, ...SEVERITIES.map((s) => total[s]));

  return (
    <div className="page audit">
      <header className="page-head">
        <h1 className="title-1">Audit</h1>
        <p className="lede">
          Every finding from the UI audit, graded against the design skills and the library-first rule. Each one links to the component it’s about.
        </p>
        {gallery.skills.length > 0 && (
          <ul className="skills skills-lg" aria-label="Skills applied">
            {gallery.skills.map((skill) => (
              <li key={skill}>{skill}</li>
            ))}
          </ul>
        )}
      </header>

      <div className="distribution" aria-hidden="true">
        {SEVERITIES.map((s) => (
          <div key={s} className="dist-row">
            <SeverityChip severity={s} />
            <span className="dist-track">
              <span className="dist-bar" data-sev={s} style={{ transform: "scaleX(" + total[s] / max + ")" }} />
            </span>
            <span className="num dist-n">{total[s]}</span>
          </div>
        ))}
      </div>

      <div className="filters" role="group" aria-label="Filter findings">
        <div className="filter-sevs" role="group" aria-label="Severity">
          {SEVERITIES.map((s) => (
            <button key={s} type="button" className="filter-chip" aria-pressed={severities.includes(s)} onClick={() => toggleSeverity(s)}>
              <SeverityChip severity={s} />
              <span>{severityName(s)}</span>
              <span className="num filter-count">
                <NumberFlow value={counts[s]} />
              </span>
            </button>
          ))}
        </div>
        <label className="select">
          <span className="select-label">Area</span>
          <select value={area} onChange={(e) => update({ area: e.target.value || null, c: null })}>
            <option value="">All areas</option>
            {areas.map((a) => (
              <option key={a} value={a}>
                {a}
              </option>
            ))}
          </select>
        </label>
        <label className="select">
          <span className="select-label">Component</span>
          <select value={componentId} onChange={(e) => update({ c: e.target.value || null })}>
            <option value="">All components</option>
            {gallery.components
              .filter((c) => !area || c.area === area)
              .map((c) => (
                <option key={c.id} value={c.id}>
                  {c.title}
                </option>
              ))}
          </select>
        </label>
        {filtered && (
          <button type="button" className="text-button" onClick={() => navigate(pathname, { replace: true })}>
            Clear
          </button>
        )}
      </div>

      <p className="result-count" aria-live="polite">
        <span className="num">
          <NumberFlow value={shown.length} />
        </span>{" "}
        of <span className="num">{gallery.findings.length}</span> findings
      </p>

      {shown.length === 0 ? (
        <p className="muted">{gallery.findings.length === 0 ? "No findings yet." : "Nothing matches these filters."}</p>
      ) : (
        <ul className="audit-list">
          {shown.map((finding) => {
            const component = componentsById.get(finding.component);
            return (
              <li key={finding.id}>
                <Link className="audit-row" href={"/c/" + finding.component + "#" + finding.id}>
                  <span className="audit-sev">
                    <SeverityChip severity={finding.severity} />
                    <span className="finding-id num">{finding.id}</span>
                  </span>
                  <span className="audit-main">
                    <span className="audit-title">{finding.title}</span>
                    <span className="audit-meta">
                      {component ? component.area + " · " + component.title : finding.component}
                      {finding.library && <> · {finding.library}</>}
                    </span>
                  </span>
                  <code className="audit-where">{finding.where}</code>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
