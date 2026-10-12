---
name: adr
description: Create an Architecture Decision Record in docs/adr/ for a technical decision in this project (choosing a CNI, VPN, secrets manager, DR approach, Kubernetes distribution, ...). Use when the user asks to record, document or write up a decision, or runs /adr.
---

# Write an ADR

ADRs capture *why* a choice was made. They feed the architecture (Workshop) part of the research report, so keep them factual and sourced.

1. Find the next number: list `docs/adr/` (create it if missing). Files are named `NNNN-kebab-case-title.md`, starting at `0001`.
2. Take the decision, the options considered and the deciding factors from the conversation. Ask only for what is missing.
3. Write the file from the template below. Status is `Proposed` unless the user says it is decided. Use today's date.
4. Add a row to `docs/adr/README.md` (create it with a `# Architecture Decision Records` heading and a `| # | Title | Status | Date |` table if missing).
5. Reply with the file path and a 2–3 line summary.

## Template

```markdown
# NNNN. <Title>

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD
- Related: <other ADRs, docs, issues>

## Context

What problem or requirement forces this decision? Quote the project plan's requirements where relevant.

## Options considered

### Option A — <name>
- Pros:
- Cons:

### Option B — <name>
- Pros:
- Cons:

## Decision

What was chosen, in one or two sentences.

## Consequences

What becomes easier, what becomes harder, what has to happen next, and how it will be validated in the lab.

## Sources

- <URL> (accessed YYYY-MM-DD)
```
