# Agents

Read README.md and CONTRIBUTING.md first: this repo is public, and every
component change goes branch → PR → merge → paste into Datto.

## Checks

Before pushing, run `tools/check.sh`: every CI check that runs on Linux, in
about 30 seconds. Windows is tested only in CI. To wait for a PR's CI, run
`tools/wait-ci.sh <pr>`; it always ends and prints only what failed.

Reviews apply `CODING_STANDARDS.md`.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on TechCollective/DattoRMM_Components (public — no client details). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one GLOSSARY.md and docs/adr/ at the repo root, created as needed. See `docs/agents/domain.md`.
