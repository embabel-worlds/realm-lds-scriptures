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
# A figure is only this realm's figure when the engine says the answer is whole. A source that failed
# or was capped, a hop cut short, a value a step could not work out: each leaves rows that still look
# like an answer, and counting them reports drift that is not the realm's. short() reads the answer's
# own verdict — `error`, `run`, `reason` and the codes `warnings` open with on a query; `status`,
# `outcome` and the warning codes on a view — and is None when whole, else the line that stands in
# for the figure: "REFUSED: <why>" or "PARTIAL <figure>: <the engine's reason>".
SHORT_CODES = ("PARTIAL_RESULT", "PRODUCER_ERROR", "NEEDS_FILTER", "NEEDS_PRODUCER", "FILTER_REJECTED",
               "UNPUSHED_FILTER", "AMBIGUOUS_LABEL", "INCOMPLETE_TRAVERSAL", "INCOMPLETE_RANKING",
               "INCOMPLETE_AGGREGATE", "INCOMPLETE_INPUT", "MATERIALIZATION_FAILED", "REDUCTION_FAILED",
               "UNPARSEABLE_ANSWER", "TERMS_UNAVAILABLE", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
               "FOLLOW_CAPPED", "UNLINKED_CHILDREN", "RESOLUTION_DROPPED", "AGENTIC_DEGRADED", "SOURCE_UNANSWERED")
SHORT_REASONS = ("UNBOUNDED", "PARTIAL_NOT_MATCHED", "UNPUSHED_FILTER", "DISCONNECTED",
                 "INTERNAL_ERROR", "WRITE_IN_PROGRESS", "KILLED", "TOO_EXPENSIVE")
SHORT_PUBLIC = ("PARTIAL", "REDUCTION_FAILED", "COMPUTE_FAILED", "PROPERTY_NOT_STORED", "AGENTIC_DEGRADED",
                "RATE_LIMITED", "SOURCE_UNAVAILABLE", "SOURCE_REJECTED", "INVALID_FILTER", "UNPUSHED_FILTER",
                "TOO_BROAD", "FETCH_CAPPED", "INDEX_UNAVAILABLE", "ARGUMENT_REFUSED")
def short(d, figure=None):
    tag = "PARTIAL" if figure is None else "PARTIAL %s" % (figure,)
    if not isinstance(d, dict):
        return "REFUSED: not an engine answer: " + str(d)[:160]
    if "outcome" in d or "status" in d:
        if d.get("status") != "SUCCEEDED":
            e = d.get("error") or {}
            e = (e.get("code", "") + " " + e.get("message", "")).strip() if isinstance(e, dict) else str(e)
            return "REFUSED: %s %s" % (d.get("status"), e[:160])
        ws = [w for w in d.get("warnings") or [] if isinstance(w, dict) and w.get("code") in SHORT_PUBLIC]
        if d.get("outcome") not in ("OK", "EMPTY") or ws:
            return "%s: %s" % (tag, (ws[0]["code"] + ": " + ws[0].get("message", "") if ws else "outcome %s" % d.get("outcome"))[:200])
        return None
    if d.get("error"):
        return "REFUSED: " + str(d["error"])[:160]
    if d.get("run"):
        return "%s: the run had not finished (%s)" % (tag, d["run"])
    ws = [w for w in d.get("warnings") or [] if isinstance(w, str) and w.split(":", 1)[0].strip() in SHORT_CODES]
    if ws:
        return "%s: %s" % (tag, ws[0][:200])
    if d.get("reason") in SHORT_REASONS:
        return "%s: reason %s" % (tag, d["reason"])
    return None
def kg(cypher):
    r = post("/api/v1/admin/kg/execute", {"cypher": cypher})
    if r.get("error"):
        raise SystemExit("  FAIL query REFUSED: %s\n    %s" % (str(r["error"])[:200], cypher))
    # A short count stops the battery as a refusal does: every check after it would read the same gap.
    rows = r.get("rows") or []
    s = short(r, rows[0]["n"] if len(rows) == 1 and "n" in rows[0] else "%d rows" % len(rows))
    if s:
        raise SystemExit("  FAIL query %s\n    %s" % (s, cypher))
    return r.get("rows") or []
def view(name, args=None, whole=True):
    r = post("/api/v1/views/%s/invoke" % name, {"args": args or {}})
    # Rows a view marks short are not its answer, so no check counts them. L1 asks with whole=False
    # because it reports each view's verdict itself and goes on to the next.
    s = whole and short(r, len(r.get("data") or []))
    if s:
        raise SystemExit("  FAIL view %s %s: %s" % (name, json.dumps(args or {}), s))
    return r
def check(what, want, got):
    global fail
    if want == got: print("  ok   %s = %s" % (what, got if len(str(got)) < 80 else str(got)[:77] + "..."))
    else: print("  FAIL %s: expected %s, got %s" % (what, str(want)[:300], str(got)[:300])); fail = 1
def records(kind):
    out = []
    for f in sorted(glob.glob(os.path.join(realm, "reference", "*.yml"))):
        out += [r["data"] for r in yaml.safe_load(open(f)) or [] if r.get("type") == kind]
    return out

# The stored reference is written in the background after the realm reports active, so a battery that
# starts at once reads a half-written graph. Wait until every stored verse of this realm, and of
# realm-bible (which it requires), is there: the counts the stored files and the holy book declare.
import time
def wait_seeded(what, query, want):
    deadline = time.time() + 1800
    while True:
        got = kg(query)[0]["n"]
        if got == want: return
        if time.time() > deadline:
            raise SystemExit("  FAIL %s: %d of %d written after 30 minutes" % (what, got, want))
        print("  wait %s: %d of %d written" % (what, got, want)); time.sleep(30)
for label in ['DcVerse', 'PgpVerse']:
    wait_seeded(label, "MATCH (v:%s) RETURN count(v) AS n" % label, len(records(label)))
# realm-bible is required, so it is always installed; its canon node may itself still be on its way.
wait_seeded("the Bible's holy book", "MATCH (h:HolyBook {scripture: 'bible'}) RETURN count(h) AS n", 1)
wait_seeded("BibleVerse", "MATCH (b:BibleVerse) RETURN count(b) AS n",
            kg("MATCH (h:HolyBook {scripture: 'bible'}) RETURN h.verseCount AS n")[0]["n"])
bible = True

print("== L1: every view answers by name ==")
for f in sorted(glob.glob(os.path.join(realm, "views", "*.yml"))):
    for v in yaml.safe_load(open(f)):
        r = view(v["name"], whole=False)
        rows = r.get("data") or []
        if r.get("status") != "SUCCEEDED":
            print("  FAIL %s: %s %s" % (v["name"], r.get("status"), str(r.get("error") or r)[:200])); fail = 1
        elif short(r, len(rows)):
            print("  FAIL %s: %s" % (v["name"], short(r, len(rows)))); fail = 1
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
      [r["book"] for r in kg("MATCH (b:PgpBook) RETURN b.name AS book ORDER BY b.bookOrder")])

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
