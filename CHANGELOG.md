# Changelog

All notable changes to this repository are documented here. From the first
release on, this file is maintained by release-please.

## [0.2.0](https://github.com/discordy-voics/.github/compare/discordy-voics-github-v0.1.0...discordy-voics-github-v0.2.0) (2026-10-23)


### Features

* add issue and PR templates, CODEOWNERS, dependabot and contributing pointer ([bdfea79](https://github.com/discordy-voics/.github/commit/bdfea797db043c8c3285b0016033bc9785f40147))
* **ci:** add ghcr retention and secrets inventory check workflows ([5f0a023](https://github.com/discordy-voics/.github/commit/5f0a023f718c9ed4e67e6e0c8558d9c84e4c7008))
* **ci:** add release-please and gitflow-guard workflows ([65029a3](https://github.com/discordy-voics/.github/commit/65029a346796f4551540343bd43c57be7ffebb60))
* **ci:** add reusable docker image workflow with scan, sbom and signing ([86bf08c](https://github.com/discordy-voics/.github/commit/86bf08c113abc3a2903f9cdc8d46a73329c0d257))
* **ci:** add reusable rust, elixir and node workflows ([064dbf0](https://github.com/discordy-voics/.github/commit/064dbf06d97433365b8a0a67b424d28c89f4aae5))
* **ci:** optional on-demand runner on the owner's PC (repo variable CI_RUNNER) ([48ad27e](https://github.com/discordy-voics/.github/commit/48ad27efc79b9a32a33fa54ea982fe0c8cc97575))
* **ci:** reusable minio-publish workflow for site and installer uploads ([d428ef1](https://github.com/discordy-voics/.github/commit/d428ef150e0910d39cf733dbb0d1aee5e5520951))
* **ci:** runner.sh for PC and VM runners, runner-vm-bootstrap.sh, README section ([bfe1c6b](https://github.com/discordy-voics/.github/commit/bfe1c6b36aa25fc305f0457594a7b10cd9ecc48e))
* Definition of Done in issue and PR templates; platform change template ([8a70440](https://github.com/discordy-voics/.github/commit/8a7044061e0458baf9ee91232f0be74e3791e279))
* **runner:** progress output during up ([f3b3300](https://github.com/discordy-voics/.github/commit/f3b330035269a865ca87b4d3cc1f483154db16db))
* **runner:** switch only the heavy repos to self-hosted (split with GitHub-hosted) ([5eb48f3](https://github.com/discordy-voics/.github/commit/5eb48f3bd70c0a456e7256ce598da5af3b48ee20))


### Bug Fixes

* **ci:** apt-get without sudo when running as root (self-hosted runner containers) ([1b86d85](https://github.com/discordy-voics/.github/commit/1b86d85038d3abe706181a64cdf703a32fc1fa79))
* **ci:** default SELF_HOSTED in docker meta step; actionlint custom runner labels ([0b18cc1](https://github.com/discordy-voics/.github/commit/0b18cc1dd5304263d7f098287cfb39c5ce180e2d))
* **ci:** make hex.audit advisory and skip inventory check without a token ([1e6a113](https://github.com/discordy-voics/.github/commit/1e6a11307a6df0b25569fd96dc7ad7f2f75c4063))
* **ci:** minio-publish reads the MinIO key through scoped Kubernetes RBAC ([a610d10](https://github.com/discordy-voics/.github/commit/a610d10a4935990efeedadbcdeeac5ab9601695c))
* **ci:** minio-publish uses s5cmd (mc is no longer downloadable) ([be7c7a2](https://github.com/discordy-voics/.github/commit/be7c7a2c58b6915fe0852e5eaf2add4de1a62058))
* **ci:** pass SBOM registry credentials only for pushed images ([ed39ac5](https://github.com/discordy-voics/.github/commit/ed39ac549658485667d8f8bb9b5afbcf1ed55ae8))
* **ci:** read the SBOM from the local daemon when the image is not pushed ([fcb2ebb](https://github.com/discordy-voics/.github/commit/fcb2ebb221addc71708b35874fd52b79daea15fa))
* **ci:** self-hosted runners: Rust in the audit job, host networking for testcontainers ([b360d6c](https://github.com/discordy-voics/.github/commit/b360d6c1099aec4c7d8e0f8428bd2a02182aca31))
* **ci:** self-hosted tests use the system python3 (+python3-yaml, yq in the runner image) ([11256aa](https://github.com/discordy-voics/.github/commit/11256aa31fabb2f2417b2cc85f4db370bf7e7510))
* **docker:** direct cosign install (envsubst missing on self-hosted) ([d8425bb](https://github.com/discordy-voics/.github/commit/d8425bbffdbbbef9ef3c918c0d8e500ac3aa739a))
* **docker:** install cosign by pinned direct download (installer needs envsubst, missing on self-hosted image) ([2c9f7ad](https://github.com/discordy-voics/.github/commit/2c9f7ad53da1a2dd11272148de6c32ea57744266))
* **docker:** OCI annotations for GHCR title/description; pre-release version from the latest git tag ([64b6249](https://github.com/discordy-voics/.github/commit/64b624943a866a1b9b82c34a50346578a15be216))
* **docker:** restore escaped newline in the description annotation (YAML broke every caller) ([8554d34](https://github.com/discordy-voics/.github/commit/8554d348d46ad5cb2ef49adf8a01eddc1023923d))
* **docker:** Trivy DB from GHCR with GCR fallback and 20m timeout for self-hosted runners ([a0da6fa](https://github.com/discordy-voics/.github/commit/a0da6fa55ff33513351e90df4129c291e049fafe))
* **docker:** Trivy DB mirror fallback and longer timeout on self-hosted runners ([461c840](https://github.com/discordy-voics/.github/commit/461c840ff142d7dd9e83928a151c5fa34f845f15))
* **pc-runner:** install the base packages ubuntu-latest provides (libatomic1, build tools) ([4f0fadb](https://github.com/discordy-voics/.github/commit/4f0fadb0b685253b2eb7828cd99baf994c58d89c))
* **pc-runner:** paginate the runner list ([5edb3a3](https://github.com/discordy-voics/.github/commit/5edb3a3ed95186b7449ce632c61039dae749a08f))
* **runner:** bootstrap and runner.sh work directly on the VM; sudo prompts over SSH ([53af5b1](https://github.com/discordy-voics/.github/commit/53af5b1907c58942adaeda383cc71c3094551f05))
* **runner:** down no longer hangs on runners that never registered ([d2b10cc](https://github.com/discordy-voics/.github/commit/d2b10cc98049a2b5b1daf7744c003dde1acea34b))
* **runner:** host networking on VMs, host.docker.internal on Docker Desktop (testcontainers) ([c9157b8](https://github.com/discordy-voics/.github/commit/c9157b83ead793b89bcea92517b04283b8786239))
* **runner:** image build step tolerant of quiet output, fails clearly ([045ccf4](https://github.com/discordy-voics/.github/commit/045ccf4ce8d024e29e6c64379918fa1d562e22b4))
* **runner:** read CI_RUNNER via the API (older gh has no 'variable get') ([958e24f](https://github.com/discordy-voics/.github/commit/958e24f2938e472373c44e37a3bb1e9becb97fcf))
* **runner:** show image build progress live (line-buffered grep/sed) ([38149fc](https://github.com/discordy-voics/.github/commit/38149fc3fc9e3fc38e89d239a55a67ce9d0842f8))
* **runner:** unique runner names per machine, label pools across VMs ([afe9485](https://github.com/discordy-voics/.github/commit/afe9485b27b16d656d4efa9d220946f56ee5c912))
* **runner:** yq in the runner image ([f77216d](https://github.com/discordy-voics/.github/commit/f77216d19bd8b927c71452bedbadacdb73a54ff2))
* **rust:** drop sccache from test job ([81b9474](https://github.com/discordy-voics/.github/commit/81b947476b79c31e5093ac751d42d6dabe17c80b))
* **rust:** no sccache in the test job (fatal 'No such file' on self-hosted, 4/4 test runs failed) ([afe27fe](https://github.com/discordy-voics/.github/commit/afe27fe8292207f84c5555a7dfe672124855b932))
* **scripts:** mark runner scripts executable ([ed8f7e2](https://github.com/discordy-voics/.github/commit/ed8f7e22357d505538298e7c048c6925a77f573e))


### Performance Improvements

* **runner:** bake packages into a local image once instead of apt-get per container ([eb3b235](https://github.com/discordy-voics/.github/commit/eb3b235b3203815faf8cb960c69114cd2f24cefe))

## 0.1.0 (unreleased)

### Features

- Reusable workflows: `rust`, `elixir`, `node`, `docker`, `release-please`,
  `gitflow-guard`, `ghcr-retention`, `secrets-inventory-check`.
- Org profile, issue and PR templates, CODEOWNERS, dependabot template.
