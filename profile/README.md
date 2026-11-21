# Discordy

Discordy is a self-hosted, Discord-equivalent chat platform: guilds, channels,
direct messages, voice and bots. It runs locally with docker compose and in
production on microk8s through Flux.

## Repositories

| Repo | What it is |
|---|---|
| [`api`](https://github.com/voics-app/api) | REST API, auth and permissions (Rust) |
| [`messages`](https://github.com/voics-app/messages) | Message storage on ScyllaDB (Rust) |
| [`gateway`](https://github.com/voics-app/gateway) | Real-time WebSocket gateway (Elixir/Phoenix) |
| [`voice`](https://github.com/voics-app/voice) | Voice signaling (Elixir) and SFU (Rust) |
| [`client`](https://github.com/voics-app/client) | Desktop client (Electron + React) |
| [`admin`](https://github.com/voics-app/admin) | Admin portal (React + Rust BFF) |
| [`bots-sdk`](https://github.com/voics-app/bots-sdk) | Bot SDK |
| [`contracts`](https://github.com/voics-app/contracts) | OpenAPI and JSON Schemas, generated TS/Rust/Elixir types |
| [`gitops`](https://github.com/voics-app/gitops) | Flux cluster config and the local compose stack |
| [`docs`](https://github.com/voics-app/docs) | Spec, ADRs, C4 model, runbooks, secrets inventory |
| [`.github`](https://github.com/voics-app/.github) | Reusable CI workflows and org defaults |

## How we work

- git-flow: `feature/*` into `develop`, `release/*` and `hotfix/*` into `main`.
- Conventional Commits; versions and changelogs by release-please.
- Images at `ghcr.io/voics-app/<repo>[-<component>]`, signed with cosign and shipped with an SBOM.
- Contributing guide: [docs/CONTRIBUTING.md](https://github.com/voics-app/docs/blob/main/CONTRIBUTING.md).
