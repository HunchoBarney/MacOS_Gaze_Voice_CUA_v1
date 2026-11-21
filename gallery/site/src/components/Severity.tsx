import type { Severity } from "../types";

const NAMES: Record<Severity, string> = { P0: "Critical", P1: "High", P2: "Medium", P3: "Low" };

export function SeverityChip({ severity, withName = false }: { severity: Severity; withName?: boolean }) {
  return (
    <span className="sev" data-sev={severity} title={NAMES[severity] + " severity"}>
      {severity}
      {withName && <span className="sev-name">{NAMES[severity]}</span>}
    </span>
  );
}

export function severityName(severity: Severity) {
  return NAMES[severity];
}
