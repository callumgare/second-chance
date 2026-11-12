// "Adjust all": one set of parameters every suggestion is generated with (colours, the subject's size and
// place, the logo's size, the second element, pattern, dot size, letter), and which treatments to show.
import type { RoleKey, SuggestionParams } from "../../api";
import { NO_ROLES } from "../../state/app";
import { Slider, SwatchRow } from "../../components/controls";
import { XYPad } from "../../components/XYPad";
import { useApp } from "../../state/app";
import { useDesign } from "../../state/design";

export function AdjustAll({ full }: { full?: boolean }) {
  const p = useDesign((s) => s.params);
  const treatments = useDesign((s) => s.treatments);
  const enabled = useDesign((s) => s.enabled);
  const set = (x: Partial<SuggestionParams>) => useDesign.getState().setParams(x);
  const num = (k: keyof SuggestionParams, d: number) => (p[k] as number | undefined) ?? d;
  const changed = Object.keys(p).length > 0 || enabled != null;
  return (
    <div className="adjust">
      <div className="ph" style={{ padding: "0 0 6px", border: 0, minHeight: 0 }}>
        <span>Adjust all suggestions</span>
        <button className="btn small ghost" disabled={!changed} onClick={() => { useDesign.getState().resetParams(); useDesign.getState().setEnabled(null); }}>Reset</button>
      </div>
      <div className={full ? "" : "adjust-cols"}>
        <div>
          <div className="sec">Colours</div>
          <div className="lbl2">Primary</div><SwatchRow value={p.primary} onChange={(v) => set({ primary: v })} />
          <div className="lbl2">Secondary</div><SwatchRow value={p.secondary} onChange={(v) => set({ secondary: v })} />
          <div className="lbl2">Background</div><SwatchRow value={p.background} onChange={(v) => set({ background: v })} />
        </div>
        <div>
          <div className="sec">Subject</div>
          <Slider label="Size" value={num("scale", 1)} min={0.5} max={1.6} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set({ scale: v === 1 ? undefined : v })} />
          <div className="lbl2">Move</div>
          <div>
            <XYPad label="Subject move" x={num("dx", 0)} y={num("dy", 0)} xRange={[-0.3, 0.3]} yRange={[-0.3, 0.3]} size={72}
              onChange={(x, y) => set({ dx: Math.abs(x) < 1e-4 ? undefined : x, dy: Math.abs(y) < 1e-4 ? undefined : y })} />
          </div>
          <Slider label="Logo size" value={num("logoScale", 1)} min={0.5} max={1.5} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set({ logoScale: v === 1 ? undefined : v })} />
        </div>
        <div>
          <div className="sec">Second element</div>
          <div className="lbl2">Move</div>
          <div>
            <XYPad label="Second element move" x={num("dx2", 0)} y={num("dy2", 0)} xRange={[-0.3, 0.3]} yRange={[-0.3, 0.3]} size={72}
              onChange={(x, y) => set({ dx2: Math.abs(x) < 1e-4 ? undefined : x, dy2: Math.abs(y) < 1e-4 ? undefined : y })} />
          </div>
          <div className="sec">Details</div>
          <label className="kv wide"><span>Pattern</span>
            <select className="text" value={p.pattern ?? "solid"} onChange={(e) => set({ pattern: e.target.value === "solid" ? undefined : e.target.value })}>
              {["solid", "stripes", "dots", "grid", "checker", "rays"].map((x) => <option key={x}>{x}</option>)}
            </select>
          </label>
          <Slider label="Dot size" value={num("cell", 26)} min={8} max={64} step={1} format={(v) => `${v} pt`} onChange={(v) => set({ cell: v === 26 ? undefined : v })} />
          <Slider label="Angle" value={num("angle", 45)} min={0} max={360} step={1} format={(v) => `${v}°`} onChange={(v) => set({ angle: v === 45 ? undefined : v })} />
          <label className="kv wide"><span>Letter</span>
            <input className="text" style={{ width: 48 }} maxLength={2} value={p.letter ?? ""} placeholder="auto" onChange={(e) => set({ letter: e.target.value || undefined })} onKeyDown={(e) => e.stopPropagation()} />
          </label>
        </div>
        {full && <RolesPicker />}
        <div className={full ? "" : "span-all"}>
          <div className="sec">Treatments <span className="grow" />
            <button className="btn small ghost" onClick={() => useDesign.getState().setEnabled(null)} disabled={enabled == null}>All</button>
          </div>
          <div className="row" style={{ flexWrap: "wrap", gap: 4 }}>
            {treatments.map((t) => {
              const on = enabled == null || enabled.includes(t.key);
              return (
                <button key={t.key} className={"chip" + (on ? " on" : "")} title={t.about}
                  onClick={() => {
                    const cur = enabled ?? treatments.map((x) => x.key);
                    const next = on ? cur.filter((k) => k !== t.key) : [...cur, t.key];
                    useDesign.getState().setEnabled(next.length === treatments.length ? null : next);
                  }}>{t.title}</button>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

const ROLE_LABELS: Record<RoleKey, string> = { subject: "Subject", fill: "Fill art", disc: "Disc", logo: "Logo", icon: "Program icon" };

/** Which picked image plays each part (the program's defaults unless changed). */
function RolesPicker() {
  const program = useApp((s) => s.program);
  const roles = useDesign((s) => s.params.roles ?? NO_ROLES);
  if (!program) return null;
  const picked = program.media.filter((m) => m.picked);
  return (
    <div>
      <div className="sec">Which media</div>
      {(Object.keys(ROLE_LABELS) as RoleKey[]).map((r) => (
        <label key={r} className="kv wide"><span>{ROLE_LABELS[r]}</span>
          <select className="text" value={roles[r] ?? ""} onChange={(e) => useDesign.getState().setParams({ roles: { ...roles, [r]: e.target.value || undefined } })}>
            <option value="">{program.roles[r] ? `default (${program.media.find((m) => m.id === program.roles[r])?.kind ?? "?"})` : "none"}</option>
            {picked.map((m) => <option key={m.id} value={m.id}>{m.kind} · {m.name.slice(0, 28)}</option>)}
          </select>
        </label>
      ))}
    </div>
  );
}
