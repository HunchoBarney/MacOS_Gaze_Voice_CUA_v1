import { toast } from "sonner";
import { sourceUrl } from "../data";
import type { Finding } from "../types";
import { ArrowUpRightIcon, LinkIcon } from "./Icons";
import { SeverityChip } from "./Severity";

export function FindingCard({
  finding,
  active,
  onShowProposed,
}: {
  finding: Finding;
  active: boolean;
  onShowProposed?: () => void;
}) {
  async function copy() {
    const url = location.origin + "/c/" + finding.component + "#" + finding.id;
    try {
      await navigator.clipboard.writeText(url);
      toast("Link to " + finding.id + " copied");
    } catch {
      toast("Couldn’t copy. The link is " + url);
    }
  }
  return (
    <article id={finding.id} className="finding" data-active={active || undefined} aria-labelledby={finding.id + "-title"}>
      <header className="finding-head">
        <SeverityChip severity={finding.severity} />
        <span className="finding-id num">{finding.id}</span>
        <button type="button" className="icon-button finding-copy" onClick={copy} aria-label={"Copy link to " + finding.id} title="Copy link">
          <LinkIcon size={14} />
        </button>
      </header>
      <h3 id={finding.id + "-title"} className="finding-title">
        {finding.title}
      </h3>
      <a className="finding-where" href={sourceUrl(finding.where)} target="_blank" rel="noreferrer">
        <code>{finding.where}</code>
        <ArrowUpRightIcon size={12} />
      </a>
      <dl className="finding-body">
        <dt>Problem</dt>
        <dd>{finding.problem}</dd>
        <dt>Fix</dt>
        <dd>{finding.fix}</dd>
        {finding.library && (
          <>
            <dt>Library</dt>
            <dd>{finding.library}</dd>
          </>
        )}
      </dl>
      <footer className="finding-foot">
        <ul className="skills" aria-label="Skills">
          {finding.skills.map((skill) => (
            <li key={skill}>{skill}</li>
          ))}
        </ul>
        {onShowProposed && (
          <button type="button" className="text-button" onClick={onShowProposed}>
            Show proposed
          </button>
        )}
      </footer>
    </article>
  );
}
