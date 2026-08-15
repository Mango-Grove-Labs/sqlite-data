# PRD — placeholder

> Created by /adopt 2026-08-15. This fork carries no product PRD, deliberately — do not
> fabricate one.

Intent lives in:

- **`MANGO-PATCHES.md` preamble** — the fork is the org-wide vehicle for library-level
  fixes to pointfreeco/sqlite-data; fully API-compatible (patches change behavior or the
  dependency manifest, never public API); library bugs are fixed here, never shadowed in
  an app or wrapper package.
- **Consuming apps' incident records** — each patch's "why" is an investigation held in
  the consumer repo (e.g. MonteSprout `docs/incidents/2026-07-18-metadata-decode-blocks-all-uploads.md`).
