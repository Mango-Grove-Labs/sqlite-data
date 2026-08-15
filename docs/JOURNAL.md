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

## 2026-08-15 — Phase 5 planned: the consumer fix round (no code changed)

Planned from MonteSprout's 1.0(16) device-matrix evidence (its
`docs/incidents/2026-08-15-device-matrix-1.0.16.md`; the matrix failed on S5, build 17
is gated on this). Two slices, jumping the queue ahead of Phase 4: 5.1 = patch 7
amendment for the F2 mirror false-positive (verify-before-patch contractual — the
slim-ack `?? -1` suspect must reproduce in a failing test first), 5.2 = patch 9 for F10
(engine-start targeted re-enqueue REQUIRED — plan-review amendment: it is the only half
that heals already-stranded fleet rows, so "either half suffices" was dropped; durable
park demoted to optional hardening). Docs only: `MANGO-PATCHES.md` § 7 defect note +
§ 9 Planned, PROGRESS Phase 5 + cursor at 5.1, DECISIONS § Phase 5. Both slices tagged
`[model: fable]`.
