# Claude Code in this repo

What `CLAUDE.md` and the `.claude/` folder are, what is already set up here, and how to use agents and skills.

## 1. The mental model

Claude Code is an agent: you describe a task, and it reads files, runs commands and edits code, asking permission for anything risky. Every session starts with **no memory of earlier sessions** — it only knows what it is given. These files are how you give it the project's context once, instead of re-explaining it every time.

| What | Where | Written by | Loaded |
|---|---|---|---|
| Project instructions | `CLAUDE.md` | you (or Claude, when asked) | at the start of every session |
| Settings and permissions | `.claude/settings.json` | you | always enforced |
| Agents and skills | `.claude/agents/`, `.claude/skills/` | you | names and descriptions always; full content only when used |
| Auto memory | `~/.claude/projects/<project>/memory/` | Claude | an index at the start of every session |

## 2. Where everything lives

**Project level — committed, shared with anyone who clones the repo:**

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Project briefing: goals, layout, conventions, rules. Keep it short — it costs context in every session. |
| `.claude/settings.json` | Permissions (allow / ask / deny), hooks, environment variables |
| `.claude/agents/*.md` | Subagents — specialised helpers with their own instructions and tools |
| `.claude/skills/<name>/SKILL.md` | Skills — reusable procedures, also available as `/<name>` |
| `.mcp.json` | MCP servers (external tool connections) for this project |

**Personal — not committed:**

| Path | Purpose |
|---|---|
| `.claude/settings.local.json` | Your own overrides for this repo (gitignored) |
| `~/.claude/CLAUDE.md` | Instructions for all your projects, e.g. "answer briefly", "I use WSL" |
| `~/.claude/settings.json` | Global settings — yours currently sets the model to Opus |
| `~/.claude/agents/`, `~/.claude/skills/` | Agents and skills available in every project |
| `~/.claude/projects/` | Session transcripts (for `/resume`) and auto memory, per project |

When the same setting is in several places, the more specific one wins: local > project > user.

## 3. What is set up in this repo

| File | What it does |
|---|---|
| [CLAUDE.md](../CLAUDE.md) | Project summary, layout, naming and CIDR rules, "no secrets in Git", "ask before touching real clusters" |
| [.claude/settings.json](../.claude/settings.json) | **allow** without prompting: read-only commands (`kubectl get/describe/logs`, `git diff/log`, `yamllint`, `helm template`). **ask** every time: `kubectl apply/delete/edit/exec`, `helm install/upgrade`, `ssh`, `scp`, `git push`. **deny**: reading token files and kubeconfigs, `kubectl get secret(s)` |
| [.claude/agents/security-reviewer.md](../.claude/agents/security-reviewer.md) | Reviews configs and manifests against CIS, NSA/CISA guidance and the project's zero-trust goals. Reports only, never edits. |
| [.claude/agents/research-scout.md](../.claude/agents/research-scout.md) | DOT "Library" research: compares tools from official sources, returns a table, a recommendation and dated sources. Runs on Sonnet, which costs less. |
| [.claude/skills/adr/SKILL.md](../.claude/skills/adr/SKILL.md) | `/adr` — writes an Architecture Decision Record into `docs/adr/` |

> Permission rules are a seatbelt, not a sandbox. `deny Read(./**/agent-token)` blocks the Read tool, but `cat agent-token` goes through Bash, a different tool. The real protection for clusters is giving Claude credentials that *can't* do damage — see section 7.

## 4. Subagents

A subagent is a separate Claude instance with **its own instructions, its own tool list and its own context window**. The main session hands it a task; it works on its own and only its final report comes back.

Why use them:
- **Clean context.** A large web research job or a sweep through many files fills the subagent's context, not your main conversation, which only gets the summary.
- **Consistency.** A reviewer with a fixed checklist and read-only tools gives more repeatable results than an ad-hoc "can you check this".
- **Parallel work.** Several can run at once.

The cost: each one starts cold and re-reads what it needs, so it uses more tokens. Don't use one for a small question.

How to use them:
- Ask by name: *"Use the security-reviewer agent to review rke2-config/"*.
- Claude can also pick one on its own when a task matches the agent's `description` — that's why descriptions say *when* to use the agent.
- `/agents` lists, creates and edits agents. It can generate a first draft from your description.
- Built-in agents exist too: **Explore** (fast read-only search across the codebase), **Plan** (designs an implementation plan) and **general-purpose**.

Anatomy of an agent file:

```markdown
---
name: security-reviewer          # how you refer to it
description: Reviews ... Use after infrastructure files change ...   # when to use it
tools: Read, Grep, Glob, Bash    # optional: limit tools (omit = all tools)
model: sonnet                    # optional: sonnet / opus / haiku (omit = same as main session)
---

The system prompt: who it is, how to work, what to return.
```

## 5. Skills

A skill is a folder with a `SKILL.md` (plus optional scripts and templates). Only its name and description sit in context until it is used, so you can have many without slowing anything down. Run one with `/<name>` (e.g. `/adr`), or let Claude load it when a task matches its description.

Agent or skill? An **agent** is a *worker* with its own context — use it to delegate a whole task. A **skill** is a *procedure* the current session follows — use it for repeatable steps like "write an ADR in our format".

Older docs mention `.claude/commands/*.md` for custom slash commands. That still works; skills are the newer form and can do more.

## 6. Hooks: automation that always runs

`CLAUDE.md` is guidance: Claude usually follows it, but nothing enforces it. **Hooks** are enforced: shell commands the harness runs on events such as `PreToolUse`, `PostToolUse`, `Stop` or `SessionStart`.

Example, not enabled here: lint every YAML file right after Claude edits it. It needs `yamllint` and `jq` (`sudo apt install yamllint jq`). Add it to `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "f=$(jq -r '.tool_input.file_path'); case \"$f\" in *.yaml|*.yml) yamllint -d relaxed \"$f\" >&2 || exit 2;; esac"
          }
        ]
      }
    ]
  }
}
```

The hook receives the tool call as JSON on stdin. Exit code 2 sends its stderr back to Claude, which then fixes the problem. `/hooks` shows what is configured.

## 7. MCP servers and cluster access

MCP (Model Context Protocol) connects Claude to external systems — GitHub, Grafana, Kubernetes, Proxmox and so on. Add servers with `claude mcp add`, or in `.mcp.json` for the whole project. Every MCP server is code with access to whatever credentials you give it, so treat it like any other dependency.

For this project, once the clusters exist, let Claude *look* at them through a kubeconfig bound to Kubernetes' built-in **`view`** role. It can read almost everything except Secrets and can change nothing:

```bash
# as cluster admin
kubectl -n kube-system create serviceaccount claude-view
kubectl create clusterrolebinding claude-view --clusterrole=view --serviceaccount=kube-system:claude-view
TOKEN=$(kubectl -n kube-system create token claude-view --duration=8h)

# build a kubeconfig that carries only that token
cp ~/.kube/homelab.yaml ~/.kube/homelab-claude-view.yaml
KC=~/.kube/homelab-claude-view.yaml
kubectl --kubeconfig "$KC" config unset users.default.client-certificate-data
kubectl --kubeconfig "$KC" config unset users.default.client-key-data
kubectl --kubeconfig "$KC" config set-credentials default --token="$TOKEN"
kubectl --kubeconfig "$KC" auth can-i delete pods -A    # must print "no"
```

Then point Claude at it in `.claude/settings.local.json` (personal, gitignored):

```json
{ "env": { "KUBECONFIG": "/home/nknez/.kube/homelab-claude-view.yaml" } }
```

Keep the admin kubeconfig for yourself. When Claude proposes a change, it writes the manifest and you apply it.

## 8. Day-to-day workflow

**Permission modes** — `Shift+Tab` cycles through them:
- *default*: asks before edits and non-allowed commands
- *accept edits*: file edits go through, commands still ask
- *plan mode*: read-only — Claude explores and proposes a plan, and changes nothing until you approve. **Use this for anything infrastructure-related.**

**Commands worth knowing:**

| Command | What it does |
|---|---|
| `/init` | Generates a `CLAUDE.md` from the codebase |
| `/memory` | Opens `CLAUDE.md` and memory files for editing |
| `/agents` | Manage subagents |
| `/permissions` | View and change allow / ask / deny rules |
| `/hooks`, `/mcp` | Inspect hooks and MCP servers |
| `/model` | Switch model |
| `/clear` | Fresh conversation (do this between unrelated tasks) |
| `/compact` | Summarise a long conversation to free up context |
| `/resume` | Continue an earlier session |
| `/rewind` (or `Esc Esc`) | Roll back to an earlier point in the conversation and code |
| `/code-review`, `/security-review` | Review the current changes |

**Habits that pay off:**
- One task per session; `/clear` between unrelated ones.
- Reference files with `@`, e.g. `@rke2-config/server.yaml`, to pull them straight into context.
- Ask for a plan before changes with a blast radius; review diffs before committing. Claude commits and pushes only when you ask.
- When Claude gets something about the project wrong, add one line to `CLAUDE.md` — that fixes it for every future session.

## 9. Things to try

1. *"Use the security-reviewer agent to review rke2-config/"*
2. `/adr` *record the decision to use Cilium with kube-proxy replacement on the Homelab cluster*
3. *"Use the research-scout agent to compare WireGuard, NetBird and Headscale for linking Homelab and Netlab, and write it to docs/research/vpn.md"*
4. Two agents in parallel: *"In parallel: research-scout on Talos vs kubeadm for the Netlab cluster, and security-reviewer on rke2-config/"*
5. Create your own agent with `/agents` — for example an `ansible-writer` that turns `prepare-node.sh` into an Ansible role.
