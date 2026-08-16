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

## 2026-08-15 — Phase 5: the consumer fix round (MonteSprout 1.0(16) matrix findings)

Planned from the consumer's evidence (`MonteSprout/docs/incidents/2026-08-15-device-matrix-1.0.16.md`);
the matrix failed on S5 and MonteSprout's build 17 is gated on these two slices.

1. **Phase 5 jumps the queue ahead of Phase 4.** Release-blocking consumer work beats hygiene; Phase 4
   stays open and blocks nothing (4.2's planned patch 8 is adjacent send-queue territory and rebases on
   top of Phase 5 whenever it's built).
2. **Numbering: F2 = an AMENDMENT to patch 7, not a new patch** — it repairs patch 7's own mirror
   write. **F10 = patch 9**, leaving 8 reserved for the long-planned metadata-read patch (the catalog's
   numbers stay stable; § 8's own numbering note is precedent).
3. **Verify-before-patch is contractual for 5.1.** The false positive is proven behaviorally (four
   consumer ledger data points, each = exactly its own uploads); the slim-ack `?? -1` write path is the
   prime suspect, not an observation — the slice starts with a reproducing test, and a non-reproducing
   test means characterize the real writer, not patch the suspect anyway.
4. **5.2's rescan is TARGETED, never blanket** (never-confirmed + mirror-behind rows only) — the
   consumer's owner explicitly ruled out an automatic full reupload (blob rewrite cost, fleet re-fetch,
   stamp-stomp risk); hence the hard dependency 5.1 → 5.2 (a flooded mirror makes "targeted" = "all").
5. **Adoption is ONE pin bump after both slices** (MonteSprout 48.3 via `/mango-update`), then the
   consumer cuts 1.0(17) and re-runs its full matrix — the fork's milestone stops here for review.

## 2026-08-15 — 5.2: stranded deletes stay out of the start rescan

Patch 9's engine-start rescan selects **live rows only** (`NOT _isDeleted`). A locally-deleted row
whose pending DELETE died with the process is a real stranded shape (the row resurrects on the next
fetch), but the rescan's no-op-update idiom emits a *save* per selected row — including a tombstone
would re-save the record the user deleted, which is worse than the stranding. A delete-aware
re-enqueue is a different mechanism (read the tombstone's recordID and `state.add(.deleteRecord(…))`
directly) and no fleet evidence shows the shape yet, so it stays out of the targeted predicate.
Reversal: extend patch-9-style when evidence arrives (noted in `MANGO-PATCHES.md` § 9 scope bounds).
Also deliberately not built: the durable park (optional hardening per the plan) — the rescan alone
heals rows already stranded in the field, which the park cannot.
