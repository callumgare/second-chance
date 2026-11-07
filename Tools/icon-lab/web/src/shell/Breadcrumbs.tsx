// The four stages as a big breadcrumb: each step says where you are and what it holds, and goes back to it.
import { go, type Route } from "../lib/router";
import { useApp } from "../state/app";
import { useDesign } from "../state/design";

export function Breadcrumbs({ route }: { route: Route }) {
  const program = useApp((s) => s.program);
  const designPins = useDesign((s) => (s.slug === route.slug ? s.pins.length : null));
  // Before the design stage has loaded this program, its count from the programs list.
  const listedPins = useApp((s) => s.programs?.find((p) => p.slug === route.slug)?.pins ?? null);
  const pins = designPins ?? listedPins;
  const saved = useDesign((s) => (s.slug === route.slug ? s.savedIds.length : 0));
  const cur = route.stage === "find" ? 1 : route.stage === "gather" ? 2 : route.stage === "design" ? 3 : 4;
  const picked = program?.media.filter((m) => m.picked).length ?? 0;
  const has = !!route.slug;
  const steps: [number, string, string, () => void, boolean, string?][] = [
    [1, "Find the program", program && has ? `${program.title}${program.year ? " · " + program.year : ""}` : "Search every catalogue", () => go(route.slug, "find"), true],
    [2, "Gather images", program && has ? `${picked} picked · ${program.media.filter((m) => !m.hidden).length} found` : "Online and from your files", () => go(route.slug, "gather"), has],
    [3, "Design the icon", has && pins != null ? `${pins} pinned` : "Suggestions and editor", () => go(route.slug, "design"), has],
    [4, "Review", has && pins ? `${pins} pinned${saved ? ` · ${saved} saved` : ""}` : "Compare and save", () => go(route.slug, "review"), has && !!pins,
      has && !pins ? "Pin a design to review it" : undefined],
  ];
  return (
    <nav className="crumbs" aria-label="Stages">
      {steps.map(([n, t, s, onClick, enabled, hint]) => (
        <button key={n} className={"crumb " + (n < cur ? "done" : n === cur ? "cur" : "later")} disabled={!enabled || n === cur}
          onClick={onClick} aria-current={n === cur ? "step" : undefined} title={hint ?? `${t}: ${s}`}>
          <span className="n">{n < cur ? "✓" : n}</span>
          <span className="t"><b>{t}</b><small>{hint ?? s}</small></span>
        </button>
      ))}
    </nav>
  );
}
