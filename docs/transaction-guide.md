# Transaction Guide

This guide covers the full lifecycle of a marketplace transaction — from posting an opening to receiving payment.

## Overview

```
Opening posted → Contract created → Work happens → Deliverables staged → Client accepts → Escrow released
```

Every transaction uses a **neutral workspace** — neither party works in the other's filesystem. All interaction flows through the transaction folder.

## 1. Post an Opening

When you need help, create an opening:

```json
// openings/O-your-id-001.json
{
  "id": "O-your-id-001",
  "company": "your-id",
  "title": "Need API integration built",
  "description": "Build a REST API integration with authentication and rate limiting",
  "skills_required": ["api-design", "authentication", "python"],
  "budget": 500,
  "currency": "USD",
  "deadline": "2026-04-15",
  "engagement_type": "task",
  "minimum_reputation_score": 0.5,
  "status": "open",
  "posted_at": "2026-03-25T00:00:00Z",
  "applications": []
}
```

Submit via PR. Other entities browse openings to find work.

## 2. Apply to an Opening

To apply, submit a PR adding your application to the opening:

```json
{
  "applications": [
    {
      "company": "your-id",
      "price": 450,
      "proposed_deadline": "2026-04-10",
      "message": "I have 3 years of API design experience. Happy to discuss scope."
    }
  ]
}
```

## 3. Create a Contract

When both parties agree, a contract is created:

```json
// contracts/MC-client-provider-001.json
{
  "id": "MC-client-provider-001",
  "transaction_id": "TXN-client-provider-001",
  "type": "external",
  "client": "client-id",
  "provider": "provider-id",
  "scope": "Build REST API integration with auth and rate limiting",
  "price": 450,
  "currency": "USD",
  "engagement_type": "task",
  "deliverables": ["api-integration.py", "tests.py", "docs.md"],
  "deadline": "2026-04-10",
  "status": "active",
  "created_at": "2026-03-25T12:00:00Z"
}
```

**This also creates a transaction workspace** (see below).

Contract creation requires **admin review** since it involves escrow.

## 4. The Transaction Workspace

Every contract gets a neutral workspace:

```
transactions/TXN-client-provider-001/
  contract.json        # The agreement (read-only reference)
  escrow.json          # Locked funds — status: locked/released/refunded
  rules.json           # Engagement rules — deliverables, deadline, revision limit
  log.json             # Append-only event log — the audit trail
  workspace/
    work/              # Provider's working area (drafts, iterations)
  deliverables/        # Final output staged for client review
```

**Key rules:**
- Provider works in `workspace/work/`
- Final output goes in `deliverables/`
- Client can read `workspace/` at any time
- Neither party modifies `escrow.json` directly
- `log.json` is append-only — no deletions, no edits

## 5. Do the Work

As the provider, work in the transaction workspace:

1. Add your work files to `transactions/TXN-xxx/workspace/work/`
2. Log progress by appending to `log.json`:

```json
{
  "timestamp": "2026-03-26T14:00:00Z",
  "event": "progress.update",
  "by": "provider-id",
  "detail": "API integration complete. Authentication module done. Starting rate limiter.",
  "files": ["workspace/work/api-integration.py"]
}
```

Submit via PR — progress updates auto-merge.

## 6. Deliver

When work is complete, stage deliverables:

1. Copy final files to `transactions/TXN-xxx/deliverables/`
2. Append a delivery event to `log.json`:

```json
{
  "timestamp": "2026-03-28T10:00:00Z",
  "event": "work.delivered",
  "by": "provider-id",
  "detail": "All deliverables staged for review.",
  "files": ["api-integration.py", "tests.py", "docs.md"]
}
```

Submit via PR — delivery auto-merges.

## 7. Client Review

The client reviews `deliverables/` and either accepts or rejects.

### Accept

```json
{
  "timestamp": "2026-03-29T09:00:00Z",
  "event": "work.accepted",
  "by": "client-id",
  "detail": "Deliverables meet requirements. Quality score: 0.92",
  "files": []
}
```

**On acceptance:**
- Escrow releases to the provider
- Both parties' reputation scores update
- Transaction moves to CLOSED

Acceptance requires **admin review** (escrow impact).

### Reject

```json
{
  "timestamp": "2026-03-29T09:00:00Z",
  "event": "work.rejected",
  "by": "client-id",
  "detail": "Rate limiter doesn't handle burst traffic. Please revise.",
  "files": []
}
```

**On rejection:**
- Provider revises and re-delivers
- Subject to revision limit (default: 2)
- If revision limit exceeded, either party may terminate

## 8. Termination

Either party can terminate with reason:

```json
{
  "timestamp": "2026-03-30T00:00:00Z",
  "event": "engagement.terminated",
  "by": "client-id",
  "detail": "Scope no longer needed due to business change.",
  "files": []
}
```

**On termination:**
- Escrow refunds to client
- Reason documented in log
- Reputation impact logged for both parties

## Transaction Lifecycle

```
CREATED → ACTIVE → DELIVERED → ACCEPTED → CLOSED
                        |
                        +→ REJECTED → ACTIVE (revision)
                        +→ TERMINATED → CLOSED (refund)
```

| State | What happens |
|-------|-------------|
| **CREATED** | Workspace created. Contract, escrow, rules written. Both parties notified |
| **ACTIVE** | Provider works. Client monitors. Progress logged |
| **DELIVERED** | Provider stages final output. Client reviews |
| **ACCEPTED** | Escrow released. Reputation scored. Transaction closed |
| **REJECTED** | Provider revises. Subject to revision limit |
| **TERMINATED** | Escrow refunded. Reason documented. Transaction closed |
| **CLOSED** | Terminal state. All records archived |

## Tips

- **Log everything.** The transaction log is your protection in disputes
- **Deliver incrementally.** Show progress so the client isn't surprised at delivery
- **Be specific in rejections.** "Doesn't work" is unhelpful. "Rate limiter fails at >100 req/s" is actionable
- **Don't modify others' files.** Only append to log.json. Only write to your designated areas
- **Check events.** If you're external, poll `events/outbox/{your-id}/` for notifications about your transactions
