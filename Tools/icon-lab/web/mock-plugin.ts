// Dev-only: serves the old prototype's per-game folders to the in-browser mock API, plus a fixtures.json that turns
// each game's analysis.json into the engine's Program/Media shape. ICON_LAB_MOCK_GAMES names the folder; without it
// the mock has no programs.
import fs from "node:fs";
import path from "node:path";
import type { Plugin } from "vite";

const GAMES = process.env.ICON_LAB_MOCK_GAMES ? path.resolve(process.env.ICON_LAB_MOCK_GAMES) : "";

const TYPES: Record<string, string> = {
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
  ".json": "application/json", ".bmp": "image/bmp",
};

function mediaId(name: string) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function kindOf(kind: string | undefined, name: string): string {
  const n = name.toLowerCase();
  if (/back/.test(n)) return "box-back";
  if (/spine/.test(n)) return "box-spine";
  if (/sddefault|hqdefault|screenshot|screen/.test(n)) return "screenshot";
  switch (kind) {
    case "cover": return "box-front";
    case "disc": return "disc";
    case "logo": return "logo";
    case "icon": return "icon";
    case "title": return "title-screen";
    case "art": return "art";
    default: return "other";
  }
}

function readJSON(file: string): any {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

function fixtures() {
  const programs: any[] = [];
  if (!GAMES || !fs.existsSync(GAMES)) return { programs };
  for (const slug of fs.readdirSync(GAMES).sort()) {
    const dir = path.join(GAMES, slug);
    const game = readJSON(path.join(dir, "game.json"));
    const analysis = readJSON(path.join(dir, "analysis.json"));
    if (!game || !analysis) continue;
    const picks: any[] = readJSON(path.join(dir, "picks.json")) ?? [];
    const used = new Set<string>();
    for (const p of picks) for (const v of Object.values(p.roles ?? {})) if (v) used.add(v as string);
    const base = `/mock-files/${slug}`;
    const media = Object.values(analysis as Record<string, any>).map((a) => {
      const name: string = a.name;
      const [w, h] = a.size ?? [a.vision?.width ?? 512, a.vision?.height ?? 512];
      const prev = readJSON(path.join(dir, "preview", name + ".json"));
      const scores = a.scores ?? {};
      const best = Math.max(0, ...Object.values(scores as Record<string, number>));
      const m = a.metrics ?? {};
      let subjectBox: number[] | undefined;
      if (prev?.box && prev?.size) {
        const [x0, y0, x1, y1] = prev.box; const [pw, ph] = prev.size;
        subjectBox = [x0 / pw, y0 / ph, (x1 - x0) / pw, (y1 - y0) / ph].map((v) => Math.round(v * 1000) / 1000);
      }
      const maskBase = name.replace(/\.[^.]+$/, "");
      const hasMask = fs.existsSync(path.join(dir, "masks", maskBase + ".png"));
      const hasCutout = prev?.cutout && fs.existsSync(path.join(dir, prev.cutout));
      return {
        id: mediaId(name),
        name,
        kind: kindOf(a.kind, name),
        kindConfidence: 0.7,
        source: name.startsWith("wikipedia") ? "Wikipedia" : name.startsWith("ia-") ? "Internet Archive" : "Your files",
        width: w, height: h,
        url: `${base}/images/${encodeURIComponent(name)}`,
        thumb: fs.existsSync(path.join(dir, "images", name + ".thumb.png")) ? `${base}/images/${encodeURIComponent(name)}.thumb.png` : `${base}/images/${encodeURIComponent(name)}`,
        cutout: hasCutout ? `${base}/${prev.cutout.split("/").map(encodeURIComponent).join("/")}` : undefined,
        mask: hasMask ? `${base}/masks/${encodeURIComponent(maskBase)}.png` : undefined,
        picked: used.has(name),
        analysis: {
          subject: !!a.vision?.subject,
          subjectBox,
          flatSides: prev?.flat ?? [],
          text: (a.vision?.text ?? []).slice(0, 12),
          textFraction: a.vision?.textFraction ?? 0,
          busyness: Math.round((m.entropy ?? 0.5) * 100) / 100,
          palette: [],
          circle: (m.circle ?? 0) > 0.6 && m.circle_at ? m.circle_at : undefined,
          pixelArt: kindOf(a.kind, name) === "icon" || undefined,
          scores,
        },
        suitability: Math.round(Math.min(5, best * 6) * 10) / 10,
      };
    });
    // Pick a handful more of the best ones so the drawer isn't empty.
    const ranked = [...media].sort((a, b) => b.suitability - a.suitability);
    for (const m of ranked.slice(0, 6)) m.picked = true;
    const roles: Record<string, string> = {};
    for (const [k, v] of Object.entries(picks[0]?.roles ?? {})) if (v) roles[k] = mediaId(v as string);
    const exists = (id: string) => media.some((m) => m.id === id);
    for (const k of Object.keys(roles)) if (!exists(roles[k])) delete roles[k];
    if (!roles.icon) { const icon = media.find((m) => m.kind === "icon"); if (icon) roles.icon = icon.id; }
    if (!roles.logo) { const logo = media.find((m) => m.kind === "logo"); if (logo) roles.logo = logo.id; }
    programs.push({ slug, title: game.title, year: game.year, media, roles, colours: {} });
  }
  return { programs };
}

export function mockFiles(): Plugin {
  return {
    name: "icon-lab-mock-files",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use("/mock-files", (req, res, next) => {
        const url = decodeURIComponent((req.url ?? "/").split("?")[0]);
        if (url === "/fixtures.json") {
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify(fixtures()));
          return;
        }
        if (url === "/scan-sample.jsonl") {
          // A real icon-extract run (over a wrapp), replayed by the mock's scans.
          res.setHeader("Content-Type", "application/x-ndjson");
          fs.createReadStream(path.resolve(__dirname, "mock-data/scan-sample.jsonl")).pipe(res);
          return;
        }
        const file = path.join(GAMES, path.normalize(url));
        if (!GAMES || !file.startsWith(GAMES) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return next();
        res.setHeader("Content-Type", TYPES[path.extname(file).toLowerCase()] ?? "application/octet-stream");
        res.setHeader("Cache-Control", "max-age=3600");
        fs.createReadStream(file).pipe(res);
      });
    },
  };
}
