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

## 2026-08-15 — Patch 10: inherit-then-upgrade the busy mode, and retry the ledger writes

Context: 5.3b made the host's connection write to the metadatabase on every local change, and
neither connection was configured to survive the resulting contention (full mechanism in
`MANGO-PATCHES.md` § 10 and the journal entry of the same date).

1. **The library's metadatabase connection inherits the host's busy mode, and only
   `.immediateError` is upgraded** (to `.timeout(5)`). Rejected: unconditionally forcing our own
   timeout — a host that installed a `.timeout` or a `.callback` meant it. Rejected: leaving the
   default and documenting it — the failure is swallowed, so "documented" means invisible.
2. **The ledger writes retry, rather than relying on the host hardening its own connection.**
   MangoSync sets `.timeout(5)`, but the library cannot require that of every host, and the first
   decision makes the library's connection hold the lock more often than before. Bounded (25/50/100 ms)
   and narrow (`SQLITE_BUSY`/`SQLITE_LOCKED` only) so a deterministic failure still fails fast.
3. **The patch's logic lives in a new Mango-owned file.** `CloudKit/Internal/MetadatabaseBusyMode.swift`
   costs zero rebase conflict surface; upstream files carry three one-line call sites. Preferred over
   making `defaultMetadatabase` `package` for its tests, which would have forced `package import` on
   Foundation, GRDB and os inside an upstream file.
4. **An unexplained test failure is a finding, not a baseline** (rebase procedure 4b). "Fails the same
   way on the previous branch" only dates the cause; the clean-base-tag run is what assigns it. This
   episode is the evidence: two failures sat labelled pre-existing while being one commit old.

## 2026-08-17 — Phase 8 (patches 11/12): participant readiness, and the additive-API exception

Trigger: MonteSprout Phase 51.1 (its collaboration-readiness audit § 5 found both library halves
of the participant story). Both red-first on their exact mechanisms; full suite 336/336 ×2.

1. **Patch 11 stays minimal — routing only.** `deleteShare`'s root-record read goes through
   `container.database(for:)` instead of `privateCloudDatabase`; no attempt to also handle
   "record genuinely gone" more gracefully (a removed participant may have lost read access
   before the deletion is processed — recorded as a known limitation; 51.14's device pass
   observes the real teardown ordering). Rejected: treating any fetch failure as "clear the
   share anyway" — that turns a transient failure into a verdict, the exact class patches 1/4/6
   exist to prevent.
2. **Patch 12 is the fork's first additive public-API patch, and the preamble now says so.**
   The old "never the public API" rule was written against *changing upstream symbols*; a
   revocation UX is impossible without a pre-purge event, and shadowing it app-side is
   structurally impossible (the purge is invisible by the time any consumer code runs). The
   sanctioned shape: additive-only, default-implemented (upstream-shaped delegates compile and
   behave unchanged), consumed by MangoSync — never imported directly by an app. Rejected:
   a Notification/closure side-channel (a second delegate mechanism to rot); polling for zone
   disappearance consumer-side (a race by construction).
3. **The hook is observe-only and fires for both scopes.** It cannot veto (the zone is already
   gone server-side); `scope` distinguishes `.shared` — cheaper than a shared-only filter the
   next consumer would have to un-build. `.encryptedDataReset` deliberately does not notify
   (nothing is deleted).
4. **Phase-8 guards are neutralize-in-place from birth** — both patches share `SyncEngine.swift`
   with the five whose bare-revert guards already rotted; writing revert-based guards for them
   would mint two more rotted guards at the next overlapping patch.

## 2026-08-23 — Phase 9 (patch 13): the revocation signal is record-granular, not zone-granular

1. **The event shape is settled by hardware, not by reading CloudKit's docs.** MonteSprout's
   two-account session instrumented three consecutive revocations: `✅ Modified zone`, then
   `🗑️ Deleted <root>` + `🗑️ Deleted cloudkit.share`. Patch 12's premise — that losing access to
   someone else's record arrives as a zone deletion — is simply false on real CloudKit. Patch 12 is
   kept (a zone the owner deletes or purges outright still arrives that way) but it is **not** the
   revocation hook, and anything written as if it were is wrong.
2. **A second delegate method, not a reuse of patch 12's.** The consumer's own finding recommended
   firing the existing zone hook, and the first implementation did. Review rejected it: one owner
   zone holds every hierarchy that owner shares out of it, so a participant given two records from
   the same zone sees them in one shared zone, and revoking one is not a fact about the zone. A
   zone-granular notice makes a consumer sweep the record it still has — in MonteSprout, deleting a
   co-teacher's own private notes about a classroom that is still hers and telling her she lost it.
   `willDeleteSharedRootRecords:inZone:` names the roots that actually went.
3. **Its default implementation is a no-op, deliberately not a forward to the zone hook.** A forward
   would give unadopted consumers the destructive behaviour of dec. 2 for free. Silence until a
   consumer adopts is recoverable; a zone-wide sweep is not. The cost is stated plainly: patch 13 is
   inert until MangoSync and its host implement the method.
4. **The additive-API exception is now two hooks, and that is the stopping point.** Both are
   `SyncEngineDelegate` methods with default implementations, both consumed through MangoSync. The
   preamble's exception class is amended to say "the two hooks", not "patch 12's hook".
5. **A negative test on a hook is assumed vacuous until proven otherwise.** All three of this
   patch's silence guards passed pre-patch. Each was proven by mutating the *shipped* patch — and
   the first draft of the private-scope test survived deleting the guard it existed for, because it
   deleted an unshared record. Write the mutation down beside the test.

## 2026-08-23 — Phase 10 (patch 14): the ledger must count what the engine will send

1. **The mechanism is not sharing-specific, so neither is the fix.** MonteSprout's F4 recommended
   "stamp the mirror on the shared-zone save/fetch paths". Tracing it found the user tables'
   `after_update` trigger stamping `userModificationTime` for the sync engine's own apply write.
   Every re-delivered row on every device was affected; a share re-delivers a whole zone, which is
   only why the reading was a device's entire row set. Patching the two named paths would have left
   the general bug in place and fixed nothing on an unshared device.
2. **Guard the column, not the trigger.** That trigger is the one metadata trigger without an
   `isSynchronizing` guard *on purpose* — its zone/parent maintenance must follow the server. Only
   the stamp is wrong there, so only the stamp is guarded
   (`CASE WHEN isSynchronizing THEN userModificationTime ELSE currentTime() END`).
3. **The ledger's contract is "what the engine will send", not "what changed on disk".** A
   sync-applied write enqueues no save — the metadata callback trigger is `!isSynchronizing` — so it
   must not read as one waiting. Post-patch the two agree; that is the invariant to test against
   next time, rather than any particular number.
4. **Mirror the stamp the record CARRIED, not the one the apply path forced up.**
   `upsertFromServerRecord` raises the record's stamp to the local one so the merged row can be
   re-uploaded. Guarding the trigger alone made the mirror inherit that value, which declares an
   already-unsent local edit settled the moment any server record for its row arrives — a false
   negative in exactly the state the ledger exists to show. The pre-force value is passed down; the
   new parameter is defaulted so save-ack callers are untouched (there the record *is* the server's
   copy verbatim).
5. **Junk becomes NULL, never an invented "in sync" stamp.** The upgrade repair follows 5.3a: at
   migration time a behind-mirror cannot be told from a genuine unsent edit, and patch 7's rule
   forbids inventing a level stamp. The rare true positive cleared is not that row's only guard —
   5.3b's durable pending ledger carries a stranded save across the launch.
6. **The slim-ack residual is split, not absorbed (10.2).** Only a fetch can ever level a mirror:
   real CloudKit's save ack carries no encrypted fields. Closing it needs the stamp the *sent* record
   carried kept across the batch → ack boundary — a new column, since a further local edit can land
   in that window. Patch 14 shrinks patch 9's re-enqueue loop from *every fetched row* to
   *fetched-and-locally-edited* rows; the residual is pinned as current behavior by
   `aSlimAckCannotLevelTheMirrorOfAFetchedRow` rather than left to be re-diagnosed.

## 2026-08-23 — Phase 10.2 (patch 15): the sent stamp is a fact, not an invention

1. **The stamp comes off the RECORD in the batch, not off the metadata row.**
   `CKRecord.userModificationTime`'s setter takes a `max`, so an outgoing record built on an
   all-fields archive can carry a stamp higher than `metadata.userModificationTime`. What is on the
   wire is what the server will hold, so that is what gets written down. A record with no stamp at
   all records nothing — absent stays unknown, never `-1` (patch 7's rule, third application).
2. **Read the batch, not the provider closure.** The stamps are collected from
   `batch.recordsToSave` after `recordZoneChangeBatch` returns, so only records that actually made
   the batch are recorded, and the whole batch costs one write instead of one per record.
3. **The ack MOVES the stamp with a `max`, never a plain assignment.** A fetch landing in the same
   window can already have put a newer server copy's stamp in the mirror; a plain assignment would
   move the mirror backwards and re-open a row patch 9 would then re-enqueue.
   `coalesce(max(mirror, sent), sent, mirror)` is monotone and NULL-correct in all four combinations.
4. **The move runs after `refreshLastKnownServerRecord`, deliberately.** When an ack *does* carry its
   encrypted fields (the mocked container, and whatever CloudKit chooses to echo) the record's own
   stamp is the better source; it lands first and the `max` leaves it alone. Ordering, not a branch.
5. **A refused save discards its stamp.** The next batch build overwrites it anyway, so the clear is
   hygiene rather than a correctness fix — but it is what makes the column's meaning ("a record
   carrying this is in flight") literally true, which is the property the `max` rule is safe under.
6. **This is not the F2 invention.** F2 forbade writing a stamp the *ack* did not carry — the `?? -1`
   getter fallback. Patch 15 writes a stamp this device demonstrably put on the wire and the server
   demonstrably accepted. The distinction is knowledge, not optimism.
7. **The harness cannot reproduce the field's ordering, and the test says so.** A mocked record has
   no `modificationDate` — nothing can give it one — so `refreshLastKnownServerRecord`'s
   newer-than-mine guard always answers yes and the mock's batch build levels a confirmed row's
   mirror optimistically, which real CloudKit's does not. The inversion test reaches the same
   behind-mirror state through a fetch that lands while the save is in flight. Rejected the
   alternatives: setting `modificationDate` (impossible — read-only system field) and asserting on
   fabricated metadata (proves the SQL, not the path).
8. **Side effect accepted and documented: the NULL-mirror slim-ack shape mostly disappears in the
   field.** Rows that went through the batch builder now leave their ack with a real mirror, so
   patch 9's start rescan gains the "edit to a slim-acked row" shape it was structurally blind to.
   That is a gain; 5.3b's ledger remains the guard for a change that dies before its ack.
