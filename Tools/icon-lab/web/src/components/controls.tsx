// Small form controls shared by the inspector and the "adjust all" panel.
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { NO_COLOURS } from "../state/app";
import { HexColorPicker } from "react-colorful";
import { isHex } from "../lib/colour";
import { useApp } from "../state/app";
import { Popup, usePopup } from "./Popup";

/** A labelled slider with a number field. `onChange` fires while dragging; `onCommit` when it's let go. */
export function Slider({ label, value, min, max, step = 0.01, onChange, onCommit, format, disabled }: {
  label: ReactNode; value: number; min: number; max: number; step?: number
  onChange(v: number): void; onCommit?(): void; format?: (v: number) => string; disabled?: boolean
}) {
  const shown = format ? format(value) : String(Math.round(value / step) * step).slice(0, 6);
  return (
    <label className="kv">
      <span>{label}</span>
      <input type="range" min={min} max={max} step={step} value={value} disabled={disabled}
        onChange={(e) => onChange(+e.target.value)}
        onPointerUp={onCommit} onKeyUp={onCommit} />
      <NumberField value={value} step={step} display={shown} disabled={disabled}
        onChange={(v) => { onChange(v); onCommit?.(); }} />
    </label>
  );
}

/** A number that edits as text and applies on Enter or blur; arrow keys step it. */
export function NumberField({ value, onChange, step = 0.01, display, disabled, className = "text num" }: {
  value: number; onChange(v: number): void; step?: number; display?: string; disabled?: boolean; className?: string
}) {
  const [text, setText] = useState<string | null>(null);
  const shown = text ?? display ?? String(+value.toFixed(4));
  const apply = () => {
    if (text == null) return;
    const v = Number(text.replace(/[^0-9.+-e]/g, ""));
    if (!Number.isNaN(v) && text.trim() !== "") onChange(v);
    setText(null);
  };
  return (
    <input className={className} value={shown} disabled={disabled}
      onFocus={(e) => { setText(String(+value.toFixed(4))); requestAnimationFrame(() => e.target.select()); }}
      onChange={(e) => setText(e.target.value)}
      onBlur={apply}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") { apply(); (e.target as HTMLInputElement).blur(); }
        else if (e.key === "Escape") { setText(null); (e.target as HTMLInputElement).blur(); }
        else if (e.key === "ArrowUp" || e.key === "ArrowDown") {
          e.preventDefault();
          const v = +(value + (e.key === "ArrowUp" ? 1 : -1) * step * (e.shiftKey ? 10 : 1)).toFixed(4);
          onChange(v); setText(String(v));
        }
      }} />
  );
}

export function Seg<T extends string>({ value, options, onChange, labels, fill }: {
  value: T; options: readonly T[]; onChange: (v: T) => void; labels?: Partial<Record<T, string>>; fill?: boolean
}) {
  return (
    <span className={"seg" + (fill ? " fill" : "")} role="radiogroup">
      {options.map((o) => (
        <button key={o} role="radio" aria-checked={o === value} className={o === value ? "on" : ""} onClick={() => onChange(o)}>
          {labels?.[o] ?? o[0].toUpperCase() + o.slice(1)}
        </button>
      ))}
    </span>
  );
}

export function Toggle({ label, checked, onChange }: { label: ReactNode; checked: boolean; onChange(v: boolean): void }) {
  return (
    <label className="row" style={{ gap: 5, fontSize: 11.5 }}>
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} /> {label}
    </label>
  );
}

/** A colour: a swatch that opens a picker offering the program's named colours, and the hex. */
export function ColourField({ value, onChange, allowNone, label }: {
  value: string | undefined | null; onChange(v: string | undefined): void; allowNone?: boolean; label?: string
}) {
  const pop = usePopup();
  const named = useNamedColours();
  const [hex, setHex] = useState(value ?? "");
  useEffect(() => setHex(value ?? ""), [value]);
  const nameOf = named.find(([, c]) => value && c.toLowerCase() === value.toLowerCase())?.[0];
  return (
    <span className="colour-field">
      <PaletteSwatches named={named} value={value} onChange={onChange} />
      <button className={"swatch free" + (value ? "" : " none")} title="Any colour…" style={value ? { background: value } : undefined}
        aria-label={label ? `${label}: ${value ?? "none"}` : value ?? "none"} onClick={(e) => pop.toggle(e.currentTarget)} />
      <input className="text hex" value={hex} placeholder={allowNone ? "auto" : ""} spellCheck={false}
        onChange={(e) => setHex(e.target.value)}
        onBlur={() => { const v = hex.startsWith("#") ? hex : "#" + hex; if (isHex(v)) onChange(v.toLowerCase()); else if (!hex && allowNone) onChange(undefined); else setHex(value ?? ""); }}
        onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
      {nameOf && <span className="faint wraps" style={{ fontSize: 10.5 }}>{nameOf}</span>}
      <Popup anchor={pop.anchor} onClose={pop.close}>
        <HexColorPicker color={value ?? "#888888"} onChange={(c) => onChange(c)} />
        {named.length > 0 && <>
          <div className="faint" style={{ fontSize: 10.5 }}>From the program's images</div>
          <div className="names">
            {named.map(([n, c]) => (
              <button key={n} className={"swatch" + (value?.toLowerCase() === c.toLowerCase() ? " on" : "")} style={{ background: c }} title={`${n} ${c}`} onClick={() => onChange(c)} />
            ))}
          </div>
        </>}
        {allowNone && <button className="btn small" onClick={() => { onChange(undefined); pop.close(); }}>Automatic</button>}
      </Popup>
    </span>
  );
}

/** The program's colours as swatches beside a colour control: the first few, and "+N" for the rest. The one
 * matching the value shows selected, which also says the colour is the palette's. */
function PaletteSwatches({ named, value, onChange }: { named: [string, string][]; value: string | undefined | null; onChange(v: string): void }) {
  const [all, setAll] = useState(false);
  if (!named.length) return null;
  const v = value?.toLowerCase();
  const FIRST = 8;
  // A chosen colour past the first few stays in view.
  const shown = all ? named : named.filter(([, c], i) => i < FIRST || c.toLowerCase() === v);
  const more = named.length - shown.length;
  return (
    <span className="sws pal">
      {shown.map(([n, c]) => (
        <button key={n} className={"swatch" + (v === c.toLowerCase() ? " on" : "")} style={{ background: c }} title={`${n} ${c}`} aria-label={`${n} ${c}`} onClick={() => onChange(c)} />
      ))}
      {more > 0 && <button className="sw-more" title="Show all the program's colours" onClick={() => setAll(true)}>+{more}</button>}
      {all && named.length > FIRST && <button className="sw-more" title="Show fewer" onClick={() => setAll(false)}>−</button>}
    </span>
  );
}

/** Named swatches in a row, plus a custom one: for "adjust all". */
export function SwatchRow({ value, onChange }: { value: string | undefined; onChange(v: string | undefined): void }) {
  const named = useNamedColours();
  const pop = usePopup();
  const custom = value && !named.some(([, c]) => c.toLowerCase() === value.toLowerCase());
  return (
    <div className="sws">
      <button className={"swatch none" + (!value ? " on" : "")} title="Automatic" onClick={() => onChange(undefined)} />
      {named.map(([n, c]) => (
        <button key={n} className={"swatch" + (value?.toLowerCase() === c.toLowerCase() ? " on" : "")} style={{ background: c }} title={`${n} ${c}`} onClick={() => onChange(value === c ? undefined : c)} />
      ))}
      <button className={"swatch" + (custom ? " on" : "")} title="Custom…" style={{ background: custom ? value : "conic-gradient(red, yellow, lime, cyan, blue, magenta, red)" }}
        onClick={(e) => pop.toggle(e.currentTarget)} />
      <Popup anchor={pop.anchor} onClose={pop.close}>
        <HexColorPicker color={value ?? "#888888"} onChange={(c) => onChange(c)} />
      </Popup>
    </div>
  );
}

/** The program's named colours, in the engine's `colourOrder` when it gives one. */
function useNamedColours(): [string, string][] {
  const colours = useApp((s) => s.program?.colours ?? NO_COLOURS);
  const order = useApp((s) => s.program?.colourOrder);
  return useMemo(() => {
    const names = order?.length ? [...order.filter((n) => n in colours), ...Object.keys(colours).filter((n) => !order.includes(n))] : Object.keys(colours);
    return names.map((n) => [n, colours[n]] as [string, string]);
  }, [colours, order]);
}
