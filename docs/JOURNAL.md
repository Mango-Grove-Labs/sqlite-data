# Journal

> Append-only, newest entries last. Created by /adopt 2026-08-15.

## 2026-08-15 — /adopt: repo joins the doc contract

State at adoption: consumer branch `mango/patches-1.9` = upstream tag 1.9.0 + patches 1–7
and their guard tests, full suite verified green 2026-08-10 per the rebase procedure
(previous branches `mango/patches-1.6` / `-1.7` kept intact for existing consumer pins).
No history was evicted — the repo had no PROGRESS.md, no CLAUDE.md, and no status
sections anywhere; `MANGO-PATCHES.md` (patch catalog + rebase procedure + consumer rule)
predates adoption and stays intact at root by decision (see `docs/DECISIONS.md`
§ 2026-08-15). Adoption was purely additive: PROGRESS.md cursor + checklist, this
journal, the decisions log, and a PRD placeholder. Open items collected into Roadmap
phase 4: the owed unbounded-range audit (GRDB first), patch 8 (a read failure must not
masquerade as a deletion), and the `drop(ifExists:)` teardown fix.
