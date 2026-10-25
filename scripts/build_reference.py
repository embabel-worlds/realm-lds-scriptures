"""
Build the realm's reference data from its published source.

Two holy books, each its own scripture:

  DcScripture ◀─IN─ DcSection ◀─IN─ DcVerse                       the Doctrine and Covenants
  PgpScripture ◀─IN─ PgpBook ◀─IN─ PgpChapter ◀─IN─ PgpVerse      the Pearl of Great Price

The Doctrine and Covenants is a book of sections, not of books, so a section is IN the holy book
directly, as a surah is in the Quran. Both were received in English, so a verse carries one text,
`text`, and `original` is left empty, as the scripture vocabulary says it is for such a scripture.

Source, downloaded into data/source/ on first run:
  bcbooks/scriptures-json (github.com/bcbooks/scriptures-json), `doctrine-and-covenants.json` and
  `pearl-of-great-price.json` — the verse text of the 2013 edition, public domain by the source's
  own statement. It leaves out what is under copyright: the introductions, the section and chapter
  headings, the footnotes, and Official Declaration 2 (1978) — so this realm has no Official
  Declarations, since the source carries neither. Sections 137 (1836) and 138 (1918) are there; both
  were published long enough ago to be in the public domain. Nothing here adds anything back.

THE BIBLE. Both draw on the King James: Moses 2–8 is Genesis 1–6 as Joseph Smith revised it,
Abraham 1–2 and 4–5 retell Genesis 11–12 and 1–2, Joseph Smith—Matthew is Matthew 23:39–24:51
revised, and the Doctrine and Covenants quotes and echoes the New Testament throughout. Each verse
records in `kjvRefs` a King James verse it quotes and in `kjvAllusions` one it echoes, and
rules/corresponds.yml draws CORRESPONDS_TO from both. Which verse is paired with which is FOUND, not
written: a verse is paired with the King James verse it reads most alike, by shared words weighted
by rarity, as realm-book-of-mormon does.

Where a chapter's parallel is known (PARALLEL, below) only those chapters are searched, and the
Book of Mormon's thresholds apply: quotation at 0.4, allusion at 0.26. Everything else is searched
against the whole King James, and the best of 31,102 verses scores higher by chance than the best
of one chapter's thirty, so the bar is higher there: quotation at 0.6, allusion at 0.3 — measured
on this text, and printed near the lines by the build so a change of source can be judged.

The King James text is read from realm-bible's reference data, which must sit beside this realm.

Run from the realm root:  python scripts/build_reference.py
"""

import json
import math
import re
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "data" / "source"
REFERENCE = ROOT / "reference"
BIBLE = ROOT.parent / "realm-bible" / "reference"
URL = "https://raw.githubusercontent.com/bcbooks/scriptures-json/master/{}.json"

DC_VERSES, DC_SECTIONS = 3654, 138
PGP_VERSES, PGP_CHAPTERS = 635, 16

# Chapters whose King James parallel is known: searched only there.
PARALLEL = {
    **{f"Moses {n}": [f"Genesis {c}" for c in range(1, 7)] for n in range(2, 9)},
    "Abraham 1": ["Genesis 11", "Genesis 12"],
    "Abraham 2": ["Genesis 11", "Genesis 12"],
    "Abraham 4": ["Genesis 1", "Genesis 2"],
    "Abraham 5": ["Genesis 1", "Genesis 2"],
    "Joseph Smith—Matthew 1": ["Matthew 23", "Matthew 24", "Mark 13", "Luke 21"],
}
POOLED = (0.4, 0.26)
WHOLE = (0.6, 0.3)
# A word in more verses than this cannot nominate a candidate on its own; it still counts in the score.
COMMON = 300


def fetch(name: str) -> dict:
    SOURCE.mkdir(parents=True, exist_ok=True)
    path = SOURCE / f"{name}.json"
    if not path.exists():
        print(f"downloading {name}.json")
        request = urllib.request.Request(URL.format(name), headers={"User-Agent": "realm-lds-scriptures build_reference"})
        with urllib.request.urlopen(request) as response:
            path.write_bytes(response.read())
    return json.loads(path.read_text(encoding="utf-8"))


def words(text: str) -> set[str]:
    return set(re.findall(r"[a-z]+", text.lower().replace("-", "")))


class KingJames:
    """realm-bible's King James verses, with the rarity of every word and an index of the rare ones."""

    def __init__(self) -> None:
        files = sorted(BIBLE.glob("bible-03-verses-*.yml"))
        if len(files) != 66:
            sys.exit(f"{BIBLE}: expected 66 verse files, found {len(files)} — realm-bible's reference data must sit beside this realm")
        self.verses: list[tuple[str, str, set[str]]] = []
        for path in files:
            for record in yaml.load(path.read_text(encoding="utf-8"), Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)):
                d = record["data"]
                self.verses.append((d["name"], d["osis"], words(d["text"])))
        count: dict[str, int] = defaultdict(int)
        for _, _, ws in self.verses:
            for w in ws:
                count[w] += 1
        self.rarity = {w: math.log(len(self.verses) / c) for w, c in count.items()}
        self.osis = {name: osis for name, osis, _ in self.verses}
        self.by_chapter: dict[str, list[int]] = defaultdict(list)
        self.index: dict[str, list[int]] = defaultdict(list)
        for i, (name, _, ws) in enumerate(self.verses):
            self.by_chapter[name.rsplit(":", 1)[0]].append(i)
            for w in ws:
                if count[w] <= COMMON:
                    self.index[w].append(i)
        missing = {c for cs in PARALLEL.values() for c in cs} - set(self.by_chapter)
        if missing:
            sys.exit(f"King James chapters not found: {sorted(missing)}")

    def likeness(self, a: set[str], b: set[str]) -> float:
        weight = lambda ws: sum(self.rarity.get(w, 1.0) for w in ws)
        return weight(a & b) / max(1e-9, weight(a | b))

    def best(self, text: str, chapters: list[str] | None) -> tuple[float, str | None]:
        ws = words(text)
        if chapters:
            pool = [i for c in chapters for i in self.by_chapter[c]]
        else:
            shared: dict[int, int] = defaultdict(int)
            for w in ws:
                for i in self.index.get(w, ()):
                    shared[i] += 1
            pool = [i for i, n in shared.items() if n >= 2]
        if not pool:
            return 0.0, None
        score, i = max((self.likeness(ws, self.verses[i][2]), i) for i in pool)
        return score, self.verses[i][0]


class Pairing:
    """Pairs each verse with the King James verse it reads most alike, and counts what it kept."""

    def __init__(self, kjv: KingJames) -> None:
        self.kjv = kjv
        self.counts = defaultdict(int)
        self.near: list[str] = []

    def pair(self, data: dict, chapter: str, text: str) -> str | None:
        chapters = PARALLEL.get(chapter)
        quotes, alludes = POOLED if chapters else WHOLE
        score, ref = self.kjv.best(text, chapters)
        if ref is None:
            return None
        if any(abs(score - line) < 0.03 for line in (quotes, alludes)):
            self.near.append(f"{score:.2f} {data['name']} ↔ {ref}")
        if score >= quotes:
            data["kjvRefs"], data["kjvOsis"] = [ref], [self.kjv.osis[ref]]
            self.counts[(data["scripture"], "quotation")] += 1
        elif score >= alludes:
            data["kjvAllusions"], data["kjvAllusionOsis"] = [ref], [self.kjv.osis[ref]]
            self.counts[(data["scripture"], "allusion")] += 1
        else:
            return None
        return ref.rsplit(":", 1)[0]


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def header(lines: str) -> str:
    return "\n".join(f"# {line}" if line else "#" for line in lines.strip().splitlines()) + "\n\n"


def write(name: str, comment: str, records: list[dict]) -> None:
    body = yaml.dump(records, allow_unicode=True, sort_keys=False, width=100_000)
    (REFERENCE / name).write_text(header(comment) + body, encoding="utf-8")


def drawn_on(found: list[str | None]) -> list[str]:
    """The King James chapters a chapter's verses pair with, in order of first appearance."""
    out: list[str] = []
    for c in found:
        if c and c not in out:
            out.append(c)
    return out


def doctrine_and_covenants(pairing: Pairing) -> None:
    source = fetch("doctrine-and-covenants")
    sections, verses = [], []
    ordinal = 0
    for section in source["sections"]:
        n, name = section["section"], section["reference"]
        found = []
        for verse in section["verses"]:
            ordinal += 1
            data = {"ref": f"dc.{n}.{verse['verse']}", "scripture": "doctrine-and-covenants",
                    "name": verse["reference"], "chapter": n, "verse": verse["verse"], "ordinal": ordinal,
                    "text": verse["text"], "translation": "2013 edition", "original": ""}
            found.append(pairing.pair(data, name, verse["text"]))
            verses.append({"type": "DcVerse", "data": data,
                           "relations": [{"predicate": "IN", "to": {"type": "DcSection", "ref": f"dc.{n}"}}]})
        data = {"ref": f"dc.{n}", "scripture": "doctrine-and-covenants", "name": name, "chapter": n,
                "verseCount": len(section["verses"]), "documentUri": f"dc://text/{n}"}
        if drawn_on(found):
            data["drawsOn"] = drawn_on(found)
        sections.append({"type": "DcSection", "data": data,
                         "relations": [{"predicate": "IN", "to": {"type": "DcScripture", "scripture": "doctrine-and-covenants"}}]})
    if ordinal != DC_VERSES or len(sections) != DC_SECTIONS:
        sys.exit(f"Doctrine and Covenants: {ordinal} verses in {len(sections)} sections, not {DC_VERSES} in {DC_SECTIONS}: refusing to build")

    write("dc-01-scripture.yml", """
The Doctrine and Covenants as one holy book. Generated by scripts/build_reference.py — do not edit by hand.
""", [{"type": "DcScripture", "data": {
        "scripture": "doctrine-and-covenants", "name": "The Doctrine and Covenants", "tradition": "Latter-day Saint",
        "originalLanguage": "English", "translation": "2013 edition", "chapterCount": DC_SECTIONS, "verseCount": DC_VERSES,
        "textSource": "bcbooks/scriptures-json (public domain): the verse text of the 2013 edition; no introduction, section headings, footnotes or Official Declarations",
    }}])
    write("dc-02-sections.yml", """
Every section, with the King James chapters its verses quote or echo (`drawsOn`). Generated by
scripts/build_reference.py — do not edit by hand.
""", sections)
    for part, start in enumerate(range(0, len(verses), 1000), start=1):
        write(f"dc-03-verses-{part}.yml", """
Verses of the Doctrine and Covenants, public domain, from bcbooks/scriptures-json. `kjvRefs` names a
King James verse a verse quotes, `kjvAllusions` one it echoes. Generated by scripts/build_reference.py
— do not edit by hand.
""", verses[start:start + 1000])


def pearl_of_great_price(pairing: Pairing) -> None:
    source = fetch("pearl-of-great-price")
    books, chapters, verse_files = [], [], []
    ordinal = 0
    for order, book in enumerate(source["books"], start=1):
        name, key = book["book"], slug(book["book"])
        verses = []
        for chapter in book["chapters"]:
            n, chapter_name = chapter["chapter"], chapter["reference"]
            found = []
            for verse in chapter["verses"]:
                ordinal += 1
                data = {"ref": f"{key}.{n}.{verse['verse']}", "scripture": "pearl-of-great-price",
                        "name": verse["reference"], "book": name, "chapter": n, "verse": verse["verse"],
                        "ordinal": ordinal, "text": verse["text"], "translation": "2013 edition", "original": ""}
                found.append(pairing.pair(data, chapter_name, verse["text"]))
                verses.append({"type": "PgpVerse", "data": data,
                               "relations": [{"predicate": "IN", "to": {"type": "PgpChapter", "ref": f"{key}.{n}"}}]})
            data = {"ref": f"{key}.{n}", "scripture": "pearl-of-great-price", "name": chapter_name, "book": name,
                    "chapter": n, "verseCount": len(chapter["verses"]), "documentUri": f"pgp://text/{key}.{n}"}
            if chapter_name in PARALLEL:
                data["parallelsChapters"] = PARALLEL[chapter_name]
            if drawn_on(found):
                data["drawsOn"] = drawn_on(found)
            chapters.append({"type": "PgpChapter", "data": data,
                             "relations": [{"predicate": "IN", "to": {"type": "PgpBook", "slug": key}}]})
        data = {"slug": key, "scripture": "pearl-of-great-price", "name": name, "bookOrder": order,
                "fullTitle": book["full_title"], "chapterCount": len(book["chapters"]), "verseCount": len(verses)}
        if book.get("full_subtitle"):
            data["subtitle"] = book["full_subtitle"]
        books.append({"type": "PgpBook", "data": data,
                      "relations": [{"predicate": "IN", "to": {"type": "PgpScripture", "scripture": "pearl-of-great-price"}}]})
        verse_files.append((order, key, name, verses))
    if ordinal != PGP_VERSES or len(chapters) != PGP_CHAPTERS:
        sys.exit(f"Pearl of Great Price: {ordinal} verses in {len(chapters)} chapters, not {PGP_VERSES} in {PGP_CHAPTERS}: refusing to build")

    write("pgp-01-scripture.yml", """
The Pearl of Great Price as one holy book. Generated by scripts/build_reference.py — do not edit by hand.
""", [{"type": "PgpScripture", "data": {
        "scripture": "pearl-of-great-price", "name": "The Pearl of Great Price", "tradition": "Latter-day Saint",
        "originalLanguage": "English", "translation": "2013 edition", "chapterCount": PGP_CHAPTERS, "verseCount": PGP_VERSES,
        "textSource": "bcbooks/scriptures-json (public domain): the verse text of the 2013 edition; no introduction, chapter headings or footnotes",
    }}])
    write("pgp-02-books.yml", """
The five books: Moses, Abraham, Joseph Smith—Matthew, Joseph Smith—History, the Articles of Faith.
Generated by scripts/build_reference.py — do not edit by hand.
""", books)
    write("pgp-03-chapters.yml", """
Every chapter, with the King James chapters it parallels (`parallelsChapters`) where its parallel is
known, and those its verses quote or echo (`drawsOn`). Generated by scripts/build_reference.py — do
not edit by hand.
""", chapters)
    for order, key, name, verses in verse_files:
        write(f"pgp-04-verses-{order:02d}-{key}.yml", f"""
Every verse of {name}, public domain, from bcbooks/scriptures-json. `kjvRefs` names a King James verse
a verse quotes, `kjvAllusions` one it echoes. Generated by scripts/build_reference.py — do not edit by hand.
""", verses)


def main() -> None:
    kjv = KingJames()
    REFERENCE.mkdir(exist_ok=True)
    for old in list(REFERENCE.glob("dc-*.yml")) + list(REFERENCE.glob("pgp-*.yml")):
        old.unlink()
    pairing = Pairing(kjv)
    doctrine_and_covenants(pairing)
    pearl_of_great_price(pairing)
    for (scripture, kind), n in sorted(pairing.counts.items()):
        print(f"{scripture}: {n} verses, {kind}")
    print("pairs nearest a line:\n  " + "\n  ".join(sorted(pairing.near)))


if __name__ == "__main__":
    main()
