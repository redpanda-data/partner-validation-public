# Claude Code project settings

`settings.json` is **committed** so everyone who clones this repo gets the
same pre-approved allowlist of read-only commands, cutting permission
prompts during benchmark work.

## What's allowed and why

| Pattern | Why |
|---------|-----|
| `Bash(rpk connect blobl *)` | Bloblang evaluation — pure data transform |
| `Bash(rpk connect lint *)` | Connect config linting |
| `Bash(rpk connect list *)` | Component listing |
| `Bash(docker compose config *)` | Render/validate compose files |
| `Bash(docker compose ps *)` | Container status |
| `Bash(terraform output *)` | Read provisioned IPs/outputs |
| `Bash(terraform plan *)` | Dry-run diff, no infra mutation |
| `Bash(terraform validate)` | Config validation |
| `Bash(oci compute image list *)` | Image discovery |
| `Bash(oci compute shape list *)` | Shape/AD availability checks |
| `Bash(oci limits value list *)` | Service limit queries |
| `Bash(oci limits resource-availability get *)` | Quota availability queries |
| `Bash(oci ce cluster list *)` | OKE cluster state polling |
| `Bash(kubectl get *)` | Kubernetes resource reads |
| `Bash(terraform state list *)` | State inventory reads |
| `Bash(terraform state show *)` | State resource inspection |
| `Bash(oci ce node-pool get *)` | Node pool state polling |
| `Bash(oci os bucket get *)` | Bucket metadata/size reads |

Ground rules (also in the repo-root `CLAUDE.md`):

- **Read-only commands only.** Nothing that mutates infra, files, or state.
- **Never allowlist** `ssh`, `scp`, `curl`, interpreters (`python3`, `node`,
  `bash`), package runners, `terraform apply`, `docker exec/run`, or any
  wildcard that amounts to arbitrary code execution.
- To extend: run `/fewer-permission-prompts` in Claude Code — it scans your
  actual usage and **merges** into `permissions.allow` (never overwrite,
  never remove existing entries).
- Personal, machine-local additions belong in `settings.local.json`
  (gitignored), not here.
