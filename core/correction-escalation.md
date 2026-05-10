# Correction Escalation Protocol

**Version**: 0.1.0
**Status**: Core protocol — loaded by Observer, Writer, and Reader

---

## 1. The Problem

Recording a correction and preventing its recurrence are two different things.

A user logs "skipping research before coding" as a correction. Then logs it again. Then again. After 19 occurrences, the journal has a thorough record of the mistake — and the AI keeps making it because the corrections are stored passively. The journal becomes a graveyard of good intentions.

Logging is necessary. It is not sufficient.

Scribe bridges the gap between "we wrote it down" and "it stopped happening" through systematic escalation: detection, monitoring, intervention, and resolution tracking.

---

## 2. Correction Tracker Format

The `correction-tracker.json` file lives in the user's data directory alongside the journal. It is the single source of truth for correction patterns and their escalation state.

```json
{
  "schema_version": 1,
  "patterns": {
    "pattern-slug": {
      "description": "Human-readable description of the pattern",
      "occurrences": [
        {
          "entry_id": "uuid",
          "date": "ISO-8601",
          "context": "What specifically happened this time"
        }
      ],
      "level": "observation | guardrail | critical",
      "escalated_at": "ISO-8601 or null",
      "resolved": false,
      "resolved_at": null,
      "resolution_method": null
    }
  },
  "last_updated": "ISO-8601"
}
```

### Field Reference

| Field | Type | Purpose |
|---|---|---|
| `schema_version` | integer | Tracker format version (additive-only, matches project convention) |
| `patterns` | object | Keyed by slug — lowercase, hyphenated, descriptive |
| `description` | string | Plain language description of what keeps going wrong |
| `occurrences` | array | Every instance, linked to its journal entry by `entry_id` |
| `level` | enum | Current escalation level: `observation`, `guardrail`, or `critical` |
| `escalated_at` | ISO-8601 or null | When the pattern last changed escalation level |
| `resolved` | boolean | Whether the pattern is considered resolved |
| `resolved_at` | ISO-8601 or null | When resolution was recorded |
| `resolution_method` | string or null | What fixed it (skill created, CLAUDE.md rule, structural change, etc.) |
| `last_updated` | ISO-8601 | Last modification timestamp for the entire tracker file |

### Slug Convention

Pattern slugs should be stable, descriptive, and lowercase-hyphenated:
- `skipping-file-reads` (not `skip_reads` or `didn't read files`)
- `unpaginated-supabase-queries` (not `pagination` or `supabase-bug`)
- `untested-code-shipped` (not `testing` or `no-tests`)

Once a slug is created, it does not change. This ensures occurrence tracking remains linked across the pattern's lifetime.

---

## 3. Escalation Levels

| Occurrences | Level | Behavior |
|---|---|---|
| 1-2 | `observation` | Logged normally as a correction in the journal entry. No special handling. |
| 3+ | `guardrail` | Surfaced at session start. Monitored during session. Flagged in real time if the pattern is about to recur. |
| 5+ with no improvement | `critical` | Scribe proposes structural intervention to the user. The user decides. |

### Level Transitions

- **observation -> guardrail**: Automatic when the 3rd occurrence is recorded. The `escalated_at` timestamp is set. The pattern will appear in session-start guardrails beginning with the next session.

- **guardrail -> critical**: Triggered when a pattern has 5+ occurrences AND shows no improvement. "No improvement" means at least 2 new occurrences after escalation to guardrail level. The transition is not purely count-based — a pattern at 5 occurrences that has shown declining frequency stays at guardrail.

- **Any level -> observation (resolved)**: When resolution criteria are met (see Section 8). The pattern returns to observation-level monitoring to catch regression.

- **Levels never skip**: A pattern cannot jump from observation to critical. It must pass through guardrail first, giving the monitoring mechanism a chance to work before proposing structural changes.

---

## 4. Pattern Detection

When the Writer records a new correction, the Observer must determine whether it matches an existing pattern or represents a new one.

### Matching Strategy

The Observer checks each new correction against existing patterns using:

1. **String similarity**: Compare the correction text against existing pattern descriptions and prior occurrence contexts. Fuzzy matching — the same mistake is rarely described in identical words.

2. **Category matching**: Corrections fall into natural categories. A new correction about "deleted file without reading it" matches the category of an existing pattern about "edited function without checking full file" — both are file-operation-before-reading failures.

3. **Root cause alignment**: Two corrections with different surface symptoms but the same underlying cause should be grouped. "Shipped broken mobile layout" and "forgot to test at 767px" are the same pattern if the root cause is skipping viewport testing.

### Categories for Grouping

These are not exhaustive — the Observer should identify categories organically — but common groupings include:

- File operations (reading before writing, checking before deleting)
- Data queries (pagination, filtering, count verification)
- Verification (testing, build checks, deploy confirmation)
- Research (reading docs, checking existing code, reviewing specs)
- Scope (over-engineering, scope creep, gold-plating)
- Communication (assumptions about requirements, skipping confirmation)
- Destructive operations (force pushes, hard resets, cascade deletes without backup)

### Bias Toward Matching

The Observer should err on the side of matching a correction to an existing pattern. The cost of a false match is low — one extra occurrence on a tracked pattern. The cost of a missed match is high — a recurring mistake that never triggers escalation because each instance looks "new."

When uncertain, match and note the uncertainty in the occurrence context.

---

## 5. Session-Start Guardrail Protocol

When one or more patterns are at `guardrail` or `critical` level, Scribe MUST surface them at the beginning of every session. This is not optional. This is not skippable. This is the mechanism that makes correction tracking actionable.

### Format

```
SCRIBE GUARDRAILS (N active):
  [GUARDRAIL] Description -- X occurrences, still recurring
  [GUARDRAIL] Description -- X occurrences, trending down (Y days since last)
  [CRITICAL]  Description -- X occurrences, intervention proposed
```

### Rules

1. **All active guardrails are shown every session.** No filtering by project, no suppression for "low activity" patterns. If it is active, it is shown.

2. **Recency matters.** Include days since last occurrence. A pattern with 5 occurrences but none in 3 weeks is different from one with 3 occurrences in the last 3 days.

3. **Trend direction is stated.** "Still recurring" vs. "trending down" gives the user (and the AI) signal about whether the guardrail is working.

4. **Critical patterns include action prompt.** If a pattern is at critical level, the guardrail line should note that intervention has been proposed or is pending.

5. **Guardrails are read by the Observer.** The Observer loads active guardrails at session start and uses them to inform real-time monitoring throughout the session.

### Example

```
SCRIBE GUARDRAILS (3 active):
  [GUARDRAIL] Read files before modifying -- 5 occurrences, still recurring
  [GUARDRAIL] Paginate Supabase queries on large tables -- 4 occurrences, trending down (12 days since last)
  [CRITICAL]  Verify build passes before committing -- 6 occurrences, intervention pending
```

---

## 6. Real-Time Monitoring

During a session, the Observer watches for moments where the AI is about to repeat a known correction pattern. The intervention happens BEFORE the mistake, not after.

### Detection Signals

The Observer identifies pattern-matching moments by watching for:

- **Action sequences** that match prior occurrence contexts (e.g., about to edit a file that has not been read in this session)
- **Missing prerequisite steps** (e.g., about to run a Supabase query without pagination on a table known to exceed 1000 rows)
- **Skipped workflow stages** (e.g., about to commit without running a build, when "untested-code-shipped" is a tracked pattern)

### Intervention Format

```
SCRIBE: Pattern match -- "pattern-slug" (N prior occurrences).
[Specific guidance for prevention]
```

### Rules

1. **Be specific.** "Pattern match -- skipping-file-reads" is insufficient. Include the actionable step: "This file has not been read yet. Read before modifying."

2. **Cite the count.** The occurrence count communicates severity. 2 prior occurrences is a reminder. 7 prior occurrences is a pattern the user has explicitly tried to fix.

3. **One line of guidance.** The intervention is a nudge, not a lecture. State what should happen instead.

4. **Do not block.** Scribe flags and advises. It does not prevent the AI from proceeding. The user and AI retain full agency. The flag creates awareness; awareness changes behavior.

5. **Log the intervention.** Whether the flag was heeded or ignored, record it in the session entry. This data feeds into escalation decisions and Reader analysis.

### Example

```
SCRIBE: Pattern match -- "skipping-file-reads" (5 prior occurrences).
This file has not been read yet. Read before modifying.
```

```
SCRIBE: Pattern match -- "unpaginated-supabase-queries" (4 prior occurrences).
This table may exceed 1000 rows. Add pagination before executing.
```

---

## 7. Critical Escalation — User-Guided Intervention

When a pattern reaches critical level (5+ occurrences with no improvement despite guardrail monitoring), logging and flagging have demonstrably failed to change behavior. Scribe escalates to the user with a proposal for structural intervention.

### When It Happens

During the next Reader session (user-initiated reflection), or at the start of a session if no Reader session occurs within 3 sessions of the critical threshold being reached.

### What Scribe Presents

1. **The pattern and its history**: Slug, description, full occurrence timeline with contexts.

2. **Why the current approach is not working**: Specific evidence — "This pattern was escalated to guardrail on [date]. Since then, N new occurrences have been logged. Real-time flags were issued M times. The pattern continues."

3. **2-3 specific options for structural intervention**, tailored to the pattern. Examples:

   - **For "skipping-file-reads"**:
     - Add a pre-action checklist to CLAUDE.md that enforces file reads before edits
     - Create a guardrail skill (similar to research-gate) that blocks edits on unread files
     - Add it to the Observer's hard-stop monitoring — flag AND refuse to proceed

   - **For "untested-code-shipped"**:
     - Add a pre-commit hook that runs the build
     - Create a verification skill that enforces test-before-commit workflow
     - Add a CLAUDE.md directive requiring build output before any commit message

   - **For "unpaginated-supabase-queries"**:
     - Add a code-level wrapper that enforces pagination on all Supabase calls
     - Create a CLAUDE.md rule with the specific tables and row-count thresholds
     - Add database-level guardrails (row limits on specific views)

4. **The user decides.** Scribe proposes. The user disposes. No autonomous changes to CLAUDE.md, no auto-generated skills, no modifications to workflow without explicit approval.

### Format

```
SCRIBE CRITICAL ESCALATION: "pattern-slug"

Pattern: [description]
Occurrences: N (first: [date], most recent: [date])
Guardrail active since: [date]
Occurrences since guardrail: M
Real-time flags issued: K (heeded: H, ignored: I)

Current approach (logging + flagging) is not preventing recurrence.

Options:
  1. [Specific structural intervention]
  2. [Specific structural intervention]
  3. [Specific structural intervention]

Which approach would you like to try? Or propose your own.
```

---

## 8. Resolution

A correction pattern is resolved when the underlying behavior has changed, not merely when the user stops encountering the specific scenario.

### Resolution Criteria

A pattern is considered resolved when ANY of the following are true:

1. **Zero new occurrences for 30+ days** with active use of the relevant workflow. (If the user hasn't worked on the relevant project in 30 days, the clock does not count.)

2. **The user explicitly marks it resolved.** The user can resolve a pattern at any time via `scribe resolve <pattern-slug>`. Scribe records the resolution but continues monitoring.

3. **A structural intervention was deployed and is working.** If the critical escalation resulted in a skill, CLAUDE.md rule, or other structural change, AND zero occurrences have been recorded since deployment, the pattern is resolved.

### Post-Resolution Monitoring

Resolved patterns are NOT deleted. They are:

- Moved back to `observation` level
- Marked with `resolved: true`, `resolved_at` timestamp, and `resolution_method`
- Monitored passively — any new occurrence triggers re-evaluation

### Regression Handling

If a resolved pattern recurs:

- 1 occurrence: Logged at observation level with a note that this is a regression on a previously resolved pattern
- 2 occurrences: Re-escalated to guardrail level. `resolved` set back to `false`. `escalated_at` updated.
- The escalation ladder applies normally from there

### Resolution Methods (Recorded Values)

| Value | Meaning |
|---|---|
| `behavioral` | The pattern stopped through awareness alone (logging + guardrails worked over time) |
| `skill_created` | A custom skill was built to enforce the correct behavior |
| `claude_md_rule` | A directive was added to CLAUDE.md |
| `structural_change` | Code-level, hook-level, or tooling change that prevents the mistake |
| `user_resolved` | User explicitly marked it resolved (override) |
| `workflow_change` | User changed their workflow to avoid the scenario entirely |

---

## 9. Integration with Writer

The Writer pipeline is the entry point for correction tracking. After writing a journal entry that contains corrections, the Writer MUST update the correction tracker.

### Writer Pipeline Steps

1. **Write the journal entry** to all enabled storage targets (local, Drive, Supabase).

2. **Check for corrections.** If the entry's `corrections[]` array is empty or absent, skip tracker update.

3. **For each correction in the entry:**

   a. **Match against existing patterns.** Use the detection strategy from Section 4 — string similarity, category matching, root cause alignment.

   b. **If a match is found:**
      - Append a new occurrence to the matched pattern's `occurrences` array
      - Set `entry_id` to the current entry's ID
      - Set `date` to the current entry's timestamp
      - Set `context` to a concise description of what specifically happened this time
      - Check escalation threshold: if occurrences reach 3, escalate to `guardrail`; if 5+ with no improvement, escalate to `critical`
      - Update `escalated_at` if level changed

   c. **If no match is found:**
      - Create a new pattern entry at `observation` level
      - Generate a descriptive slug from the correction text
      - Set `escalated_at` to null, `resolved` to false

4. **Update `last_updated`** on the tracker file.

5. **Write `correction-tracker.json`** to the data directory.

### Atomicity

The tracker update should happen after the journal entry is successfully written. A failed tracker update should not block or roll back the journal entry. The journal is always the primary record; the tracker is a derived index.

---

## 10. Integration with Reader

The Reader uses the correction tracker to provide evidence-based reflection on the user's correction patterns and growth.

### Correction Scorecard

When the user asks about improvement, progress, or patterns, the Reader includes a correction scorecard:

```
CORRECTION SCORECARD:
  Active guardrails: N
  Critical patterns: M
  Resolved (last 90 days): K
  Total tracked patterns: T

  Most frequent: "pattern-slug" (X occurrences)
  Most recent: "pattern-slug" (last occurrence: date)
  Longest resolved: "pattern-slug" (resolved Y days ago, no regression)
```

### Before/After Analysis

The Reader should report correction frequency relative to escalation events:

- Occurrence rate before guardrail activation vs. after
- Whether real-time flags are being heeded (if logged)
- Time between occurrences — accelerating, stable, or decelerating

### Growth Assessment Integration

Correction patterns factor into the Reader's growth assessments:

- A user with zero active guardrails and 5 resolved patterns in the last quarter shows concrete growth
- A user with 3 critical patterns and no resolutions in 60 days is plateaued in those areas
- The Reader should name this directly, per the honesty rules

### Escalation Proposals

When the Reader detects a pattern at critical threshold during a reflection session, it presents the critical escalation (Section 7) as part of the reflection. The Reader does not wait for the user to specifically ask about corrections — if critical patterns exist, they are included in any reflection response.

---

## 11. Observer Responsibilities

For clarity, here is a consolidated list of what the Observer does at each phase of a session relative to this protocol.

### Session Start

1. Load `correction-tracker.json` from the data directory
2. Identify all patterns at `guardrail` or `critical` level
3. Output the guardrail block (Section 5) if any active guardrails exist
4. Hold the active patterns in context for real-time monitoring

### During Session

1. Watch for action sequences that match active guardrail patterns
2. Issue real-time flags (Section 6) when a match is detected
3. Record whether flags were heeded or ignored (for escalation analysis)

### Session End

1. If corrections were logged during the session, verify the Writer updated the tracker
2. Note any guardrail compliance or violations in the session-close entry

---

## 12. Edge Cases

### Multiple Patterns in One Session

A single session can trigger multiple pattern matches. Each is flagged independently. The guardrail block at session start shows all active patterns regardless of how many there are.

### Overlapping Patterns

Two patterns may share root causes. The Observer should track them separately but note the connection in occurrence context. The Reader can surface the connection during reflection.

### User Disagreement

The user may disagree that a correction constitutes a pattern match. The Observer should accept the user's judgment and note it. If the user consistently rejects matches for a pattern, the Reader should raise this during reflection — either the pattern definition needs refinement, or the user is in denial. Both possibilities are worth surfacing.

### New User / Empty Tracker

On first use, `correction-tracker.json` is initialized with an empty `patterns` object. Every correction is a new pattern at observation level. The system bootstraps naturally from the first session.

### Imported Corrections

If a user imports existing journal entries (from a prior Scribe instance or chat exports), the Writer should process all corrections in chronological order to build the tracker retroactively. This may result in patterns that are immediately at guardrail or critical level.
