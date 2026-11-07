// Stage 1: find the program. One search box over every catalogue; results stream in as each source answers,
// merged into one row per program and re-ranked as they come. Recent programs sit below; the sources panel
// says what each source is doing.
import { useEffect, useMemo, useRef, useState } from "react";
import { api, type KnownProgram, type ProgramResult, type ProgramSummary, type SearchSnapshot, type SourceInfo } from "../../api";
import { go, type Route } from "../../lib/router";
import { useApp } from "../../state/app";
import { useSearch } from "../../state/search";
import { StatusSlot } from "../../shell/slots";
import "./find.css";

const KINDS = [["all", "All"], ["game", "Games"], ["software", "Software"], ["demo", "Demos"], ["remake", "Remakes"]] as const;
type KindFilter = (typeof KINDS)[number][0];
const WEAK = 35;

export function FindStage({ route }: { route: Route }) {
  const programs = useApp((s) => s.programs);
  const { q, current, snapshots, sources, error } = useSearch();
  const [text, setText] = useState(q);
  const [kind, setKind] = useState<KindFilter>("all");
  const [showWeak, setShowWeak] = useState(false);
  const [active, setActive] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => { void useSearch.getState().loadSources(); void useApp.getState().loadPrograms(); }, []);
  // Search as you type, a moment after you stop.
  useEffect(() => {
    if (text === useSearch.getState().q) return;
    const t = window.setTimeout(() => void useSearch.getState().run(text), 300);
    return () => window.clearTimeout(t);
  }, [text]);

  const snap: SearchSnapshot | null = current ? snapshots[current] ?? null : null;
  const all = snap?.results ?? [];
  const counts = useMemo(() => Object.fromEntries(KINDS.map(([k]) => [k, k === "all" ? all.length : all.filter((r) => r.kind === k).length])), [all]);
  const byKind = all.filter((r) => kind === "all" || r.kind === kind);
  const strong = byKind.filter((r) => r.score >= WEAK);
  const shown = showWeak ? byKind : strong;
  const weakHidden = byKind.length - strong.length;
  const names = useMemo(() => {
    const m = new Map<string, string>();
    for (const s of sources ?? []) m.set(s.id, s.name);
    for (const s of snap?.sources ?? []) m.set(s.id, s.name);
    return m;
  }, [sources, snap]);
  useEffect(() => setActive(0), [current, kind]);

  const choose = async (r: ProgramResult) => {
    setBusy(r.key);
    try {
      const p = await api.createProgram(r);
      api.gather(p.slug).catch((e: unknown) => useApp.getState().say("Couldn't start gathering images: " + (e as Error).message, "error"));
      void useApp.getState().loadPrograms();
      go(p.slug, "gather");
    } catch (e) {
      useApp.getState().say((e as Error).message, "error");
    } finally { setBusy(null); }
  };

  const running = snap?.sources.filter((s) => s.running) ?? [];
  const answered = snap ? snap.sources.filter((s) => s.state === "ready" && !s.running).length : 0;
  const usable = snap ? snap.sources.filter((s) => s.state === "ready").length : (sources ?? []).filter((s) => s.state === "ready").length;

  return (
    <div className="s1">
      <div className="centre">
        <label className="searchbox">
          <svg width="22" height="22" viewBox="0 0 24 24" aria-hidden><circle cx="10.5" cy="10.5" r="6.5" fill="none" stroke="currentColor" strokeWidth="2" /><path d="M15.5 15.5 21 21" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg>
          <input ref={input} autoFocus value={text} placeholder="Search for a game or program" spellCheck={false} aria-label="Search for a program"
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => Math.min(shown.length - 1, a + 1)); }
              else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(0, a - 1)); }
              else if (e.key === "Enter") { if (text !== q) void useSearch.getState().run(text); else if (shown[active]) void choose(shown[active]); }
              else if (e.key === "Escape") setText("");
            }} />
          {snap && !snap.done && <span className="spin" />}
          <span className="hint">{!text.trim() ? "Type a name, part of one, or a year" : snap ? `${answered} of ${usable} sources answered` : "Searching…"}</span>
        </label>

        {text.trim() && (
          <div className="kinds">
            {KINDS.map(([k, label]) => (
              <button key={k} className={"chip" + (kind === k ? " on" : "")} onClick={() => setKind(k)} disabled={k !== "all" && !counts[k]}>
                {label} <span className="ct">{counts[k]}</span>
              </button>
            ))}
            <span className="faint sortnote">
              Sorted by match{weakHidden > 0 && !showWeak && <> · {weakHidden} weaker {weakHidden === 1 ? "match" : "matches"} hidden <button className="linkish" onClick={() => setShowWeak(true)}>show</button></>}
              {showWeak && weakHidden > 0 && <> · <button className="linkish" onClick={() => setShowWeak(false)}>hide weaker</button></>}
            </span>
          </div>
        )}

        <div className="scroll results-scroll">
          <KnownPrograms filter={text} />
          {error && <div className="notice bad">Search failed: {error}</div>}
          {text.trim() && (
            <div className="results" role="listbox" aria-label="Results">
              {shown.map((r, i) => <ResultRow key={r.key} r={r} active={i === active} busy={busy === r.key} names={names} onChoose={() => void choose(r)} onHover={() => setActive(i)} />)}
              {snap && !shown.length && (snap.done ? <div className="empty">Nothing found for “{snap.q}”. Try fewer words, or another spelling.</div> : <div className="empty"><span className="spin" /> Waiting for the sources…</div>)}
              {!snap && !error && <div className="empty"><span className="spin" /> Searching…</div>}
            </div>
          )}
          <Recents programs={programs} current={route.slug} />
        </div>
      </div>

      <SourcesPanel snap={snap} sources={sources} />

      <StatusSlot.Fill>
        {snap && !snap.done ? <span className="row" style={{ gap: 6 }}><span className="spin" /> Searching {running.slice(0, 3).map((s) => s.name).join(", ")}{running.length > 3 ? ` and ${running.length - 3} more` : ""}…</span>
          : snap ? <span>{all.length} programs from {snap.sources.reduce((n, s) => n + s.count, 0)} matches</span>
          : <span>{programs ? `${programs.length} programs worked on` : "Ready"}</span>}
        <span className="faint">↑↓ choose · Enter opens · Esc clears</span>
      </StatusSlot.Fill>
    </div>
  );
}

function ResultRow({ r, active, busy, names, onChoose, onHover }: { r: ProgramResult; active: boolean; busy: boolean; names: Map<string, string>; onChoose(): void; onHover(): void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [broken, setBroken] = useState(false);
  useEffect(() => { if (active) ref.current?.scrollIntoView({ block: "nearest" }); }, [active]);
  const srcs = [...new Set(r.hits.map((h) => h.source))];
  const thumb = r.thumb ?? r.hits.find((h) => h.thumb)?.thumb;
  const linkOnly = Object.entries(r.links ?? {}).filter(([id]) => !srcs.includes(id));
  return (
    <div ref={ref} className={"res" + (active ? " top" : "")} role="option" aria-selected={active} onMouseEnter={onHover}>
      <button className="res-main" onClick={onChoose} disabled={busy}>
        {thumb && !broken ? <img className="th" src={thumb} alt="" loading="lazy" onError={() => setBroken(true)} /> : <KindIcon kind={r.kind} />}
        <span className="res-body">
          <h3>{r.title} {r.year && <span className="yr">{r.year}</span>}
            {r.kind && r.kind !== "game" && <span className={"tag" + (r.kind === "remake" ? " warn" : "")}>{r.kind}</span>}
          </h3>
          <span className="meta">
            {[r.developer, r.publisher && r.publisher !== r.developer ? r.publisher : null].filter(Boolean).join(" · ") || <span className="faint">maker unknown</span>}
            {r.platforms?.length > 0 && <span title={r.platforms.join(", ")}> · {r.platforms.slice(0, 4).join(", ")}{r.platforms.length > 4 ? ` and ${r.platforms.length - 4} more` : ""}</span>}
            {r.kind === "remake" && <span className="warnText"> · a remake: it may run on a Mac already</span>}
          </span>
          <span className="srcs">{srcs.map((s) => <span key={s} className="tag">{names.get(s) ?? s}</span>)}</span>
        </span>
        <span className="match"><b>{Math.round(r.score)}</b>match<span>{srcs.length} {srcs.length === 1 ? "source" : "sources"}</span></span>
      </button>
      {(r.mergeReasons.length > 0 || linkOnly.length > 0 || r.hits.length > 1) && (
        <details className="merge">
          <summary>{r.hits.length > 1 ? `Why these ${r.hits.length} were merged` : "More"}</summary>
          {r.mergeReasons.map((m, i) => <div key={i}>· {m}</div>)}
          {r.hits.length > 1 && <div className="hits">{r.hits.map((h, i) => (
            <div key={i}><span className="tag">{names.get(h.source) ?? h.source}</span> {h.title}{h.year ? ` (${h.year})` : ""}{h.platforms?.length ? ` · ${h.platforms.join(", ")}` : ""}{h.url && <> · <a href={h.url} target="_blank" rel="noreferrer">page ↗</a></>}</div>
          ))}</div>}
          {linkOnly.length > 0 && <div>Also at: {linkOnly.map(([id, url], i) => <span key={id}>{i > 0 && ", "}<a href={url} target="_blank" rel="noreferrer">{names.get(id) ?? id} ↗</a></span>)}</div>}
        </details>
      )}
      {busy && <div className="res-busy"><span className="spin" /> Opening…</div>}
    </div>
  );
}

function KindIcon({ kind }: { kind?: string }) {
  return (
    <span className="th generic" aria-hidden title={kind ?? "program"}>
      {kind === "software" ? (
        <svg viewBox="0 0 32 32" width="30" height="30"><rect x="4" y="6" width="24" height="18" rx="2.5" fill="none" stroke="currentColor" strokeWidth="2" /><path d="M4 11h24" stroke="currentColor" strokeWidth="2" /><path d="M12 28h8" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg>
      ) : (
        <svg viewBox="0 0 32 32" width="30" height="30"><rect x="3" y="10" width="26" height="14" rx="7" fill="none" stroke="currentColor" strokeWidth="2" /><path d="M10 14v6M7 17h6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /><circle cx="21" cy="15.5" r="1.6" fill="currentColor" /><circle cx="24" cy="18.5" r="1.6" fill="currentColor" /></svg>
      )}
    </span>
  );
}

/** The programs the host has bundles for (Second Chance's), above the search's results: choosing one opens the
 *  program kept for its bundle, made the first time. */
function KnownPrograms({ filter }: { filter: string }) {
  const [known, setKnown] = useState<KnownProgram[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [all, setAll] = useState(false);
  useEffect(() => { api.knownPrograms().then(setKnown).catch(() => setKnown([])); }, []);
  if (!known?.length) return null;
  const words = filter.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const matching = known.filter((k) => words.every((w) => k.title.toLowerCase().includes(w) || k.id.includes(w)));
  if (!matching.length) return null;
  const shown = all || words.length ? matching : matching.slice(0, 12);
  const open = async (k: KnownProgram) => {
    setBusy(k.id);
    try {
      const { slug } = await api.openKnown(k.id);
      if (!k.opened) api.gather(slug).catch((e: unknown) => useApp.getState().say("Couldn't start gathering images: " + (e as Error).message, "error"));
      void useApp.getState().loadPrograms();
      go(slug, k.opened ? "design" : "gather");
    } catch (e) {
      useApp.getState().say((e as Error).message, "error");
    } finally { setBusy(null); }
  };
  return (
    <div className="recent known">
      <h2>Second Chance's programs</h2>
      <div className="recents">
        {shown.map((k) => (
          <button key={k.id} className="rec" onClick={() => void open(k)} disabled={busy === k.id} title={k.id}>
            <span className="rec-ph" />
            <span className="ellipsis"><b className="ellipsis">{k.title}</b><small>{k.id}{k.opened ? " · opened" : ""}</small></span>
          </button>
        ))}
      </div>
      {!all && !words.length && matching.length > shown.length && (
        <button className="linkish" onClick={() => setAll(true)}>Show all {matching.length}</button>
      )}
    </div>
  );
}

function Recents({ programs, current }: { programs: ProgramSummary[] | null; current: string | null }) {
  if (!programs) return <div className="recent"><h2>Recent</h2><div className="empty"><span className="spin" /></div></div>;
  if (!programs.length) return null;
  return (
    <div className="recent">
      <h2>Recent</h2>
      <div className="recents">
        {programs.map((p) => (
          <button key={p.slug} className={"rec" + (p.slug === current ? " cur" : "")} onClick={() => go(p.slug, p.pins ? "design" : "gather")} title={p.slug}>
            {p.thumb ? <img src={p.thumb} alt="" loading="lazy" /> : <span className="rec-ph" />}
            <span className="ellipsis"><b className="ellipsis">{p.title}</b><small>{p.year ? `${p.year} · ` : ""}{p.media} images{p.pins ? ` · ${p.pins} pinned` : ""}</small></span>
          </button>
        ))}
      </div>
    </div>
  );
}

function SourcesPanel({ snap, sources }: { snap: SearchSnapshot | null; sources: SourceInfo[] | null }) {
  const rows = snap?.sources ?? (sources ?? []).map((s) => ({ ...s, running: false, count: -1 }));
  const info = new Map((sources ?? []).map((s) => [s.id, s]));
  const order = (s: { state: string; local?: boolean }) => (s.state === "ready" ? (s.local ? 0 : 1) : s.state === "needsKey" ? 2 : s.state === "linkOnly" ? 3 : 4);
  const sorted = [...rows].sort((a, b) => order({ ...a, local: info.get(a.id)?.local }) - order({ ...b, local: info.get(b.id)?.local }));
  const running = rows.filter((s) => s.running).length;
  return (
    <aside className="panel sources">
      <div className="ph">Sources
        <span className="row" style={{ gap: 6 }}>
          <small>{snap ? (running ? `searching ${running} more` : "all answered") : sources ? `${rows.filter((s) => s.state === "ready").length} ready` : ""}</small>
          <button className="btn small ghost" title="Download the local copies (LaunchBox, TheGamesDB…) now if they're missing or old"
            onClick={() => void api.refreshSources().then((s) => useSearch.setState({ sources: s })).catch((e) => useApp.getState().say((e as Error).message, "error"))}>Refresh</button>
        </span>
      </div>
      <div className="scroll">
        <div className="srclist">
          {sorted.map((s) => {
            const local = info.get(s.id)?.local;
            const home = info.get(s.id)?.homepage;
            return (
              <div key={s.id} className={"src" + (s.count === 0 || s.state !== "ready" ? " zero" : "")} title={s.note ?? ""}>
                {s.running ? <span className="spin" /> : <span className={"dot " + (s.state === "needsKey" ? "warn" : s.state === "ready" ? (s.count === 0 ? "off" : "") : "off")} />}
                <span className="src-name">
                  {home ? <a href={home} target="_blank" rel="noreferrer">{s.name}</a> : s.name}
                  {local && <span className="tag">local</span>}
                  {s.state === "linkOnly" && <span className="tag">link only</span>}
                  {s.state === "needsKey" && <span className="st">needs a key</span>}
                  {s.state === "disabled" && <span className="st">off</span>}
                  {s.note && <small className="faint">{s.note}</small>}
                </span>
                <span className="n">{s.state !== "ready" ? "–" : s.running || s.count < 0 ? "" : s.count}</span>
              </div>
            );
          })}
          {!rows.length && <div className="empty"><span className="spin" /></div>}
        </div>
        <p className="faint about">Local copies (LaunchBox, TheGamesDB) answer at once. Live sources are rate-limited and cached; the Internet Archive gets one request every 4 s. “Link only” sites forbid automated access, so a result links to them instead.</p>
      </div>
    </aside>
  );
}
