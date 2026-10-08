<!-- b-init-managed:start -->
# Docs

Index for project docs. Each folder has its own `README.md` with naming and a template.

## Folders
- [`references/`](references/README.md): material sourced from external research.
- [`runbooks/`](runbooks/README.md): guides to set up or operate the project.
- [`decisions/`](decisions/README.md): ADRs.
- [`architecture/`](architecture/README.md): as-built structure and diagrams from **b-drawio** or **b-excalidraw**.
- [`specs/`](specs/README.md): requirements and approved plans.

## Where does a doc go
- Facts gathered from outside the repo (vendor docs, versions) -> `references/`.
- Steps to set up, run, back up, restore, or troubleshoot -> `runbooks/`.
- Why a choice was made, or reversed -> `decisions/`.
- How the system is currently built -> `architecture/`.
- What is to be built and how it is accepted -> `specs/`.

## Shared rules
- Names are lowercase kebab-case ASCII `.md` with no dates, except `README.md` and `DESIGN.md`. `docs/DESIGN.md` stays at the docs root under **b-design**.
- Search for an existing doc and update it in place before creating a new one.
<!-- b-init-managed:end -->
