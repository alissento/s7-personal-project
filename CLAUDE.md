# CLAUDE.md

## Project

Semester 7 research project: a secure, multi-site Kubernetes platform for a dummy banking app. Two clusters — Homelab (Poland, Proxmox, RKE2, 3 masters + 2 workers) and Netlab (distribution TBD) — with zero-trust security, GitOps and automated disaster recovery between them. Research follows the DOT framework (Library / Workshop / Lab / Showroom).

- Plan: `docs/Project Plan_v1.pdf` · options and roadmap: `docs/ideas.md` · network plan: `docs/network-plan.md`
- The repo is a deliverable: it is read by coaches, so docs should be clear and sourced.

## Layout

- `ansible/` — node preparation and RKE2 install for Homelab (inventory, roles, playbooks); written step by step with the user
- `docs/` — plan, network plan, ideas, Claude Code guide; ADRs go in `docs/adr/`, research write-ups in `docs/research/`
- `terraform/`, `clusters/`, `platform/`, `apps/` — planned

## Conventions

- IPs, hostnames and domains are examples until the user confirms them. When changing one, update every file in the "Where the values live" table in `docs/network-plan.md`.
- Hostnames: Homelab nodes are `master-NN` / `worker-NN` (as created in Proxmox); Netlab nodes get an `nl-` prefix.
- Pod and service CIDRs must never overlap between sites (Cilium Cluster Mesh).
- RKE2 settings that must match across servers must live in one place only (the Ansible RKE2 role, not written yet).
- Never put secrets in the repo — tokens, keys, kubeconfigs, S3 credentials. RKE2 reads tokens via `token-file`.
- Pin versions (RKE2, charts, images) and note when they were checked.
- Record significant technical decisions as ADRs (`/adr`).

## Working rules

- Ask before anything that changes a real cluster or VM (`kubectl apply/delete/exec`, `helm install/upgrade`, `ssh`, `qm`). Read-only commands are fine.
- Validate before finishing: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" <file>` for YAML (or `yamllint` if installed), `bash -n` for scripts.
- Prefer official docs (docs.rke2.io, docs.cilium.io, kubernetes.io) and link them in docs with the date checked.
