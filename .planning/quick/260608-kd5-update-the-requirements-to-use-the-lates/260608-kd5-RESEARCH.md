# Quick Research: Python requirement target

**Task:** Update Correlia requirements to use the latest LTS Python.  
**Date:** 2026-06-08  
**Confidence:** HIGH for Python release/support facts; MEDIUM for repo touchpoints because the repo currently has planning docs only, not a generated Python package yet.

## Answer

Python does **not** publish a separate Ubuntu-style "LTS" line to target. [CITED: https://devguide.python.org/versions/] CPython uses per-feature-release lifecycle states: feature, prerelease, bugfix/stable, security, and end-of-life. [CITED: https://devguide.python.org/versions/#status-key] PEP 602 says each Python 3.x line is maintained for five years; starting with Python 3.13, that means about two years of bugfix/full releases followed by three years of source-only security fixes. [CITED: https://peps.python.org/pep-0602/#years-of-full-support-3-more-years-of-security-fixes]

As of 2026-06-08, the latest stable/bugfix Python line is **Python 3.14**, and the latest published 3.14 patch release is **Python 3.14.5** from 2026-05-10. [CITED: https://www.python.org/downloads/] [CITED: https://peps.python.org/pep-0745/#bugfix-releases] Python 3.15 is not stable yet: PEP 790 lists 3.15.0 beta 2 as actual on 2026-06-02 and 3.15.0 final as expected on 2026-10-01. [CITED: https://peps.python.org/pep-0790/#schedule]

**Recommendation:** If the user intent is "latest supported stable Python," update Correlia's baseline from **Python 3.13+** to **Python 3.14+**. [VERIFIED: repo + Python docs] Do not call it "latest LTS" in project docs; call it "latest stable CPython feature release in bugfix support" or simply "Python 3.14+". [CITED: https://devguide.python.org/versions/#status-key]

## Why 3.14, not 3.13 or 3.15?

| Candidate | Status on 2026-06-08 | Support horizon | Decision |
|---|---:|---:|---|
| Python 3.13 | bugfix/stable; first released 2024-10-07; EOL 2029-10 [CITED: https://devguide.python.org/versions/] | Long supported, currently project's documented baseline [VERIFIED: `.planning/PROJECT.md`, `CLAUDE.md`, `idea.md`] | Keep only if the goal is conservative dependency compatibility. |
| Python 3.14 | bugfix/stable; first released 2025-10-07; EOL 2030-10 [CITED: https://devguide.python.org/versions/] | Newest stable line; 3.14.5 is current as of 2026-06-08 [CITED: https://peps.python.org/pep-0745/#bugfix-releases] | **Recommended baseline for this requested update.** |
| Python 3.15 | prerelease/beta; final expected 2026-10-01 [CITED: https://peps.python.org/pep-0790/#schedule] | Not stable yet | Do not target as the main requirement. |

The existing project research previously recommended Python 3.13.x as a safer baseline and allowing 3.14.x after CI proves dependencies. [VERIFIED: `.planning/research/STACK.md`] That was a conservative stack decision, not a Python lifecycle constraint. [VERIFIED: repo + Python docs] Because this repo is still planning-only and has no Python package files yet, switching the documented baseline to 3.14+ is low-cost if the project wants newest-stable behavior. [VERIFIED: repo root listing]

## Repo touchpoints likely requiring updates

Current repo facts: there is no `pyproject.toml`, `.python-version`, `requirements.txt`, `uv.lock`, source package, or CI workflow in the repo root right now. [VERIFIED: repo root listing] Existing Python version references live in planning/design docs.

Update these when executing the change:

1. `.planning/REQUIREMENTS.md`
   - `FND-01`: change "Python 3.13" to "Python 3.14". [VERIFIED: `.planning/REQUIREMENTS.md`]

2. `.planning/PROJECT.md`
   - Context line describing idea-doc stack: `Python 3.13+` -> `Python 3.14+`. [VERIFIED: `.planning/PROJECT.md`]
   - Constraints tech stack: `Python 3.13+` -> `Python 3.14+`. [VERIFIED: `.planning/PROJECT.md`]

3. `idea.md`
   - Technology Stack language entry: `Python 3.13+` -> `Python 3.14+`. [VERIFIED: `idea.md`]

4. `.planning/research/STACK.md`
   - Recommendation and core technology row currently say `Python 3.13.x baseline; allow 3.14.x only after CI proves all dependencies`; revise to a 3.14 baseline if this quick task is accepted. [VERIFIED: `.planning/research/STACK.md`]
   - Ruff target currently says `py313`; revise to `py314` if the future project baseline becomes 3.14. [VERIFIED: `.planning/research/STACK.md`]
   - Compatibility notes currently discuss Python 3.13; update to 3.14 after dependency metadata is checked during implementation. [VERIFIED: `.planning/research/STACK.md`]

5. `CLAUDE.md`
   - Mirrors `.planning/PROJECT.md` and `.planning/research/STACK.md` inside generated GSD sections. [VERIFIED: `CLAUDE.md`] Prefer updating source planning/research artifacts and regenerating/syncing `CLAUDE.md` through the project workflow rather than hand-editing only `CLAUDE.md`. [ASSUMED]

6. Future package files, when created
   - `pyproject.toml`: set `requires-python = ">=3.14"`. [ASSUMED]
   - `.python-version`: pin a concrete patch such as `3.14.5` now, then allow normal patch upgrades. [ASSUMED]
   - `uv.lock`: regenerate after creating/updating project metadata. [ASSUMED]
   - CI/tooling: use Python 3.14 and configure Python-aware tools such as Ruff for `py314`. [ASSUMED]

## Implementation guidance

- Do **not** use a patch version in package compatibility metadata; use a minor baseline such as `>=3.14`. [ASSUMED]
- It is fine to document the current patch as "verified against Python 3.14.5" separately from the requirement floor. [ASSUMED]
- If retaining compatibility with 3.13 matters, use `>=3.13` and test both 3.13 and 3.14 instead of raising the floor. [ASSUMED]
- For this user's stated request, the clean cutover is `Python 3.14+`, with wording changed from "LTS" to "stable bugfix-supported CPython release." [VERIFIED: repo + Python docs]

## Sources

- Python Developer's Guide — Status of Python versions: https://devguide.python.org/versions/
- Python downloads page — active releases and current 3.14 patch releases: https://www.python.org/downloads/
- PEP 602 — Annual Release Cycle for Python: https://peps.python.org/pep-0602/
- PEP 745 — Python 3.14 Release Schedule: https://peps.python.org/pep-0745/
- PEP 790 — Python 3.15 Release Schedule: https://peps.python.org/pep-0790/
- Repo files read: `.planning/STATE.md`, `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, `.planning/research/STACK.md`, `CLAUDE.md`, `idea.md`

## Open questions

None blocking. The only product decision is whether "latest stable" should override the prior conservative 3.13 baseline. If yes, target Python 3.14+. If no, keep Python 3.13+ and add 3.14 as a supported/tested runtime.
