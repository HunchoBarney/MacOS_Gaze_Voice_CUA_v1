import { Link } from "../router";

export function NotFound({ what = "page" }: { what?: string }) {
  return (
    <section className="page empty-page">
      <h1 className="title-1">No such {what}</h1>
      <p className="lede">The link may point at a render that was renamed or removed.</p>
      <p>
        <Link className="text-button" href="/">
          Back to all components
        </Link>
      </p>
    </section>
  );
}
