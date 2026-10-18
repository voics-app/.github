# Discordy

Discordy is a self-hosted, Discord-equivalent chat platform: guilds, channels,
direct messages, voice and bots. It runs locally with docker compose and in
production on microk8s through Flux.

## Repositories

| Repo | What it is |
|---|---|
| [`api`](https://github.com/discordy-voics/api) | REST API, auth and permissions (Rust) |
| [`messages`](https://github.com/discordy-voics/messages) | Message storage on ScyllaDB (Rust) |
| [`gateway`](https://github.com/discordy-voics/gateway) | Real-time WebSocket gateway (Elixir/Phoenix) |
| [`voice`](https://github.com/discordy-voics/voice) | Voice signaling (Elixir) and SFU (Rust) |
| [`client`](https://github.com/discordy-voics/client) | Desktop client (Electron + React) |
| [`admin`](https://github.com/discordy-voics/admin) | Admin portal (React + Rust BFF) |
| [`bots-sdk`](https://github.com/discordy-voics/bots-sdk) | Bot SDK |
| [`contracts`](https://github.com/discordy-voics/contracts) | OpenAPI and JSON Schemas, generated TS/Rust/Elixir types |
| [`gitops`](https://github.com/discordy-voics/gitops) | Flux cluster config and the local compose stack |
| [`docs`](https://github.com/discordy-voics/docs) | Spec, ADRs, C4 model, runbooks, secrets inventory |
| [`.github`](https://github.com/discordy-voics/.github) | Reusable CI workflows and org defaults |

## How we work

- git-flow: `feature/*` into `develop`, `release/*` and `hotfix/*` into `main`.
- Conventional Commits; versions and changelogs by release-please.
- Images at `ghcr.io/discordy-voics/<repo>[-<component>]`, signed with cosign and shipped with an SBOM.
- Contributing guide: [docs/CONTRIBUTING.md](https://github.com/discordy-voics/docs/blob/main/CONTRIBUTING.md).
