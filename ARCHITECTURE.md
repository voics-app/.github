# Architecture

This repository has no runtime service. Its "components" are reusable GitHub
Actions workflows that the Discordy repositories call. Each one is a small
unit with one job. Every input is explicit, and the scripts embedded in the
workflows are covered by `tests/test_workflows.py`.

## C4 component view

```mermaid
C4Component
    title discordy-voics/.github - reusable CI components

    Container_Boundary(caller, "Service repo ci.yml (api, gateway, messages, voice, client, admin, ...)") {
        Component(ci, "ci.yml", "workflow", "Calls the reusable workflows with image-name and description")
    }

    Container_Boundary(org, "discordy-voics/.github") {
        Component(lang, "rust.yml / elixir.yml / node.yml", "workflow_call", "Lint, test, dependency audit")
        Component(docker, "docker.yml", "workflow_call", "buildx, Trivy, GHCR push, syft SBOM, cosign")
        Component(guard, "gitflow-guard.yml", "workflow_call", "Enforces git-flow PR sources")
        Component(rp, "release-please.yml", "workflow_call", "Release PR, vX.Y.Z tag, changelog")
        Component(ret, "ghcr-retention.yml", "workflow_call", "Prunes old prerelease images")
        Component(inv, "secrets-inventory-check.yml", "workflow_call", "Manifest secret keys vs inventory")
    }

    System_Ext(ghcr, "GHCR", "ghcr.io/discordy-voics/*")
    System_Ext(sigstore, "Sigstore", "Fulcio / Rekor keyless signing")
    System_Ext(docs, "discordy-voics/docs", "secrets/inventory.yaml")

    Rel(ci, guard, "pull_request")
    Rel(ci, lang, "push / pull_request")
    Rel(ci, docker, "needs: lang")
    Rel(ci, rp, "push to main")
    Rel(rp, docker, "version output")
    Rel(docker, ghcr, "push image, SBOM attestation")
    Rel(docker, sigstore, "OIDC keyless signature")
    Rel(ret, ghcr, "delete expired prereleases")
    Rel(inv, docs, "reads inventory")
```

## Pipeline order (spec section 13)

lint -> test -> build -> scan (Trivy, cargo-audit, sobelow, pnpm audit) -> SBOM (syft) -> push to GHCR -> cosign signature.

`docker.yml` builds and scans a local single-platform image **before** it
pushes anything, so an image with a CRITICAL vulnerability never reaches the
registry. The multi-platform push that follows reuses the GitHub Actions
BuildKit cache.

## Design decisions

- **No shared script files**: reusable workflows in a private repo cannot
  easily check out their own repo, so every script lives inline in its
  workflow. Values reach the scripts only through `env:`, never through `${{ }}`
  inside `run:`, which prevents script injection. The tests run those inline
  scripts directly.
- **`runs-on` as string-or-JSON**: callers pass `ubuntu-latest` or
  `["self-hosted","discordy"]`. The expression
  `startsWith(inputs.runs-on, '[') && fromJSON(inputs.runs-on) || inputs.runs-on`
  turns either form into a runner selector.
- **Action pinning**: every third-party action is pinned to a commit SHA, with
  the release tag as a comment. Dependabot updates the pins.
