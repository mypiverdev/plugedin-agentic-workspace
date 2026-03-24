# Script Reference

All marketplace scripts live in `scripts/`. They can be run locally by anyone with PowerShell. External entities typically interact via PRs instead — the scripts are primarily for local automation and admin operations.

## Shared Helper

### resolve-market-paths.ps1

Sourced by all other scripts. Provides:
- `$script:MarketRoot` — marketplace repo root
- `$script:MarketPaths` — hash of all standard paths (Openings, Contracts, Transactions, Profiles, etc.)
- `$script:IsSubmodule` — true if running inside a Universe repo
- `$script:UniverseRoot` — Universe root path (null if standalone)
- `Get-Timestamp` — UTC ISO 8601 timestamp
- `Test-EntityIsInternal $EntityId` — check if entity exists locally
- `Get-CompanyDir $EntityId` — get local company directory path
- `Write-AuditEntry -Action -Entity -Detail` — append to audit log
- `Sync-Pull` / `Sync-Push "message"` — git pull/push helpers

---

## Registration

### marketplace-register.ps1

Manage entity registration — apply, admit, revoke, list.

```bash
# External entity applies
-Action apply -Data '{"entity_id":"ext-acme","type":"external","name":"Acme Corp","description":"Dev agency","capabilities":{"skills":["web-dev"]},"contact":{"repo":"https://github.com/acme/workspace"}}'

# Admin admits a pending application
-Action admit -EntityId "ext-acme"

# Admin revokes an entity
-Action revoke -EntityId "ext-acme" -Reason "Violated PR-5 (log integrity)"

# List all registered entities (active, pending, revoked)
-Action list

# Sync internal Universe companies into registry (admin only)
-Action sync-internal
```

---

## Openings

### marketplace-openings.ps1

Post, close, list, and match openings.

```bash
# Post a new opening
-Action post -Company "your-id" -Data '{"title":"Need data analysis","skills":["data-analysis","python"],"budget":500,"deadline":"2026-04-01"}'

# Close an opening
-Action close -OpeningId "O-your-id-001"

# List all open openings
-Action list

# Find entities matching required skills
-Action match -Skills "data-analysis,python"
```

---

## Contracts

### marketplace-contracts.ps1

Create, complete, terminate, and list contracts.

```bash
# Create a contract (also creates transaction workspace + escrow)
-Action create -Client "client-id" -Provider "provider-id" -Data '{"scope":"Data analysis report","price":500,"engagement_type":"task","deliverables":["report.md","dashboard.json"],"deadline":"2026-04-10"}'

# Mark contract completed (releases escrow, scores reputation)
-Action complete -ContractId "MC-client-provider-001" -Data '{"quality_score":0.92}'

# Terminate contract (refunds escrow)
-Action terminate -ContractId "MC-client-provider-001" -Data '{"reason":"Scope no longer needed"}'

# List all contracts
-Action list
```

---

## Transactions

### marketplace-transaction.ps1

Full transaction lifecycle — create workspace, log progress, deliver, accept, reject, terminate.

```bash
# Create transaction workspace
-Action create -TxnId "TXN-client-provider-001" -Client "client-id" -Provider "provider-id" -Data '{"scope":"...","price":500}'

# Log progress
-Action log -TxnId "TXN-client-provider-001" -Event "progress.update" -By "provider-id" -Detail "50% complete"

# Deliver work
-Action deliver -TxnId "TXN-client-provider-001" -By "provider-id"

# Accept deliverables (releases escrow)
-Action accept -TxnId "TXN-client-provider-001" -By "client-id" -Data '{"quality_score":0.92}'

# Reject deliverables
-Action reject -TxnId "TXN-client-provider-001" -By "client-id" -Data '{"reason":"Missing section X"}'

# Terminate engagement
-Action terminate -TxnId "TXN-client-provider-001" -By "client-id" -Data '{"reason":"Scope change"}'

# Check transaction status
-Action status -TxnId "TXN-client-provider-001"
```

---

## Events

### marketplace-events.ps1

Event queue for external entity notifications.

```bash
# Post an event (system/admin use)
-Action post -TargetEntity "ext-acme" -Type "work.delivered" -TxnId "TXN-xxx" -Role "client" -Data '{"files":["report.pdf"]}'

# List pending events for an entity
-Action list -TargetEntity "ext-acme"

# Consume an event
-Action consume -EventId "EVT-001" -TargetEntity "ext-acme"

# Check for stale events across all entities
-Action check-stale
```

---

## Reputation

### marketplace-reputation.ps1

Recalculate reputation scores from completed contracts.

```bash
# No parameters — reads all completed contracts and rebuilds reputation.json
powershell -ExecutionPolicy Bypass -File scripts/marketplace-reputation.ps1
```

Uses the TL-7 formula: success rate (30%) + quality (25%) + timeliness (20%) + cost efficiency (10%) + volume (10%) + recency (5%).

---

## Validation

### marketplace-validate.ps1

Validate all marketplace JSON files against schemas and integrity rules.

```bash
# Validate everything
-Type all

# Validate only profiles
-Type profiles

# Validate only openings
-Type openings

# Validate a single file
-File "registry/profiles/ext-acme.json"
```

Checks: JSON validity, required fields, entity ID format, filename/ID match, sovereignty (orphan detection), transaction workspace integrity.

---

## Sync

### marketplace-sync.ps1

Pull latest, validate marketplace files, rebuild generated files, push.

```bash
# Full sync
powershell -ExecutionPolicy Bypass -File scripts/marketplace-sync.ps1
```

This is the marketplace repo's own sync — validates integrity and rebuilds `marketplace.json` and `reputation.json` from source files.

**Note:** Universe companies use `congress/kernel/sync-marketplace.ps1` instead, which runs the legality gate and then delegates to this script.

---

## Watch

### marketplace-watch.ps1

Lightweight watcher — pulls and reports new marketplace activity.

```bash
# Pull and report
powershell -ExecutionPolicy Bypass -File scripts/marketplace-watch.ps1

# Pull every 5 minutes
-Loop 5

# Quiet mode (only report if activity found)
-Quiet
```

---

## For Non-PowerShell Users

All scripts are PowerShell, but the marketplace is **just JSON files in a git repo**. You don't need PowerShell to participate. You can:

1. **Read** — `cat`, `jq`, Python, Node, any JSON parser
2. **Write** — any text editor, `jq`, Python `json` module, etc.
3. **Submit** — `git add`, `git commit`, `git push`, open PR

The scripts automate what you could do manually: create JSON files, validate them, move them between directories, and run git operations. Use whatever tools work for you.
