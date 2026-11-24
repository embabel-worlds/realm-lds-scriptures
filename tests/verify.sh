#!/bin/sh
# Ground truth for realm-lds-scriptures, against the text it was built from.
#
#   L1  every view answers BY NAME on its defaults; the ones that read stored text are not empty
#   L2  the graph against bcbooks/scriptures-json, fetched fresh: the Doctrine and Covenants' 138
#       sections and the Pearl of Great Price's five books — every chapter's verse count and every
#       verse's text, exactly — the two holy books' counts, and the stored reference/ loaded whole
#   L3  views against the graph and the source: a section, a chapter (em dash and hyphen alike), the
#       two searches
#   L4  with realm-bible installed: chapters are paired with exactly the King James verses their stored
#       `kjvRefs` name (skipped, and said so, when realm-bible is absent)
#
# No producers and no source calls at query time — the text is stored — so there is no pushdown or
# cost check to make. Keyless: the sources are public files.
#
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# The last line on success is exactly `ALL CHECKS PASS`; any failure exits non-zero.
set -e
AUTHCFG=$(mktemp); trap 'rm -f "$AUTHCFG"' EXIT
if [ -n "${TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTHCFG"
else printf 'user = "%s"\n' "${AUTH:?set AUTH (user:pass) or TOKEN}" > "$AUTHCFG"; fi
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
APPLIANCE="$APPLIANCE" AUTHCFG="$AUTHCFG" python3 - "$(dirname "$0")/.." <<'PY'
import glob, json, os, subprocess, sys, urllib.request, yaml
base, auth, realm = os.environ["APPLIANCE"], os.environ["AUTHCFG"], sys.argv[1]
SOURCE = "https://raw.githubusercontent.com/bcbooks/scriptures-json/master/{}.json"
fail = 0

def post(path, body):
    out = subprocess.run(["curl", "-s", "--max-time", "600", "-K", auth, "-X", "POST", base + path,
                          "-H", "Content-Type: application/json", "-d", json.dumps(body)],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out, strict=False)
    except ValueError:
        return {"error": "not JSON: " + out[:200]}
def kg(cypher):
    r = post("/api/v1/admin/kg/execute", {"cypher": cypher})
    if r.get("error"):
        raise SystemExit("  FAIL query REFUSED: %s\n    %s" % (str(r["error"])[:200], cypher))
    return r.get("rows") or []
def view(name, args=None):
    return post("/api/v1/views/%s/invoke" % name, {"args": args or {}})
def check(what, want, got):
    global fail
    if want == got: print("  ok   %s = %s" % (what, got if len(str(got)) < 80 else str(got)[:77] + "..."))
    else: print("  FAIL %s: expected %s, got %s" % (what, str(want)[:300], str(got)[:300])); fail = 1
def records(kind):
    out = []
    for f in sorted(glob.glob(os.path.join(realm, "reference", "*.yml"))):
        out += [r["data"] for r in yaml.safe_load(open(f)) or [] if r.get("type") == kind]
    return out

bible = kg("MATCH (b:BibleVerse) RETURN count(b) AS n")[0]["n"] > 0

print("== L1: every view answers by name ==")
for f in sorted(glob.glob(os.path.join(realm, "views", "*.yml"))):
    for v in yaml.safe_load(open(f)):
        r = view(v["name"])
        rows = r.get("data") or []
        if r.get("status") != "SUCCEEDED":
            print("  FAIL %s: %s %s" % (v["name"], r.get("status"), str(r.get("error") or r)[:200])); fail = 1
        elif not rows and not (v["name"] == "LdsVersesDrawingOn" and not bible):
            print("  FAIL %s answered no rows on its defaults" % v["name"]); fail = 1
        else:
            print("  ok   %-28s %d rows" % (v["name"], len(rows)))

print("== L2: the graph against bcbooks/scriptures-json ==")
dc = json.load(urllib.request.urlopen(SOURCE.format("doctrine-and-covenants"), timeout=120))
pgp = json.load(urllib.request.urlopen(SOURCE.format("pearl-of-great-price"), timeout=120))
chapters = {"DcSection": {s["reference"]: s["verses"] for s in dc["sections"]},
            "PgpChapter": {c["reference"]: c["verses"] for b in pgp["books"] for c in b["chapters"]}}
verse = {"DcSection": "DcVerse", "PgpChapter": "PgpVerse"}
holy = {"DcSection": "DcScripture", "PgpChapter": "PgpScripture"}
for kind, want in chapters.items():
    got = {r["c"]: r["n"] for r in kg("MATCH (c:%s)<-[:IN]-(v:%s) RETURN c.name AS c, count(v) AS n" % (kind, verse[kind]))}
    check("%s: verses in every chapter (%d chapters)" % (kind, len(want)), {k: len(v) for k, v in want.items()}, got)
    check("%s: holy book's counts" % holy[kind], [{"chapters": len(want), "verses": sum(len(v) for v in want.values())}],
          kg("MATCH (h:%s) RETURN h.chapterCount AS chapters, h.verseCount AS verses" % holy[kind]))
    texts = {v["reference"]: v["text"] for vs in want.values() for v in vs}
    got = {r["n"]: r["t"] for r in kg("MATCH (v:%s) RETURN v.name AS n, v.text AS t" % verse[kind])}
    bad = sorted(k for k in texts if texts[k] != got.get(k)) + sorted(set(got) - set(texts))
    check("%s: every verse's text, exactly (%d)" % (verse[kind], len(texts)), [], bad[:5])
    check("%s: the stored reference/ loaded whole" % verse[kind], len(records(verse[kind])), len(got))
check("PgpBook: the five books in order", [b["book"] for b in pgp["books"]],
      [r["b"] for r in kg("MATCH (b:PgpBook) RETURN b.name AS b ORDER BY b.bookOrder")])

print("== L3: views against the graph and the source ==")
check("ReadDcSection 76", len(chapters["DcSection"]["D&C 76"]), len(view("ReadDcSection", {"section": 76}).get("data") or []))
check("ReadDcVerse 'Doctrine and Covenants 121:7'",
      [v["text"] for v in chapters["DcSection"]["D&C 121"] if v["verse"] == 7],
      [r["text"] for r in view("ReadDcVerse", {"ref": "Doctrine and Covenants 121:7"}).get("data") or []])
for spelled in ("Joseph Smith—Matthew 1", "Joseph Smith-Matthew 1"):
    check("ReadPgpChapter %r" % spelled, len(chapters["PgpChapter"]["Joseph Smith—Matthew 1"]),
          len(view("ReadPgpChapter", {"chapter": spelled}).get("data") or []))
for name, kind, term in (("SearchDoctrineAndCovenants", "DcSection", "priesthood"), ("SearchPearlOfGreatPrice", "PgpChapter", "enoch")):
    want = sum(1 for vs in chapters[kind].values() for v in vs if term in v["text"].lower())
    check("%s %r = the source's count" % (name, term), want,
          len(view(name, {"term": term, "limit": 10000}).get("data") or []))

print("== L4: verses paired with the King James ==")
if not bible:
    print("  skip realm-bible is not installed, so CORRESPONDS_TO is empty by design")
else:
    stored = records("DcVerse") + records("PgpVerse")
    for chapter in ("Moses 2", "Joseph Smith—Matthew 1", "D&C 138"):
        want = sorted((v["verse"], k) for v in stored if v["name"].startswith(chapter + ":") for k in v.get("kjvRefs") or [])
        rows = view("LdsBesideKingJames", {"chapter": chapter}).get("data") or []
        got = sorted((x["verse"], x["kingJames"]) for x in rows if x.get("kind") == "quotation")
        check("%s quotes exactly its stored kjvRefs (%d)" % (chapter, len(want)), want, got)

if fail: print("FAILED"); sys.exit(1)
print("ALL CHECKS PASS")
PY
