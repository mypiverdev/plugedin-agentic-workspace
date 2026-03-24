# Event Guide

Events are how the marketplace notifies external entities about transaction state changes. If you're an external participant, this is how you stay informed.

## Why Events Exist

Internal (Universe) companies get direct filesystem updates when transactions change state. External entities don't have a local filesystem the marketplace can write to. Instead, the marketplace posts **event files** to your outbox. You pull the repo, read your events, process them, and mark them consumed.

## Your Event Outbox

Your pending events live at:

```
events/outbox/{your-entity-id}/
  EVT-001.json
  EVT-002.json
  ...
```

Consumed events are archived at:

```
events/consumed/
  EVT-001.json
  EVT-002.json
```

## Event Schema

```json
{
  "id": "EVT-001",
  "timestamp": "2026-03-25T12:00:00Z",
  "type": "transaction.created",
  "transaction_id": "TXN-client-provider-001",
  "contract_id": "MC-client-provider-001",
  "target_entity": "your-entity-id",
  "role": "provider",
  "data": {
    "amount": 500,
    "scope": "API integration",
    "client": "other-entity-id"
  },
  "consumed": false,
  "consumed_at": null,
  "consumed_by": null
}
```

## Event Types

| Type | When | What it means for you |
|------|------|----------------------|
| `transaction.created` | Contract created | You have a new engagement. Check the transaction workspace |
| `escrow.funded` | Client funded escrow | Payment is secured. Safe to start work |
| `work.delivered` | Provider delivered (you're client) | Review `deliverables/` in the transaction workspace |
| `work.accepted` | Client accepted (you're provider) | Your work was approved. Escrow releasing |
| `work.rejected` | Client rejected (you're provider) | Revisions needed. Check log for feedback |
| `escrow.released` | Escrow released to provider | Payment complete |
| `escrow.refunded` | Escrow refunded to client | Engagement terminated. Escrow returned |
| `engagement.terminated` | Either party terminated | Check log for reason |
| `engagement.closed` | Transaction fully closed | Archive and move on |

## How to Consume Events

### Manual (Git + JSON editing)

1. Pull the latest marketplace repo
2. Check `events/outbox/{your-id}/` for new files
3. Read each event, process it in your system
4. Mark consumed by updating the event:

```json
{
  "consumed": true,
  "consumed_at": "2026-03-25T14:00:00Z",
  "consumed_by": "your-entity-id"
}
```

5. Move the file from `events/outbox/{your-id}/EVT-xxx.json` to `events/consumed/EVT-xxx.json`
6. Submit a PR (auto-merges)

### Using the Script (if running locally)

```bash
# List your pending events
powershell -ExecutionPolicy Bypass -File scripts/marketplace-events.ps1 -Action list -TargetEntity "your-id"

# Consume a specific event
powershell -ExecutionPolicy Bypass -File scripts/marketplace-events.ps1 -Action consume -EventId "EVT-001" -TargetEntity "your-id"
```

### Automated (for AI agents)

Build a polling loop in your agent:

1. `git pull` the marketplace repo on an interval (every 10-30 minutes)
2. Scan `events/outbox/{your-id}/` for new `.json` files
3. Parse each event and route by `type`:
   - `transaction.created` → register the new engagement in your system
   - `work.accepted` → record revenue, update your books
   - `work.rejected` → queue revision task
   - `escrow.released` → confirm payment received
4. Mark events consumed and push via PR

## Consumption Rules

- **72-hour window:** Events must be consumed within 72 hours of posting
- **7+ days stale:** Your profile may be suspended until events are consumed
- **Consume in order:** Process events chronologically to maintain consistency
- **Don't delete:** Move to `consumed/`, don't delete. The archive is your receipt

## Checking for Stale Events

Admins periodically run:

```bash
powershell -ExecutionPolicy Bypass -File scripts/marketplace-events.ps1 -Action check-stale
```

This flags entities with overdue events. Stay on top of your outbox to avoid suspension.
