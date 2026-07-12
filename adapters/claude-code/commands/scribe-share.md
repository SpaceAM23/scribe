---
name: scribe-share
description: Generate a Scribe-to-Scribe packet for a collaborator
---

# Scribe Share — Generate a Scribe-to-Scribe Packet

Create a trusted handshake packet to share project context with another Scribe user.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Read config and schema

Read two files:
1. `<data_path>/config.json` — for sender profile, share defaults, and project list
2. `~/.claude/scribe/core/packet-schema.json` — for the packet format

## Step 3: Parse arguments

Extract from the user's message:
- **Project name** (required) — the project to share context about
- **Receiver name** (required, via `--to <name>` or natural language like "share with the operator")

If either is missing, ask the user. Example: "Which project and who should I generate the packet for? Usage: /scribe-share restaurant --to operator"

Validate the project name against the user's config. If the project is not in config, warn but proceed (entries may still exist for it).

## Step 4: Gather project entries

Filter entries from `<data_path>/journal.jsonl` to the specified project:

```bash
cat <data_path>/journal.jsonl | jq -s '[.[] | select(.project == "<project>")]'
```

From the filtered entries, extract:

1. **Decisions**: entries with type `decision_made` — pull title, summary (as reasoning), and timestamp
2. **Learnings**: entries with type `learning` — pull title, summary (as detail), and derive relevance
3. **Corrections**: entries with type `correction` — look for correction-to-resolution chains to build learning stories
4. **Active work**: entries with type `feature_shipped` or `bug_fixed` from the last 30 days — derive status
5. **Working agreements**: scan decisions for convention/pattern entries that would apply to both people

## Step 5: Build learning stories

Look for correction entries that have related resolution entries (connected via `connections.builds_on[]` or same topic). For each chain:

```json
{
  "title": "<topic>",
  "attempts": ["<first approach and what happened>", "<second approach>"],
  "thinking": "<reasoning behind the eventual solution>",
  "outcome": "<measured result>",
  "transferable_lesson": "<what the receiver can apply>"
}
```

If no correction chains exist, learning_stories can be an empty array.

## Step 6: Check for prior packets

Look for existing packets with this receiver in `<data_path>/outbox/`:

```bash
ls <data_path>/outbox/<receiver_lowercase>-*.packet.json 2>/dev/null
```

If prior packets exist, read the most recent one to:
- Pull relationship information (how_we_work_together, trust_level, collaboration_since, etc.)
- Note interaction patterns and shared vocabulary
- Only include NEW decisions/learnings since the last packet date

## Step 7: Build the packet

Construct the packet following the schema from `core/packet-schema.json`:

```json
{
  "scribe_packet": "1.0",
  "generated": "<current ISO timestamp>",
  "packet_id": "<new UUID>",

  "sender": {
    "name": "<from config user_profile.name>",
    "scribe_id": "<from config user_id>",
    "role": "<from config user_profile.role>",
    "expertise": "<from config user_profile.expertise, filtered by share_defaults>",
    "working_style": "<from config user_profile.working_style, if share_defaults.include_working_style>",
    "communication_preferences": "<from config, if share_defaults.include_communication_prefs>"
  },

  "receiver": {
    "name": "<receiver name>",
    "known_role": "<if known from prior packets or entries>",
    "notes": "<contextual notes about the receiver>"
  },

  "relationship": {
    "shared_projects": ["<project>"],
    "how_we_work_together": "<from prior packets or inferred from entries>",
    "trust_level": "<from prior packets or 'new'>",
    "collaboration_since": "<from prior packets or 'new'>",
    "interaction_patterns": "<from prior packets or inferred>",
    "shared_vocabulary": ["<terms used across entries>"],
    "tension_points": "<from prior packets or null>"
  },

  "for_receiver_claude": {
    "integration_guidance": "<generated: how receiver's Claude should use sender's decisions>",
    "watch_for": "<generated: potential gaps between sender and receiver perspectives>",
    "how_to_use_this_context": "<generated: this is background, not a directive>",
    "when_to_reference": "<generated: when working on shared project, when decisions come up>"
  },

  "project_context": {
    "project": "<project name>",
    "description": "<from config projects or inferred from entries>",
    "current_phase": "<inferred from recent entries>",
    "stack": "<from entries or config>",
    "key_patterns": ["<architectural patterns from decisions>"]
  },

  "decisions": [<extracted decisions>],
  "active_work": [<recent work items with status>],
  "learnings": [<extracted learnings with relevance>],
  "learning_stories": [<built from correction chains>],
  "working_agreements": [<conventions and patterns>],
  "open_questions": []
}
```

**Privacy rules — strictly enforced:**
- NEVER include `behavioral` data from any entry
- NEVER include `growth` assessments from any entry
- NEVER include encrypted content
- NEVER include entries from other projects
- Only include sender profile fields allowed by `scribe_to_scribe.share_defaults` in config
- The user can add open_questions manually before sending

## Step 8: Display for review

Show the complete packet to the user in a readable format before saving:

```
SCRIBE PACKET PREVIEW
=====================

To: <receiver> | Project: <project> | Date: <date>

SENDER PROFILE
  Name: <name>
  Role: <role>
  Expertise: <list>

RECEIVER
  Name: <name>
  Known role: <role or "unknown">

RELATIONSHIP
  <how_we_work_together summary>
  Trust: <level>
  Since: <date>

PROJECT CONTEXT
  <project>: <description>
  Phase: <phase>
  Stack: <stack>
  Patterns: <list>

DECISIONS (<count>)
  - <title> (<date>)

ACTIVE WORK (<count>)
  - <title> [<status>]

LEARNINGS (<count>)
  - <title>

LEARNING STORIES (<count>)
  - <title>

WORKING AGREEMENTS (<count>)
  - <agreement>

OPEN QUESTIONS (<count>)
  (none — add questions before sending if needed)

Save this packet? (The file will be saved to outbox/ for you to deliver.)
```

## Step 9: Save the packet

After the user confirms, save to the outbox:

```bash
<data_path>/outbox/<receiver_lowercase>-<project>-<YYYY-MM-DD>.packet.json
```

Create the outbox directory if it does not exist:

```bash
mkdir -p <data_path>/outbox
```

Write the packet as formatted JSON (2-space indent).

## Step 10: Delivery instructions

Tell the user:

```
PACKET SAVED
  File: <absolute_path>

To deliver this packet, send the file to <receiver> via:
  - Email attachment
  - Shared Google Drive folder
  - AirDrop / direct file transfer
  - Slack / messaging

The receiver drops the file into their Scribe inbox/ directory.
Their Scribe will detect it on their next session start.
```
