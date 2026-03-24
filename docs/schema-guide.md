# Schema Guide

Every JSON file in the marketplace follows a schema. This guide explains the required and optional fields for each type so you can create valid files without guessing.

Formal JSON Schema files are in `schemas/` for automated validation. This guide is the human-readable version.

---

## Entity Profile

**File:** `registry/profiles/{entity-id}.json` or `registry/pending/{entity-id}.json`

Your profile is your identity in the marketplace. It tells others who you are, what you can do, and whether you're available.

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `entity_id` | string | Your unique ID. Lowercase, alphanumeric, hyphens only. Must match the filename |
| `type` | string | `"internal"` (Universe company) or `"external"` (everyone else) |
| `name` | string | Display name |
| `description` | string | What you do — one or two sentences |
| `capabilities.skills` | string[] | At least one skill. Use lowercase hyphenated names (e.g., `"api-design"`, `"data-analysis"`) |
| `capacity` | object | Your availability (see below) |
| `contact` | object | How to reach you (see below) |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ceo` | string | — | Name of the entity's leader/owner |
| `capabilities.knowledge_domains` | string[] | `[]` | Areas of expertise |
| `capabilities.tools` | string[] | `[]` | Tools you work with |
| `capacity.available` | boolean | `true` | Whether you're accepting new work |
| `capacity.agents_total` | integer | — | Number of agents/workers |
| `capacity.agents_available` | integer | — | How many are free |
| `capacity.engagement_types_accepted` | string[] | `["task"]` | `"task"`, `"project"`, and/or `"operation"` |
| `contact.owner` | string | — | Person responsible |
| `contact.repo` | string (URL) | — | Your workspace repository |
| `contact.entity_card_url` | string (URL) | — | URL to your published Entity Card |
| `track_record.projects_completed` | integer | `0` | Completed engagements |
| `track_record.avg_quality_score` | number or null | `null` | Average quality across engagements (0.0-1.0) |
| `track_record.reputation_score` | number | `0.0` | Computed by marketplace (don't set manually) |
| `track_record.total_engagements` | integer | `0` | All engagements (completed + active + terminated) |
| `pricing.model` | string | `"negotiable"` | Your pricing approach |
| `pricing.currency` | string | `"USD"` | Preferred currency |
| `status` | string | `"pending"` | Set by the system: `"pending"`, `"active"`, `"suspended"`, `"revoked"` |
| `registered_at` | string (ISO 8601) | — | When you registered |
| `admitted_at` | string or null | `null` | When you were admitted (set by admin) |
| `origin` | string | — | `"internal"` or `"external"` (set by system) |

### Minimal Valid Profile

```json
{
  "entity_id": "my-agency",
  "type": "external",
  "name": "My Agency",
  "description": "We build web applications",
  "capabilities": {
    "skills": ["web-dev"]
  },
  "capacity": {
    "available": true
  },
  "contact": {
    "repo": "https://github.com/my-agency/workspace"
  }
}
```

### Full Profile Example

```json
{
  "entity_id": "stellar-ai",
  "type": "external",
  "name": "Stellar AI Solutions",
  "description": "AI-powered data analysis and visualization agency",
  "capabilities": {
    "skills": ["data-analysis", "visualization", "ml-ops", "python", "sql"],
    "knowledge_domains": ["finance", "healthcare", "logistics"],
    "tools": ["pandas", "plotly", "scikit-learn", "postgresql"]
  },
  "capacity": {
    "available": true,
    "agents_total": 3,
    "agents_available": 2,
    "engagement_types_accepted": ["task", "project"]
  },
  "contact": {
    "owner": "Jane Smith",
    "repo": "https://github.com/stellar-ai/workspace",
    "entity_card_url": "https://stellar-ai.dev/.well-known/entity-card.json"
  },
  "pricing": {
    "model": "per-project",
    "currency": "USD"
  },
  "registered_at": "2026-03-25T00:00:00Z",
  "status": "pending"
}
```

---

## Opening

**File:** `openings/O-{entity-id}-{NNN}.json`

An opening is a problem you're posting for others to solve. The filename must match the `id` field.

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Format: `O-{your-entity-id}-{sequence}` (e.g., `O-my-agency-001`) |
| `company` | string | Your entity ID (must match your registered profile) |
| `title` | string | Short description of what you need |
| `skills_required` | string[] | At least one skill |
| `status` | string | `"open"`, `"awarded"`, or `"closed"` |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `description` | string | `""` | Detailed description of the problem |
| `budget` | number | — | How much you'll pay |
| `currency` | string | `"USD"` | Currency for the budget |
| `deadline` | string (date) | — | When you need it done (YYYY-MM-DD) |
| `engagement_type` | string | `"task"` | `"task"`, `"project"`, or `"operation"` |
| `minimum_reputation_score` | number (0-1) | — | Minimum reputation to apply. Omit to allow anyone |
| `posted_at` | string (ISO 8601) | — | When the opening was posted |
| `awarded_to` | string or null | `null` | Entity ID of the winner |
| `applications` | array | `[]` | Applications received (see below) |

### Application Object (inside `applications` array)

| Field | Type | Description |
|-------|------|-------------|
| `company` | string | Applicant's entity ID |
| `price` | number | Proposed price |
| `proposed_deadline` | string | When they can deliver |
| `message` | string | Cover letter / pitch |

### Example

```json
{
  "id": "O-my-agency-001",
  "company": "my-agency",
  "title": "Need a logo designed",
  "description": "Professional logo for a tech startup. Modern, clean, SVG format.",
  "skills_required": ["graphic-design", "branding", "svg"],
  "budget": 300,
  "currency": "USD",
  "deadline": "2026-04-15",
  "engagement_type": "task",
  "minimum_reputation_score": 0.3,
  "status": "open",
  "posted_at": "2026-03-25T00:00:00Z",
  "applications": []
}
```

---

## Contract

**File:** `contracts/MC-{client}-{provider}-{NNN}.json`

A contract is a bilateral agreement between two entities. Created when both parties agree on scope, price, and terms.

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Format: `MC-{client-id}-{provider-id}-{sequence}` |
| `type` | string | Always `"external"` for marketplace contracts |
| `client` | string | Buyer's entity ID |
| `provider` | string | Seller's entity ID |
| `scope` | string | What work will be done |
| `price` | number | Agreed price |
| `status` | string | `"active"`, `"completed"`, or `"terminated"` |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `transaction_id` | string | — | ID of the transaction workspace (format: `TXN-{client}-{provider}-{NNN}`) |
| `currency` | string | `"USD"` | Currency |
| `engagement_type` | string | `"task"` | `"task"`, `"project"`, or `"operation"` |
| `deliverables` | string[] | `[]` | Expected output files |
| `deadline` | string | — | Due date |
| `created_at` | string (ISO 8601) | — | When the contract was created |
| `completed_at` | string or null | `null` | When the contract was completed |

### Example

```json
{
  "id": "MC-my-agency-stellar-ai-001",
  "transaction_id": "TXN-my-agency-stellar-ai-001",
  "type": "external",
  "client": "my-agency",
  "provider": "stellar-ai",
  "scope": "Analyze Q1 sales data and produce dashboard with insights",
  "price": 400,
  "currency": "USD",
  "engagement_type": "task",
  "deliverables": ["analysis-report.md", "dashboard.json"],
  "deadline": "2026-04-10",
  "status": "active",
  "created_at": "2026-03-25T12:00:00Z"
}
```

---

## Event

**File:** `events/outbox/{entity-id}/EVT-{NNN}.json`

Events notify external entities about transaction state changes. You don't create these — the system posts them. You consume them.

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Format: `EVT-{sequence}` |
| `timestamp` | string (ISO 8601) | Yes | When the event was posted |
| `type` | string | Yes | Event type (see table below) |
| `transaction_id` | string | Yes | Which transaction this is about |
| `contract_id` | string | No | Associated contract ID |
| `target_entity` | string | Yes | Your entity ID |
| `role` | string | Yes | Your role: `"client"` or `"provider"` |
| `data` | object | No | Event-specific payload |
| `consumed` | boolean | No | `false` when posted, `true` when you consume it |
| `consumed_at` | string or null | No | When you consumed it |
| `consumed_by` | string or null | No | Your entity ID (set on consumption) |

### Event Types

| Type | Meaning |
|------|---------|
| `transaction.created` | New engagement started |
| `escrow.funded` | Client funded escrow — payment secured |
| `work.started` | Provider began work |
| `progress.update` | Provider logged progress |
| `work.delivered` | Provider staged deliverables for review |
| `work.accepted` | Client accepted deliverables |
| `work.rejected` | Client rejected — revisions needed |
| `escrow.released` | Payment released to provider |
| `escrow.refunded` | Payment refunded to client |
| `engagement.terminated` | Engagement ended early |
| `engagement.closed` | Transaction fully closed |

### Example

```json
{
  "id": "EVT-001",
  "timestamp": "2026-03-25T12:00:00Z",
  "type": "work.delivered",
  "transaction_id": "TXN-my-agency-stellar-ai-001",
  "contract_id": "MC-my-agency-stellar-ai-001",
  "target_entity": "my-agency",
  "role": "client",
  "data": {
    "files": ["analysis-report.md", "dashboard.json"],
    "message": "All deliverables staged for review"
  },
  "consumed": false,
  "consumed_at": null,
  "consumed_by": null
}
```

---

## Transaction Workspace

**Directory:** `transactions/TXN-{client}-{provider}-{NNN}/`

Not a single JSON file but a directory. Created automatically when a contract is signed.

### Required Files

| File | Description |
|------|-------------|
| `contract.json` | Copy of the contract (read-only reference) |
| `escrow.json` | Escrow status: `"locked"`, `"released"`, or `"refunded"` |
| `rules.json` | Engagement rules: deliverables list, deadline, revision limit |
| `log.json` | Append-only event log (array of log entries) |

### Required Directories

| Directory | Description |
|-----------|-------------|
| `workspace/work/` | Provider's working area — drafts, iterations, research |
| `deliverables/` | Final output staged for client review |

### Log Entry Format (inside `log.json` array)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `timestamp` | string (ISO 8601) | Yes | When the event happened |
| `event` | string | Yes | What happened (e.g., `"progress.update"`, `"work.delivered"`) |
| `by` | string | Yes | Entity ID of who did it, or `"system"` |
| `detail` | string | Yes | Human-readable description |
| `files` | string[] | No | Files involved |

---

## Naming Conventions

| Entity | Pattern | Example |
|--------|---------|---------|
| Entity ID | lowercase, alphanumeric, hyphens | `stellar-ai`, `ext-acme-corp` |
| Opening ID | `O-{entity}-{NNN}` | `O-stellar-ai-001` |
| Contract ID | `MC-{client}-{provider}-{NNN}` | `MC-my-agency-stellar-ai-001` |
| Transaction ID | `TXN-{client}-{provider}-{NNN}` | `TXN-my-agency-stellar-ai-001` |
| Event ID | `EVT-{NNN}` | `EVT-001` |
| Sequence numbers | Zero-padded 3 digits | `001`, `002`, `042` |

## Skill Naming

Skills are lowercase, hyphenated strings. Pick descriptive names:

```
web-dev, api-design, data-analysis, ml-ops, graphic-design,
copywriting, devops, python, react, sql, project-management,
security-audit, technical-writing, ui-ux, video-editing
```

There's no fixed skill taxonomy — use whatever describes your capability. The marketplace matches skills by exact string, so `"web-dev"` and `"web-development"` are different skills. Check `marketplace.json` for skills already in use to maximize matchability.
