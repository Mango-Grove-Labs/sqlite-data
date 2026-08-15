# Decisions

## 2026-08-15 — /adopt: fork-shaped doc contract

Context: `/adopt` ran on a `kind: fork` repo (upstream pointfreeco/sqlite-data + the
Mango patch stack). The canonical doc system was written for app/project repos, so the
adoption shape itself needed decisions. All are cheap to reverse (delete the additive
files); none touch upstream content.

1. **`MANGO-PATCHES.md` is the single reference doc** — it fills the OVERVIEW,
   architecture, and ROADMAP-plan-prose roles. It is kept verbatim at root and is never
   split into `docs/`: each patch commit carries its text, and the vacuity-guard
   procedure (§ Rebase procedure step 4) depends on reverts conflicting on it.
2. **No `docs/ROADMAP.md`** — plan prose for open items already lives in
   `MANGO-PATCHES.md` (§ 8, § patch 3 "Owed", § patch 5 known limitation);
   `PROGRESS.md` `## Roadmap` is the only live checklist and points into those sections.
3. **Upstream files are never edited for doc-contract reasons.** `README.md` passes the
   doctor untouched; the `SyncEngineDelegate.swift` doc example stays as upstream wrote
   it (see `MANGO-PATCHES.md` § patch 5 consumer note for why).
4. **Monorepo surface structure waived.** The tree must mirror upstream for the
   cherry-pick/rebase procedure to work; no migration plan applies to this repo, ever.
   Likewise the signing check and Mango-package-adoption audit are skipped by design:
   `Examples/Examples.xcodeproj` is upstream vendor content and this repo is itself a
   catalog package (`kind: fork`), not an app surface.
5. **`docs/PRD.md` is a placeholder, not a fabricated PRD.** A fork's intent is the
   `MANGO-PATCHES.md` preamble (API-compatible, org-wide vehicle for library-level
   fixes) plus the consuming apps' incident records.
6. **Retro phase labels 1–3 are new identifiers** minted by /adopt for the shipped
   patch stack (grouped by base tag: 1.6.6 → 1.7.0 → 1.9.0); they appear nowhere in
   prior commits/docs — treat them as stable from now on.
