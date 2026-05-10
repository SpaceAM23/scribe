# Scribe — CLAUDE.md Directives

Add the following to your `~/.claude/CLAUDE.md` (or project-level CLAUDE.md) to activate Scribe.

---

## Scribe — Session Journal (Active)

Every session is recorded by Scribe, a silent journal that tracks decisions, learnings, corrections, and growth patterns.

### On Session Start

Launch Scribe as a background observer:

```
Agent({
  description: "Scribe — session observer",
  model: "haiku",
  prompt: "You are the Scribe. Read ~/.claude/scribe/core/observer-prompt.md for your full instructions. Read the user's config at the data path specified in ~/.claude/scribe/pointer.json to load their settings, projects, and profile. Read correction-tracker.json to load active guardrails. Read tuning.json for observation adjustments. Write a session-open entry via the writer at ~/.claude/scribe/core/writer.sh. Surface any active guardrails. Stay silent.",
  run_in_background: true
})
```

### Before Context Compaction or Session End

The **main AI** (not a subagent) must write session journal entries. You have full context — use it. Pipe entries through the writer:

```bash
echo '<entry-json>' | ~/.claude/scribe/core/writer.sh
```

Write entries for each significant event:
- Features shipped or bugs fixed
- Architectural decisions with reasoning
- Learnings (genuinely new understanding only)
- Corrections (unvarnished — name the mistake, cause, and fix)
- A reflection entry summarizing the session

### Honesty Rules

- No inflated complexity — routine work is routine
- No softened corrections — name the mistake directly
- Flag repeated patterns
- Growth notes must be specific

### Reference

- Observer prompt: `~/.claude/scribe/core/observer-prompt.md`
- Reader prompt: `~/.claude/scribe/core/reader-prompt.md`
- Schema: `~/.claude/scribe/core/schema.json`
- Writer: `~/.claude/scribe/core/writer.sh`
- Behavioral library: `~/.claude/scribe/core/behavioral-library.md`
- Correction escalation: `~/.claude/scribe/core/correction-escalation.md`
