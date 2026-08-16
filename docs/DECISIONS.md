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

## 2026-08-15 — Consumer review of 5.1/5.2: approved, and Phase 5 re-opened for 5.3

Reviewed from the consumer side (MonteSprout session; both new suites re-run green here). 5.1 approved
outright — the amendment even covers a mechanism the plan missed (a slim re-ack stomping a
previously-correct stamp). 5.2 approved as scoped. Two findings promoted into a new 5.3, blocking
adoption:

1. **The legacy `-1` sentinel loop (adoption blocker, found in review).** Every row uploaded under
   pre-amendment code holds mirror `-1` on disk. Patch 9 selects `-1 < local` at every start, and the
   amended ack path (correctly) never rewrites a slim ack's mirror — so an UPGRADED device re-enqueues
   its entire pre-fix dataset on EVERY launch, forever: a permanent de-facto blanket reupload (blobs
   included) arriving through the back door of two individually-correct patches. Fix: a one-time
   metadatabase migration nulling `-1` mirrors — junk becomes honest unknown; `-1` cannot be a
   legitimate epoch-ns stamp. Composition-of-patches lesson: each patch's tests passed; only walking an
   upgraded ledger through both showed it.
2. **The durable park graduates from "optional hardening" to required.** § 9's accepted scope bounds
   (stranded edit on a slim-acked NULL-mirror row; stranded DELETE) sit exactly on the consumer's S5
   matrix step — the gate probes that shape by design, so shipping the gap risks failing the build-17
   matrix and burning a build number + a hardware day. Owner call (consumer session, 2026-08-15):
   build 5.3 before adoption rather than letting the matrix decide.

## 2026-08-15 — 5.3 refinement (fork-side plan review): the mechanism is the always-on ledger

The review round's "durable park persists at park time" could never pass its own promised test: a
mid-flight force-quit (the S5 stranded-edit shape) goes through no park handler — the pending save
exists only in CKSyncEngine's in-memory state, so a park-time hook never sees it. The mechanism is
therefore the **always-on durable pending ledger**: `didUpdate`/`didDelete` write the existing
`PendingRecordZoneChange` table while the engine runs too (upstream writes it only while stopped),
sends/acks clear rows, the existing start drain re-enqueues, and patch-6 parks write through it —
one mechanism covering the stranded edit, the stranded DELETE, and the park crash-window at once.
Also split for sizing: 5.3a (the `-1` sentinel migration, the adoption blocker) and 5.3b (the
ledger) are separate session-sized slices; the stranded-DELETE rescan exclusion (§ 5.2 entry)
stands for the rescan predicate itself.

## 2026-08-15 — 1.10.0 retarget: what we take from upstream, and what now proves a patch survived

**Take only the two `TriggerTests.swift` lines from upstream #522, not the commit.** Tag 1.10.0 ships
a stale inline snapshot — it raised its `swift-structured-queries` floor to 0.36.0, which removed a
redundant paren pair in `IN (…)` subquery rendering, but left the old form recorded. `triggers()`
therefore fails on a **clean checkout of the tag**; verified against vanilla 1.10.0 before touching
anything, which is what established it as upstream's defect and not the patch stack's. Upstream fixed
it the same day in #522, but that commit is on `main` and in **no release tag**, and the rest of it is
an unrelated `$foo.set(…)` → `.taskLocal($foo, …)` test-API migration that collides with our patched
test files. So: take the snapshot re-record verbatim, leave the migration, and drop the re-record at
the first upstream tag containing #522. Rejected alternative — cherry-pick all of #522: it drags an
unreleased test-API migration into a fork whose whole value is being boring relative to upstream.

**The byte-identity check, not the step-4 guards, is now what rules out a dropped patch at a
retarget.** Re-verifying the guards on this retarget found that five of the nine have rotted: patches
5, 6, 7 and 9 no longer revert at all (conflict, or a no-op reverse-apply), and patch 1 reverts only
with a conflict resolution that can also revert adjacent patch content — because 5.3a/5.3b later
rewrote the same `SyncEngine` regions. This is not rebase damage; the identical reverts behave the
same way on `mango/patches-1.9`. The replacement check exploits a durable structural fact: upstream
has never touched `CloudKit/SyncEngine.swift`, `CloudKit/Internal/Metadatabase.swift` or
`CloudKit/SyncMetadata.swift`, so `git diff <old mango branch> <new mango branch> --
Sources/SQLiteData/CloudKit/` must be **empty** after any retarget. That directly refutes the exact
failure step 4 exists to catch — a conflict resolved by taking upstream's side silently reverting
patch 6's removed case-list codes or 5.3b's removed start wipe, neither of which produces a compile
error. It is strictly stronger than the guards *for the drop question*, and strictly weaker for the
"is the patch still meaningful on the new base" question, which is why rewriting the rotted guards in
the 5.3a style (neutralize the mechanism in place, never revert the commit) stays owed rather than
cancelled.
