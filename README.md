# realm-lds-scriptures

> **Experimental.** Its types are children of
> [realm-scripture-vocabulary](https://github.com/embabel-worlds/realm-scripture-vocabulary), which must be installed first — a
> child whose parent's realm is missing is refused at load. It also needs a host that writes a child
> type's inherited properties (Embabel hosts from October 2026): a `DcVerse` declares little of its own.

The Doctrine and Covenants and the Pearl of Great Price as a queryable graph — the two books of
Latter-day Saint scripture printed beside the Book of Mormon. Read a verse, a section or a chapter,
search either, and read Moses beside the Genesis it retells, Joseph Smith—Matthew beside Matthew 24,
and any section beside the New Testament it quotes. Each is its own scripture, so a question asked of
every scripture answers for each; with [realm-book-of-mormon](https://github.com/embabel-worlds/realm-book-of-mormon) installed too,
the three Latter-day Saint scriptures answer side by side.

## Shape

```
DcScripture ◀─IN─ DcSection ◀─IN─ DcVerse ──────────────┐
(HolyBook)        (ScriptureChapter) (Verse)              │
                                                          ├─CORRESPONDS_TO─▶ BibleVerse   (with realm-bible)
PgpScripture ◀─IN─ PgpBook ◀─IN─ PgpChapter ◀─IN─ PgpVerse ┘
(HolyBook)         (ScriptureBook) (ScriptureChapter) (Verse)
```

| | Count |
|---|---|
| DcScripture | 1 (`scripture: doctrine-and-covenants`) |
| DcSection | 138 |
| DcVerse | 3,654 |
| PgpScripture | 1 (`scripture: pearl-of-great-price`) |
| PgpBook | 5 (Moses, Abraham, Joseph Smith—Matthew, Joseph Smith—History, Articles of Faith) |
| PgpChapter | 16 |
| PgpVerse | 635 |

The Doctrine and Covenants is a book of sections, not of books, so a section is IN the holy book
directly, as a surah is in the Quran; a section is the vocabulary's chapter, and `chapter` is its
number. Both were received in English, so a verse has one text: `text` is the scripture and
`original` is empty. References are as a reader writes them — `D&C 76:22`, `Moses 1:39`,
`Joseph Smith—History 1:17` with the printed em dash. The read views accept `Doctrine and Covenants
76:22`, and a hyphen for the dash.

## Where they draw on the Bible

The build finds which verse quotes which, as realm-book-of-mormon's does: each verse is paired with
the King James verse it reads most like, by shared words weighted by rarity, and kept as a
**quotation** or an **allusion** by how alike they are.

Where a chapter's parallel is known, `PARALLEL` in `scripts/build_reference.py` names it, only those
King James chapters are searched, and the Book of Mormon's thresholds apply (quotation 0.4, allusion
0.26):

| Chapters | Parallel | Quoting | Alluding |
|---|---|---|---|
| Moses 2–8 | Genesis 1–6, as Joseph Smith revised it | 135 | 7 |
| Abraham 1–2, 4–5 | Genesis 11–12, and the creation of Genesis 1–2 told of "the Gods" | 51 | 11 |
| Joseph Smith—Matthew 1 | Matthew 23:39–24:51 (with Mark 13, Luke 21) | 48 | 5 |

The distribution splits in two, as the Book of Mormon's does. A revised verse that keeps the King
James's words reads as a quotation — Moses 2:3 is Genesis 1:3 with "I, God" — and one that sets new
matter around them as an allusion: Moses 6:17 on Enos and Cainan in Genesis 5:9. The edge does not tell a
revision from a quotation; it names the King James verse either way.

Everything else — every section of the Doctrine and Covenants, Moses 1, Abraham 3, Joseph
Smith—History and the Articles of Faith — is searched against the whole King James. The best of
31,102 verses scores higher by chance than the best of one chapter's thirty, so the bar is higher:
quotation at 0.6, allusion at 0.3, set from the measured distribution. Above 0.6 are quotations:
D&C 74:1 is 1 Corinthians 7:14 word for word, D&C 138:7–10 quotes 1 Peter 3:18–20 and 4:6, D&C
101:81–84 retells the parable of the unjust judge, and Joseph Smith—History 1:37 is Malachi 4:1.
Between 0.3 and 0.6 are the echoes the sections are full of — D&C 86:7 on the wheat and the tares,
D&C 88:67 on the single eye, Abraham 3:27 on "Here am I, send me", Joseph Smith—History 1:11 reading
James 1:5. Below 0.3 the best match is mostly shared vocabulary, and nothing is kept.

| Scripture | Quoting | Alluding |
|---|---|---|
| Doctrine and Covenants | 29 | 241 |
| Pearl of Great Price | 235 | 28 |

An allusion was found by words alone, so it is a candidate for a reader, not a finding. A long verse
that quotes a short one inside it scores low, because likeness is measured over both verses' words:
D&C 128:18 quotes Malachi 4:6 and is not paired. Each verse stores `kjvRefs` or `kjvAllusions`, and
`rules/corresponds.yml` derives `CORRESPONDS_TO {kind}` to realm-bible's `BibleVerse`. It is empty if
realm-bible is not installed. A section's or chapter's `drawsOn` lists the King James chapters its
verses pair with.

## Views

| View | Answers |
|---|---|
| `ReadDcVerse` | one verse of the Doctrine and Covenants, with the King James verse it quotes or echoes |
| `ReadDcSection` | a whole section by number |
| `DcSections` | every section, its length and the King James chapters it draws on |
| `SearchDoctrineAndCovenants` | verses containing a word |
| `ReadPgpVerse` | one verse of the Pearl of Great Price |
| `ReadPgpChapter` | a whole chapter, with the King James chapters it retells |
| `PgpBooks` | the five books, their titles, sizes and parallels |
| `SearchPearlOfGreatPrice` | verses containing a word |
| `LdsBesideKingJames` | a section or chapter verse by verse beside its King James source, through `CORRESPONDS_TO` (needs realm-bible) |
| `LdsVersesDrawingOn` | every verse of either that quotes or echoes a given King James book (needs realm-bible) |

Searching across scriptures, by word and by meaning, is in realm-scripture-vocabulary.

`sources.yml` declares both texts as documents too — one per section or chapter (`dc://text/76`,
`pgp://text/moses.1`), tagged `scripture` and each scripture's own slug, so the vocabulary's meaning
search ranks them beside every other scripture — embedded on install.

## Rebuilding the reference data

```
python scripts/build_reference.py
```

Downloads into `data/source/` (ignored by git) and rewrites `reference/`. It reads the King James from
`../realm-bible/reference/` and refuses to build without it. It prints the pairs nearest each
threshold, so the effect of a new source on the thresholds can be judged.

## Licences

- **Text**: [bcbooks/scriptures-json](https://github.com/bcbooks/scriptures-json), which states its
  files are in the public domain: the verse text of the 2013 edition, from the Mormon Documentation
  Project, with the 2013 typographic adjustments. It leaves out everything under copyright — the
  introductions, the section and chapter headings (so no section here carries its date or setting),
  the footnotes, and Official Declaration 2 (1978). Official Declaration 1 (1890) is not in the
  source either, so the realm has no Official Declarations. Sections 137 (a vision of 1836) and 138
  (1918) are in the source and included: both were published long enough ago to be public domain in
  the United States. The facsimiles' explanations in the Book of Abraham are in the source but not
  in this realm.
- **Code**: GPL-3.0, as realm-bible.
