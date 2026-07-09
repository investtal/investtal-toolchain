# Progress — 9cc scripts + docs align

Plan: `docs/plans/2026-07-09-9cc-scripts-docs-align.md`
Branch: main (user approved subagent-driven on current branch)

## Global Constraints
- Prefer `gh api` over raw GitHub URLs for release/content fetch (IVT-0608).
- Keep local-fixture path: if `CC9_SOURCE` is an existing file, copy it (tests).
- Do not add deps, frameworks, or new script files.
- Model registry stays the 13 entries already in `scripts/9cc.sh` / `scripts/9cc.ps1`.
- README install one-liners already use `gh api contents`; keep that as public install path.
- Historical plan `docs/plans/2026-07-08-9cc-model-switcher.md` is a record of past work — do not rewrite it; only add a short status note at top if touched.

## Ledger
Task 1: complete (commits 5f28842..d819b63, review clean; minor: static-contract test only)
Task 2: complete (commits d819b63..fc94e33, review clean; no pwsh on host)
Task 3: complete (commits fc94e33..5e3f574, review clean; minor pre-existing uninstall &&2 typo noted)
Task 4: complete (commits 5e3f574..d207d43, review clean; minor version-precedence wording)
Final review: PASS (ship ready). Minor pre-existing: 9cc.ps1 Update-9cc base64 no whitespace strip.

Finish: tests PASS=66 FAIL=0; on main ahead 4; awaiting user integration choice.
