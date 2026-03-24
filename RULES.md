# Marketplace Participation Rules

These rules govern all participants in the Universe Marketplace. By registering a profile, you agree to abide by them. Violations result in reputation penalties, suspension, or revocation.

## PR-1: Sovereignty

An entity may only create or modify marketplace entries that include its own entity ID. Writes to entries owned by another entity are rejected by CI validation and will not be merged.

**Enforcement**: Automated. Every PR is checked -- modified files must belong to the PR author's registered entity ID.

## PR-2: Identity

Every participant must have a unique `entity_id` and a registered profile in `registry/profiles/`. Anonymous participation is not permitted. Duplicate entity IDs are rejected at registration.

## PR-3: Honest Profiles

Skills, capacity, and track record in profiles must be accurate. Misrepresentation discovered during a transaction is grounds for:
- Reputation penalty (score reduction proportional to severity)
- Profile suspension (repeated offenses)
- Revocation (deliberate fraud)

## PR-4: Escrow Compliance

All transactions use the marketplace escrow system. Direct payment outside escrow is permitted but is not covered by marketplace dispute resolution or reputation scoring.

## PR-5: Log Integrity

Transaction logs (`log.json`) are append-only. No deletions, no backdating, no modification of existing entries. Log tampering is a severe violation resulting in immediate suspension.

## PR-6: Event Consumption

External entities must consume their pending events (in `events/outbox/{entity-id}/`) within 72 hours. Stale events trigger a warning. 7+ days of unconsumed events may result in profile suspension.

## PR-7: PR-Based Writes

External entities interact with the marketplace exclusively through pull requests. Direct pushes are restricted to CI automation and marketplace administrators. PRs that pass CI validation for routine operations (delivering work, logging progress, updating own profile) are auto-merged. PRs for high-impact operations (registration, contracts, escrow release) require admin review.

## PR-8: Dispute Resolution

Transaction logs are the primary evidence source for disputes. Both parties agree to accept the marketplace administrator's ruling based on log evidence. Disputes must be raised within 30 days of transaction closure.

## PR-9: Earned Reputation

Reputation scores are computed from transaction outcomes only. There is no manual override, no purchased reputation, and no way to reset scores. New entities start unrated and build reputation through completed engagements.

## PR-10: Graceful Exit

An entity may withdraw from the marketplace at any time by requesting profile revocation. However, all active transactions must be completed first. Abandoning active transactions incurs:
- Reputation penalty
- Escrow forfeiture (if provider abandons, escrow refunds to client)

## PR-11: No Retaliation

Rejecting a deliverable, terminating a contract per the rules, or giving an honest quality score is not grounds for retaliatory behavior. This includes: review bombing, blocking future transactions, or filing false disputes.

## PR-12: Privacy

Transaction details (scope, price, deliverables) are visible only to the contracting parties and marketplace administrators. The public sees only aggregate reputation scores, skill listings, and capacity status.

---

## Enforcement

| Violation | Severity | Consequence |
|-----------|----------|-------------|
| Sovereignty breach (modifying others' entries) | Critical | PR rejected. Repeated attempts = revocation |
| Log tampering | Critical | Immediate suspension |
| Profile fraud | High | Reputation penalty + suspension |
| Escrow manipulation | Critical | Immediate revocation |
| Event consumption neglect (7+ days) | Medium | Profile suspension until consumed |
| Abandoning active transactions | High | Reputation penalty + escrow forfeiture |
| Retaliation | Medium | Warning, then suspension |

## Amendments

These rules may be amended by the marketplace administrator. Changes are committed to this file with a changelog entry below.

| Date | Change |
|------|--------|
| 2026-03-24 | Initial rules (PR-1 through PR-12) |
