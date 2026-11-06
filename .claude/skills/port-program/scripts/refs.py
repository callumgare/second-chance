#!/usr/bin/env python3
"""Look up what other porting projects know about a program.

Sources, each cached under $PORTING_REFS_DIR (default
~/Library/Caches/second-chance-porting):

  crossover  CodeWeavers' CrossTie database: ~5,000 Windows programs, each with
             its install notes, the components it needs (winetricks-like
             dependencies), registry and DLL-override tweaks, the Windows
             version and CD/installer globs, and how well it ran ("medals")
             by CrossOver version. Read from the CrossOver app or the copy it
             keeps updated in Application Support. Only on this Mac; never
             committed or copied into a bundle.
  pk         Porting Kit's list of ports (~1,500), with each port's description
             fetched from its public API on demand. A port's recipe (.wsi3:
             its Wine engine, winetricks, registry, renderer and launch
             steps) isn't served openly: it's read from .wsi3 files on this
             Mac — ones saved from Porting Kit, or the pk_backup.wsi3 inside a
             port Porting Kit installed.
  lutris     Lutris's install scripts (its public API), fetched on demand.
  pcgw       PCGamingWiki's infobox (its public Cargo API), fetched on demand.

  refs.py sync                         rebuild the local indexes (CrossOver, Porting Kit)
  refs.py search <words>…              search every index by name
  refs.py show crossover:<appid>       one CrossTie profile, dependencies named
  refs.py show pk:<id>                 a Porting Kit port's description (and its .wsi3 if one is here)
  refs.py wsi <file.wsi3>              summarise a .wsi3 recipe
  refs.py draft crossover:<id>         candidate Wrappfile lines from a CrossTie, each naming its source,
  refs.py draft pk:<id>|<file.wsi3>      or from a Porting Kit recipe; then what it couldn't map
                                       (the mapping is draft-map.json, beside this script)
  refs.py draft --check-map            check draft-map.json's verbs and CrossTie ids
  refs.py lutris <words>…              Lutris games and their install scripts
  refs.py pcgw <title>                 PCGamingWiki's page facts for a title

Run with python3 -I (only the standard library is used).
"""

from __future__ import annotations

import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

CACHE = Path(os.environ.get("PORTING_REFS_DIR", Path.home() / "Library/Caches/second-chance-porting"))
UA = "second-chance-porting-refs/1 (a local lookup tool)"
PK_API = "https://www.portingkit.com/api3"
TIE_IN_APP = "Contents/SharedSupport/CrossOver/share/crossover/data/crossover.tie"


# ---------------------------------------------------------------- helpers

# archive.org asks scrapers for at most one request every 4 seconds (search, metadata, downloads, Wayback).
SPACING = {"archive.org": 4.0}
_last: dict[str, float] = {}


def fetch(url: str, *, data: bytes | None = None, headers: dict | None = None) -> bytes:
    host = urllib.parse.urlparse(url).hostname or ""
    for domain, gap in SPACING.items():
        if host == domain or host.endswith("." + domain):
            wait = _last.get(domain, 0) + gap - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            _last[domain] = time.monotonic()
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def cached_fetch(path: Path, url: str, max_age_days: float = 30) -> bytes:
    if path.exists() and time.time() - path.stat().st_mtime < max_age_days * 86400:
        return path.read_bytes()
    body = fetch(url)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)
    return body


def norm(s: str) -> str:
    s = s.lower().replace("&", " and ")
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(w for w in s.split() if w not in {"the", "a", "an"})


def strip_html(s: str) -> str:
    s = re.sub(r"<\s*(br|/div|/p|/li)\s*/?>", "\n", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s)
    return re.sub(r"\n\s*\n+", "\n\n", s).strip()


def mdfind(query: str) -> list[str]:
    try:
        out = subprocess.run(["mdfind", query], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [l for l in out.splitlines() if l]


# ---------------------------------------------------------------- CrossOver

def find_ties() -> list[Path]:
    """Every crossover.tie on this Mac, newest first."""
    found: list[Path] = []
    support = Path.home() / "Library/Application Support/CrossOver/tie/crossover.tie"
    if support.exists():
        found.append(support)
    apps = set(mdfind("kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver'"))
    apps |= {"/Applications/CrossOver.app", str(Path.home() / "Applications/CrossOver.app")}
    for app in apps:
        p = Path(app) / TIE_IN_APP
        if p.exists():
            found.append(p)
    return sorted(set(found), key=lambda p: p.stat().st_mtime, reverse=True)


def localised_out(el: ET.Element) -> None:
    """Drop translations: keep elements with no lang or lang="en"."""
    for child in list(el):
        lang = child.get("lang")
        if lang and lang != "en":
            el.remove(child)
        else:
            localised_out(child)


def text_of(el: ET.Element, tag: str) -> str | None:
    for c in el.iter(tag):
        if c.get("lang") in (None, "en") and c.text:
            return c.text.strip()
    return None


def medal_summary(app: ET.Element) -> str:
    """The latest Mac medal, and the best Mac medal ever."""
    order = ["knownnottowork", "untested", "ungold", "bronze", "silver", "gold"]
    mac = [m for m in app.iter("medal") if m.get("platform") == "Mac" and m.text]
    if not mac:
        return ""
    latest = max(mac, key=lambda m: m.get("last", ""))
    best = max(mac, key=lambda m: order.index(m.text) if m.text in order else 0)
    return f"mac latest {latest.text} ({latest.get('version')}, {latest.get('last','')[:10]}); best {best.text} ({best.get('version')})"


def sync_crossover() -> None:
    ties = find_ties()
    if not ties:
        print("crossover: no CrossOver found (looked in Application Support and every CrossOver.app)")
        return
    tie = ties[0]
    out = CACHE / "crossover"
    (out / "apps").mkdir(parents=True, exist_ok=True)
    index = []
    for _, el in ET.iterparse(tie, events=("end",)):
        if el.tag != "app":
            continue
        appid = el.get("appid", "")
        localised_out(el)
        for banner in list(el.iter("icon")):
            banner.text = None
        name = text_of(el, "name") or appid
        index.append({
            "id": appid,
            "name": name,
            "category": text_of(el, "category") or "",
            "steamid": text_of(el, "steamid") or "",
            "medals": medal_summary(el),
            "bottle": text_of(el, "bottletemplate") or "",
        })
        (out / "apps" / f"{appid}.xml").write_text(ET.tostring(el, encoding="unicode"))
        el.clear()
    (out / "index.json").write_text(json.dumps(index, indent=0))
    (out / "source.txt").write_text(f"{tie}\nmodified {time.ctime(tie.stat().st_mtime)}\n")
    print(f"crossover: {len(index)} profiles from {tie}")


def show_crossover(appid: str) -> None:
    if not appid.startswith("com."):
        appid = f"com.codeweavers.c4.{appid}"
    path = CACHE / "crossover/apps" / f"{appid}.xml"
    if not path.exists():
        sys.exit(f"no CrossTie {appid} (run refs.py sync?)")
    names = {a["id"]: a["name"] for a in json.loads((CACHE / "crossover/index.json").read_text())}
    xml = path.read_text()
    # Leave out the long marketing description; name each dependency.
    xml = re.sub(r"<description[^>]*>.*?</description>\s*", "", xml, flags=re.S)
    xml = re.sub(r">(com\.codeweavers\.[\w.]+)<", lambda m: f">{m.group(1)} [{names.get(m.group(1), '?')}]<", xml)
    print(xml)


# ---------------------------------------------------------------- Porting Kit

def sync_pk() -> None:
    out = CACHE / "pk"
    out.mkdir(parents=True, exist_ok=True)
    try:
        apps = json.loads(fetch(f"{PK_API}/listApps1.0.php"))
        (out / "index.json").write_text(json.dumps(apps, indent=0))
        print(f"pk: {len(apps)} ports listed")
    except Exception as e:  # noqa: BLE001 - a lookup tool: say what failed, carry on
        print(f"pk: couldn't fetch the list of ports: {e}")
    # Recipes on this Mac: saved .wsi3 files and installed ports' pk_backup.wsi3.
    wsis = [p for p in mdfind("kMDItemFSName == '*.wsi3'") if "/Code/User/History/" not in p]
    (out / "local-wsi3.json").write_text(json.dumps(wsis, indent=0))
    print(f"pk: {len(wsis)} .wsi3 recipes on this Mac")


def wsi_summary(path: str) -> str:
    d = json.loads(Path(path).read_text())
    lines = [f"{d.get('name')}  (wsi {d.get('wsiVersion')}, id {d.get('id')}, {d.get('system')}/{d.get('type')}, {d.get('bits')}-bit, source {d.get('source')})"]
    for step in d.get("steps", []):
        props = step.get("properties")
        cond = step.get("conditions") or {}
        lines.append(f"  {step.get('type')}: {json.dumps(props)}" + (f"  if {json.dumps(cond)}" if cond else ""))
    return "\n".join(lines)


def show_pk(pid: str) -> None:
    body = cached_fetch(CACHE / "pk/descriptions" / f"{pid}.json", f"{PK_API}/getDescription1.2.php?id={pid}")
    d = json.loads(body)
    print(f"{d.get('name')} (Porting Kit {pid}, by {d.get('creator')}, updated {d.get('updated')})")
    print(strip_html(d.get("description", "")))
    local = CACHE / "pk/local-wsi3.json"
    for p in json.loads(local.read_text()) if local.exists() else []:
        try:
            if str(json.loads(Path(p).read_text()).get("id")) == pid:
                print(f"\n.wsi3 at {p}:\n{wsi_summary(p)}")
        except (OSError, ValueError):
            pass


# ---------------------------------------------------------------- search

def search(words: list[str]) -> None:
    q = norm(" ".join(words)).split()
    def hit(name: str) -> bool:
        # Each word of the query starts a word of the name: "iji" finds Iji, not Mijia.
        words = norm(name).split()
        return all(any(n.startswith(w) for n in words) for w in q)
    cx = CACHE / "crossover/index.json"
    if cx.exists():
        for a in json.loads(cx.read_text()):
            if hit(a["name"]):
                print(f"crossover:{a['id'].rsplit('.', 1)[-1]:<6} {a['name']}  [{a['category']}] {a['medals']}" + (f" bottle={a['bottle']}" if a["bottle"] else ""))
    pk = CACHE / "pk/index.json"
    if pk.exists():
        for a in json.loads(pk.read_text()):
            if hit(a["name"]):
                print(f"pk:{a['id']:<6} {a['name']}  (updated {a.get('updated')}, steam {a.get('steam_id') or '-'}, gog {a.get('gog_id') or '-'})")
    local = CACHE / "pk/local-wsi3.json"
    for p in json.loads(local.read_text()) if local.exists() else []:
        if hit(Path(p).stem):
            print(f"wsi3: {p}")
    if not cx.exists() and not pk.exists():
        print("no indexes yet: run refs.py sync")


# ---------------------------------------------------------------- Lutris, PCGamingWiki

def lutris(words: list[str]) -> None:
    q = urllib.parse.quote(" ".join(words))
    games = json.loads(fetch(f"https://lutris.net/api/games?search={q}"))
    for g in games.get("results", [])[:8]:
        print(f"{g['slug']}: {g['name']} ({g.get('year')}) platforms {[p['name'] for p in g.get('platforms', [])]}")
    if games.get("results"):
        # Lutris ranks loosely: an exact slug wins over its first result.
        want = norm(" ".join(words)).replace(" ", "-")
        slugs = [g["slug"] for g in games["results"]]
        slug = want if want in slugs else slugs[0]
        print(f"\ninstallers for {slug}:")
        inst = json.loads(fetch(f"https://lutris.net/api/installers/{slug}"))
        for i in inst.get("results", inst if isinstance(inst, list) else []):
            print(f"\n--- installer {i.get('slug')} runner={i.get('runner')} version={i.get('version')}")
            print(i.get("content") or json.dumps(i.get("script"), indent=1))


def pcgw(title: list[str]) -> None:
    """Its arbitrary Cargo queries are closed to the public (2026), so: search, then the page's wikitext."""
    api = "https://www.pcgamingwiki.com/w/api.php?"
    found = json.loads(fetch(api + urllib.parse.urlencode(
        {"action": "query", "list": "search", "srsearch": " ".join(title), "format": "json", "srlimit": "5"})))
    hits = found.get("query", {}).get("search", [])
    for h in hits:
        print(f"{h['title']}: https://www.pcgamingwiki.com/wiki/{urllib.parse.quote(h['title'].replace(' ', '_'))}")
    if not hits:
        return
    page = json.loads(fetch(api + urllib.parse.urlencode(
        {"action": "parse", "page": hits[0]["title"], "prop": "wikitext", "format": "json", "redirects": "1"})))
    text = page.get("parse", {}).get("wikitext", {}).get("*", "")
    # The parts that matter for running it: the infobox, then fixes and settings, not the
    # long tables of keys and controller support.
    keep = []
    for section in re.split(r"(?m)^(?===[^=])", text):
        head = section.splitlines()[0] if section else ""
        if not head.startswith("==") or re.search(r"Availability|Essential|Issues|Game data|Video|Audio|System requirements|Other information|Compatibility", head):
            keep.append(section)
    print(f"\n--- {hits[0]['title']}\n" + "".join(keep)[:12000])


# ---------------------------------------------------------------- draft

# The repo this script sits in (.claude/skills/port-program/scripts/refs.py), for our winetricks.
REPO = Path(__file__).resolve().parents[4]
WINETRICKS = REPO / "Packages/Modules/wine/Sources/WineExecutor/Resources/winetricks"
DRAFT_MAP = Path(__file__).with_name("draft-map.json")
OVERRIDE_VERB = re.compile(r"^[\w.*-]+=(native|builtin|default|disabled)$")


def load_map() -> dict:
    return json.loads(DRAFT_MAP.read_text())


def winetricks_text() -> str:
    try:
        return WINETRICKS.read_text(errors="replace")
    except OSError:
        return ""


def winetricks_verbs() -> set[str]:
    """The verbs our winetricks has, read from its w_metadata lines (never run)."""
    return set(re.findall(r"(?m)^w_metadata (\S+) ", winetricks_text()))


def winetricks_overrides(verbs: list[str]) -> set[str]:
    """The DLLs these verbs override themselves (w_override_dlls in their load_ functions and what
    those call), lower case, so a recipe's dump of the same overrides can be left out."""
    funcs = {m.group(1): m.group(2) for m in re.finditer(r"(?ms)^(\w+)\(\)\n\{\n(.*?)^\}", winetricks_text())}
    found: set[str] = set()
    seen: set[str] = set()
    def walk(name: str, depth: int) -> None:
        if name in seen or name not in funcs or depth > 4:
            return
        seen.add(name)
        body = funcs[name]
        for line in re.findall(r"(?m)^\s*w_override_dlls\s+\S+\s+(.*)$", body):
            found.update(w.lower().removesuffix(".dll") for w in line.split() if "$" not in w and not w.startswith("#"))
        for verb in re.findall(r"(?m)\bw_call\s+([\w.=-]+)", body):
            walk(f"load_{verb}", depth + 1)
        for word in set(re.findall(r"\b(helper_\w+)", body)):
            walk(word, depth + 1)
    for v in verbs:
        walk(f"load_{v}", 0)
    return found


def quote(word: str) -> str:
    """A Wrappfile word: quoted when it has a space, a quote, a # or is empty."""
    if word and not re.search(r'[\s"#]', word):
        return word
    return '"' + word.replace('"', '""') + '"'


def windows_path(path: str, program_files: str = "C:/Program Files (x86)") -> str:
    """A CrossOver or Porting Kit path as a wine: path (C:/…), its %Variables% filled in."""
    p = path.replace("\\", "/")
    for var, value in {"%ProgramFiles%": program_files, "%ProgramFiles(x86)%": "C:/Program Files (x86)",
                       "%WinDir%": "C:/windows", "%WinSysDir%": "C:/windows/syswow64",
                       "%UserProfile%": "C:/users/crossover", "%Desktop%": "C:/users/crossover/Desktop",
                       "%MyDocuments%": "C:/users/crossover/Documents"}.items():
        p = re.sub(re.escape(var), value, p, flags=re.I)
    if re.match(r"^[a-z]:", p):
        p = p[0].upper() + p[1:]
    return re.sub(r"/+", "/", p)


class Draft:
    """Candidate Wrappfile lines, each with where it came from, and what couldn't be mapped."""

    def __init__(self, title: str, source: str) -> None:
        self.map = load_map()
        self.verbs = winetricks_verbs()
        self.title, self.source = title, source
        self.notes: list[str] = []                       # header comments
        self.before: list[tuple[str, str]] = []          # prefix set-up, before the install
        self.install: tuple[str, str] | None = None
        self.after: list[tuple[str, str]] = []           # after the install
        self.launch_options: list[tuple[str, str]] = []
        self.program: tuple[str, str] | None = None
        self.program_args: list[str] = []
        self.input: str | None = None                    # disc-1 or installer
        self.uses: set[str] = set()
        self.unmapped: list[tuple[str, str]] = []
        self.unmapped_values: dict[tuple[str, str], list[str]] = {}   # (origin, why) -> registry values
        self.overrides: list[tuple[str, str, str, bool]] = []          # (dll, value, origin, after)
        self._seen: set[str] = set()

    # -- adding

    def line(self, text: str, origin: str, *, after: bool = False) -> None:
        if text in self._seen:
            return
        self._seen.add(text)
        (self.after if after else self.before).append((text, origin))

    def verb(self, verb: str, origin: str, *, after: bool = False, note: str = "") -> None:
        alias = self.map["pk-winetricks"].get(verb)
        if alias is not None and alias.get("verbs") and verb not in alias["verbs"]:
            note = "; ".join(n for n in (note, alias.get("note", "")) if n)
            for v in alias["verbs"]:
                self.verb(v, origin, after=after, note=note)
            return
        if verb not in self.verbs and not OVERRIDE_VERB.match(verb):
            self.unmapped.append((origin, f"winetricks verb {verb!r}: our winetricks has no such verb"))
            return
        self.line(f"WINE.WINETRICKS {verb}", origin + (f" ({note})" if note else ""), after=after)

    def apply(self, mapping: dict, origin: str, *, after: bool = False) -> None:
        """A draft-map.json entry: its verbs, lines and launch options, or, with none, an unmapped thing."""
        note = mapping.get("note", "")
        did = False
        if mapping.get("noop"):
            self.notes.append(f"{origin}: {note or 'nothing to set'}")
            return
        for v in mapping.get("verbs", []):
            self.verb(v, origin, after=after, note=note)
            did = True
        for l in mapping.get("lines", []):
            self.line(l, origin + (f" ({note})" if note else ""), after=after)
            did = True
        for o in mapping.get("launch", []):
            self.launch_options.append((o, origin))
            did = True
        self.uses |= set(mapping.get("uses", []))
        if not did:
            self.unmapped.append((origin, note or "nothing of ours does this"))

    def windows_version(self, name: str, origin: str) -> None:
        mapping = self.map["windows-versions"].get(name)
        if mapping is None:
            self.unmapped.append((origin, f"Windows version {name!r} isn't in draft-map.json"))
        elif not mapping.get("verbs"):
            self.notes.append(f"{origin}: {mapping.get('note', 'nothing to set')}")
        else:
            self.apply(mapping, origin)

    def registry(self, key: str, name: str | None, data: str, origin: str, *, after: bool = False) -> None:
        key = re.sub(r"^HKCU\\", r"HKEY_CURRENT_USER\\", key, flags=re.I)
        key = re.sub(r"^HKLM\\", r"HKEY_LOCAL_MACHINE\\", key, flags=re.I)
        what = f"{key}\\{name or '(default)'}"
        for prefix, why in self.map["registry-unmapped"].items():
            if not prefix.startswith("_") and key.lower().startswith(prefix.lower()):
                self.unmapped_values.setdefault((origin, f"{prefix}: {why}"), []).append(what[len(prefix):].lstrip("\\"))
                return
        for k, values in self.map["registry-values"].items():
            if k.lower() == key.lower() and name and name.lower() in values:
                by_data = values[name.lower()]
                hit = by_data.get(data.lower(), by_data.get("*"))
                if hit is not None:
                    self.apply(hit, f"{origin}: {what}", after=after)
                    return
        if not name:
            self.unmapped.append((origin, f"{what}: WINE.REGISTRY sets a named value, not a key's default"))
            return
        if re.match(r"^(dword|hex(\(\w+\))?):", data, re.I):
            self.unmapped.append((origin, f"{what} = {data.split(':')[0]}: WINE.REGISTRY sets text values (REG_SZ) only"))
            return
        if not data and not key.lower().endswith("\\dlloverrides"):
            self.unmapped.append((origin, f"{what} set empty: a Wrappfile word can't be empty"))
            return
        if not key.upper().startswith("HKEY_"):
            self.unmapped.append((origin, f"{what}: not a key in full"))
            return
        if key.lower() == "hkey_current_user\\software\\wine\\dlloverrides":
            data = data.replace(" ", "") or "disabled"   # an empty override is Wine's "disabled"
            # Held back to the end, to leave out what the draft's own winetricks verbs set
            self.overrides.append((name, data, origin, after))
            return
        short = next((v for k, v in self.map["registry-keys"].items() if k.lower() == key.lower()), None)
        target = f"{short or key}:{name}"
        self.line(f"WINE.REGISTRY --set {quote(target)} {quote(data)}", origin, after=after)

    def set_program(self, path: str, origin: str, args: str = "") -> None:
        if self.program is None:
            self.program = (path, origin)
            self.program_args = args.split()
        elif self.program[0].lower() != path.lower():
            self.notes.append(f"{origin}: another program, {path}")

    # -- printing

    def place_overrides(self) -> None:
        """The recipe's DLL overrides, less those a WINE.WINETRICKS verb of the draft sets itself."""
        verbs = [t.split()[1] for t, _ in self.before + self.after if t.startswith("WINE.WINETRICKS ")]
        if any(t == "DO wine.cnc-ddraw" for t, _ in self.before + self.after):
            verbs.append("cnc_ddraw")
        covered = winetricks_overrides(verbs)
        left_out: dict[str, list[str]] = {}
        for dll, data, origin, after in self.overrides:
            if dll.lower().lstrip("*").removesuffix(".dll") in covered:
                left_out.setdefault(origin, []).append(dll)
                continue
            target = f"HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides:{dll}"
            self.line(f"WINE.REGISTRY --set {quote(target)} {quote(data)}", origin, after=after)
        for origin, dlls in left_out.items():
            self.notes.append(f"{origin}: {len(dlls)} DLL overrides left out, as the draft's winetricks verbs set them")
        self.overrides = []

    def render(self) -> str:
        self.place_overrides()
        out = [f"# A draft from {self.source}, for {self.title}.",
               "# Suggestions to try one at a time (port-program step 6), never a Wrappfile to",
               "# commit as it is: keep only what the program turns out to need."]
        out += [f"# {n}" for n in dict.fromkeys(self.notes)]
        out.append("")
        program = self.program[0] if self.program else None
        if program and "/" in program:
            install_dir, exe = program.rsplit("/", 1)
        else:
            install_dir, exe = "C:/Program Files (x86)/TODO", "TODO.exe"
        if not self.install and self.input is None:
            self.input = "game"
            self.install = ("COPY --from=${input.game} . ${const.install-dir}/",
                            "nothing said how it installs: a program copied in as it comes")
        if self.input:
            out.append(f"INPUT {self.input}")
        out.append(f"CONST install-dir = {quote(install_dir)}")
        out.append(f'CONST program = "${{const.install-dir}}/{exe}"'
                   + (f"  # {self.program[1]}" if self.program else "  # TODO: nothing said which program it starts"))
        out += ["", "FROM --module=wine@10 prefix AS draft"]
        uses = sorted(self.uses | ({"installer"} if self.install and self.install[0].startswith("INSTALLER.") else set()))
        out += [f"USE {u}" for u in uses]
        body = list(self.before)
        body.append(self.install)
        body += self.after
        launch = [o for o, _ in self.launch_options]
        if not any(o.startswith("--wine.graphics=") for o in launch):
            launch.append("--wine.graphics=unknown")
            graphics = "TODO: what it draws with, direct-draw, direct-3d or unknown (identify.py says)"
        else:
            graphics = ""
        launch_line = "LAUNCH " + " ".join(launch + ["${const.program}"] + [quote(a) for a in self.program_args])
        launch_origin = "; ".join(dict.fromkeys([o for _, o in self.launch_options] + ([graphics] if graphics else [])))
        body.append((launch_line, launch_origin))
        width = min(max((len(t) for t, _ in body), default=0), 60)
        for text, origin in body:
            out.append(f"{text:<{width}}  # {origin}" if origin else text)
        if self.unmapped or self.unmapped_values:
            out += ["", "# Couldn't map:"]
            out += [f"#   {origin}: {why}" for origin, why in self.unmapped]
            for (origin, why), values in self.unmapped_values.items():
                shown = ", ".join(values[:4]) + (f" and {len(values) - 4} more" if len(values) > 4 else "")
                out.append(f"#   {origin}: {why} ({shown})")
        return "\n".join(out)


# -- CrossOver

def useif_text(el: ET.Element) -> str:
    """A CrossTie <useif>'s condition, as text."""
    def walk(e: ET.Element) -> str:
        kids = [walk(c) for c in e]
        if e.tag in ("useif", "and"):
            return " and ".join(kids)
        if e.tag == "or":
            return "(" + " or ".join(kids) + ")"
        if e.tag == "not":
            return "not " + " ".join(kids)
        op = {"equal": "=", "match": "~", "lt": "<", "ge": ">="}.get(e.tag, e.tag)
        return f"{e.get('name')} {op} {(e.text or '').strip()}"
    return walk(el)


def draft_crossover(appid: str) -> Draft:
    if not appid.startswith("com."):
        appid = f"com.codeweavers.c4.{appid}"
    path = CACHE / "crossover/apps" / f"{appid}.xml"
    if not path.exists():
        sys.exit(f"no CrossTie {appid} (run refs.py sync?)")
    index = {a["id"]: a for a in json.loads((CACHE / "crossover/index.json").read_text())}
    app = ET.fromstring(path.read_text())
    short = appid.rsplit(".", 1)[-1]
    d = Draft(text_of(app, "name") or appid, f"CrossOver's CrossTie {short}")
    if index.get(appid, {}).get("medals"):
        d.notes.append(f"CrossOver medals: {index[appid]['medals']}")
    flags = [f.text for f in app.iter("flag")]
    if "application" not in flags:
        d.notes.append(f"CrossOver flags it {', '.join(f for f in flags if f)}, not an application")

    profile = app.find("appprofile")
    bottles = [b.text for b in (profile.iter("bottletemplate") if profile is not None else []) if b.text]
    if bottles:
        d.windows_version(bottles[0], f'CrossOver: bottle template "{bottles[0]}"')
        if len(bottles) > 1:
            d.notes.append(f"CrossOver: it also allows bottles {', '.join(bottles[1:])}")

    def component(dep: str, origin_prefix: str, *, after: bool, depth: int = 0) -> None:
        num = dep.rsplit(".", 1)[-1]
        name = index.get(dep, {}).get("name", "?")
        origin = f'{origin_prefix}component "{name}" ({num})'
        mapping = d.map["crossover-components"].get(num)
        sub = CACHE / "crossover/apps" / f"{dep}.xml"
        deps = []
        if sub.exists():
            deps = [e.text.strip() for e in ET.fromstring(sub.read_text()).iter("predependency") if e.text]
        if (mapping is None or mapping.get("expand")) and deps and depth < 3:
            for sd in deps:
                component(sd, f'{origin_prefix}via "{name}": ', after=after, depth=depth + 1)
            return
        if mapping is None:
            d.unmapped.append((origin, "not in draft-map.json's crossover-components"))
        else:
            d.apply(mapping, origin, after=after)

    has_disc = app.find("cdprofile") is not None
    for prof in app.findall("installprofile"):
        cond = prof.find("useif")
        when = f" [only when {useif_text(cond)}]" if cond is not None else ""
        o = "CrossOver" + when + ": "
        for e in prof.findall("predependency"):
            if e.text:
                component(e.text.strip(), o, after=False)
        for kind, after in (("preinstallregistry", False), ("postinstallregistry", True)):
            for reg in prof.findall(kind):
                key = (reg.findtext("key") or "").strip()
                for v in reg.findall("value"):
                    d.registry(key, (v.findtext("name") or "").strip() or None, (v.findtext("data") or "").strip(),
                               f"{o}{kind}", after=after)
        for e in prof.findall("installerdlloverrides"):
            for part in re.split(r"[;]", e.text or ""):
                dlls, _, mode = part.partition("=")
                value = {"n": "native", "b": "builtin", "n,b": "native,builtin", "b,n": "builtin,native", "": ""}.get(mode, mode)
                for dll in filter(None, dlls.split(",")):
                    key = "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides"
                    d.line(f"WINE.REGISTRY --set {quote(key + ':' + dll)} {quote(value)}", f"{o}DLL override while installing")
                    d.line(f"WINE.REGISTRY --remove {quote(key + ':' + dll)}", f"{o}DLL override while installing, taken off", after=True)
        for e in prof.findall("installerwinver"):
            d.notes.append(f"{o}installs under Windows version {e.text}: try it if the installer fails")
        for e in prof.findall("lnkfile"):
            # A shortcut's target, which can carry arguments after the program
            m = re.match(r"^\s*(.+?\.exe)(?:\s+(.*))?$", e.findtext("target") or "", re.I)
            if not m:
                continue
            exe = windows_path(m.group(1))
            if exe.lower().startswith("c:/windows/") or re.search(r"unins|setup|readme|config", exe, re.I):
                continue
            d.set_program(exe, f"{o}shortcut target", m.group(2) or "")
        for e in prof.findall("postdependency"):
            if e.text:
                component(e.text.strip(), o, after=True)
        for tag, why in (("installnotes", f"has install notes: read them with refs.py show crossover:{short}"),
                         ("installerenvironment", "an environment variable for the installer: INSTALLER.RUN takes none"),
                         ("preinstallenvironment", "an environment variable: INSTALLER.RUN takes none, LAUNCH --env might"),
                         ("installeroption", "options for the installer: an answer file (--answer-file) is ours"),
                         ("installersilentoption", "the installer's silent option: an answer file (--answer-file) is ours"),
                         ("filestocopy", "files copied from the install source: a COPY --from=${input.…} may do it"),
                         ("prermfakedll", "a Wine stub DLL removed before installing"),
                         ("postregisterdll", "a DLL registered after installing: RUN regsvr32 may do it"),
                         ("postinstallurl", "a web page opened after installing"),
                         ("zipencoding", "the zip's file-name encoding")):
            items = prof.findall(tag)
            if items:
                named = ", ".join(sorted({(i.findtext("name") or i.findtext("glob") or i.text or "").strip()
                                          for i in items} - {""}))
                show = "" if tag == "installnotes" else (f" ({named})" if named and len(named) < 80 else "")
                d.unmapped.append((f"{o}{tag}", why + show))
    if has_disc:
        globs = [g.text for g in app.iter("glob") if g.text]
        d.input = "disc-1"
        d.install = ("INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} --creates=${const.program}",
                     "CrossOver: installs from a disc" + (f" (it knows it by {', '.join(globs[:3])})" if globs else ""))
    elif profile is not None and (profile.find("downloadglob") is not None or profile.find("downloadurl") is not None
                                  or profile.find("steamid") is not None):
        d.input = "installer"
        d.install = ("INSTALLER.RUN --from=${input.installer} --into=${const.install-dir} --creates=${const.program}",
                     "CrossOver: installs from a download")
        if profile.find("steamid") is not None:
            d.notes.append(f"CrossOver: on Steam as app {profile.findtext('steamid')}: the steam module may be the way (docs/steam.md)")
    else:
        d.input = "installer"
        d.install = ("INSTALLER.RUN --from=${input.installer} --into=${const.install-dir} --creates=${const.program}",
                     "CrossOver: says nothing of the source; an installer assumed")
    return d


# -- Porting Kit

def pk_recipe(ident: str) -> Path:
    """A .wsi3 by Porting Kit id (one on this Mac) or by its path."""
    if ident.endswith(".wsi3") or "/" in ident:
        p = Path(ident).expanduser()
        if not p.exists():
            sys.exit(f"no such .wsi3: {p}")
        return p
    local = CACHE / "pk/local-wsi3.json"
    for p in json.loads(local.read_text()) if local.exists() else []:
        try:
            if str(json.loads(Path(p).read_text()).get("id")) == ident:
                return Path(p)
        except (OSError, ValueError):
            pass
    sys.exit(f"no .wsi3 for Porting Kit port {ident} on this Mac: Porting Kit doesn't serve recipes openly; "
             "save one from Porting Kit (or find a port's pk_backup.wsi3), refs.py sync, or pass its path")


def draft_pk(ident: str) -> Draft:
    path = pk_recipe(ident)
    w = json.loads(path.read_text())
    d = Draft(str(w.get("name")), f"Porting Kit's recipe {path.name} (port {w.get('id')})")
    installed = False
    for n, step in enumerate(w.get("steps", []), 1):
        kind, props = step.get("type"), step.get("properties")
        cond = step.get("conditions")
        o = f"Porting Kit: step {n} {kind}" + (f" [only if {json.dumps(cond)}]" if cond else "")
        if kind == "setEngine":
            eng = (props or {}).get("engine", {})
            d.notes.append(f"Porting Kit ran it on {eng.get('type', '?')} Wine {eng.get('version', '?')} "
                           f"({eng.get('bits', '?')}-bit engine); this draft uses wine@10, Second Chance's")
        elif kind == "installWinetrick":
            verb = (props or {}).get("name", "")
            if verb in d.map["windows-versions"]:
                d.windows_version(verb, f'{o} "{verb}"')
            elif verb in d.map["pk-winetricks"] and not d.map["pk-winetricks"][verb].get("verbs"):
                d.apply(d.map["pk-winetricks"][verb], f'{o} "{verb}"', after=installed)
            else:
                d.verb(verb, f'{o} "{verb}"', after=installed)
        elif kind == "installDependency":
            dep = str((props or {}).get("id"))
            d.apply(d.map["pk-dependencies"].get(dep, {"note": f"dependency {dep!r} isn't in draft-map.json"}), f'{o} "{dep}"')
        elif kind == "setRegistryEntry":
            hive = {"user": "HKEY_CURRENT_USER", "system": "HKEY_LOCAL_MACHINE"}.get((props or {}).get("registry"), "")
            header = (props or {}).get("header", "").strip("[]").replace("\\\\", "\\")
            key = header if header.upper().startswith("HKEY_") else f"{hive}\\{header}"
            entries = (props or {}).get("entries", [])
            for e in entries:
                value = str(e.get("value", ""))
                data = value[1:-1] if len(value) >= 2 and value[0] == value[-1] == '"' else value
                d.registry(key, e.get("key") or None, data, o, after=installed)
        elif kind == "setRenderer":
            r = props if isinstance(props, str) else str(props)
            d.apply(d.map["pk-renderers"].get(r, {"note": f"renderer {r!r} isn't in draft-map.json"}), f'{o} "{r}"', after=installed)
        elif kind == "setProperties":
            for k, v in (props or {}).items():
                m = d.map["pk-properties"].get(k, {}).get(json.dumps(v))
                if m is None:
                    d.unmapped.append((f"{o} {k}", f"{json.dumps(v)} isn't in draft-map.json's pk-properties"))
                elif m.get("verbs") or m.get("lines"):
                    d.apply(m, f"{o} {k}={json.dumps(v)}", after=installed)
        elif kind == "setDrivers":
            if any(x != "mac" for x in props or []):
                d.notes.append(f"{o}: {', '.join(dict.fromkeys(props))}; Second Chance's Wine uses only the Mac driver")
        elif kind == "setVideoCardInfo":
            if (props or {}).get("auto") is not True:
                d.unmapped.append((o, "a video card's details: no Wrappfile setting"))
        elif kind == "run":
            p = props or {}
            installed = True
            d.input = "installer"
            d.install = ("INSTALLER.RUN --from=${input.installer} --into=${const.install-dir} --creates=${const.program}",
                         f"{o}: runs an installer" + (f" ({p.get('filename')})" if p.get("filename") else "")
                         + (" with flags" if p.get("flags") else ""))
            if p.get("neededFileOnClose"):
                d.set_program(windows_path(p["neededFileOnClose"]), f"{o}: the file it waits for")
            if p.get("flags"):
                d.unmapped.append((o, f"the installer's flags ({p['flags']}): INSTALLER.RUN takes an answer file instead"))
        elif kind == "setMainApplication":
            p = props or {}
            if p.get("compatibility"):
                d.windows_version(p["compatibility"], f'{o}: compatibility "{p["compatibility"]}"')
            if p.get("path"):
                path_ = windows_path(p["path"])
                if re.search(r"/steam/steam\.exe$", path_, re.I):
                    d.unmapped.append((o, "starts Steam: a Steam game is FROM --module=steam@1 client and DO steam.install (docs/steam.md)"))
                elif re.search(r"bfgclient\.exe$", path_, re.I):
                    d.unmapped.append((o, "starts Big Fish's client: the big-fish module (docs/big-fish.md)"))
                else:
                    d.set_program(path_, f"{o}: its program", p.get("flags", ""))
            elif p.get("pathType") == "manual":
                d.notes.append(f"{o}: the person picks the program after installing")
        else:
            d.unmapped.append((o, f"step type {kind!r} isn't known to refs.py draft"))
    return d


def draft(ref: str) -> None:
    src, _, ident = ref.partition(":")
    if src == "crossover":
        print(draft_crossover(ident).render())
    elif src == "pk":
        print(draft_pk(ident).render())
    elif ref.endswith(".wsi3"):
        print(draft_pk(ref).render())
    else:
        sys.exit("refs.py draft crossover:<id> | pk:<id> | pk:<file.wsi3>")


def check_map() -> None:
    """draft-map.json against our winetricks and CrossOver's index: every verb ours, every component's name its."""
    m, verbs = load_map(), winetricks_verbs()
    bad = 0
    def walk(node, where):
        nonlocal bad
        if isinstance(node, dict):
            for v in node.get("verbs", []):
                if v not in verbs and not OVERRIDE_VERB.match(v):
                    print(f"{where}: winetricks has no verb {v}")
                    bad += 1
            for k, sub in node.items():
                if not k.startswith("_"):
                    walk(sub, f"{where}.{k}")
    walk(m, "draft-map")
    cx = CACHE / "crossover/index.json"
    if cx.exists():
        names = {a["id"].rsplit(".", 1)[-1]: a["name"] for a in json.loads(cx.read_text())}
        for num, entry in m["crossover-components"].items():
            if num.startswith("_"):
                continue
            if num not in names:
                print(f"crossover-components.{num}: no such CrossTie ({entry.get('name')})")
                bad += 1
            elif names[num] != entry.get("name"):
                print(f"crossover-components.{num}: CrossOver calls it {names[num]!r}, the map {entry.get('name')!r}")
                bad += 1
    print("draft-map.json: fine" if not bad else f"draft-map.json: {bad} problems")


# ---------------------------------------------------------------- main

def main(argv: list[str]) -> None:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd, rest = argv[0], argv[1:]
    if cmd == "sync":
        CACHE.mkdir(parents=True, exist_ok=True)
        sync_crossover()
        sync_pk()
    elif cmd == "search":
        search(rest)
    elif cmd == "show" and rest:
        src, _, ident = rest[0].partition(":")
        {"crossover": show_crossover, "pk": show_pk}.get(src, lambda _: sys.exit(f"unknown source {src}"))(ident)
    elif cmd == "wsi" and rest:
        print(wsi_summary(rest[0]))
    elif cmd == "draft" and rest == ["--check-map"]:
        check_map()
    elif cmd == "draft" and rest:
        draft(rest[0])
    elif cmd == "lutris" and rest:
        lutris(rest)
    elif cmd == "pcgw" and rest:
        pcgw(rest)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
