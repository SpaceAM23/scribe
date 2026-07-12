---
name: scribe-inbox
description: Manage received Scribe-to-Scribe packets
---

# Scribe Inbox — Manage Received Packets

List, read, and accept Scribe-to-Scribe packets from collaborators.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Parse sub-command

Check the user's message for a sub-command:

- **No sub-command** (just `/scribe-inbox`) — list all packets
- **`read <filename>`** — display a specific packet's contents
- **`accept <filename>`** — integrate a packet into the active session

---

## Sub-command: LIST (default)

List all `.packet.json` files in the inbox directory:

```bash
ls <data_path>/inbox/*.packet.json 2>/dev/null
```

If the inbox directory does not exist or is empty, tell the user: "Inbox is empty. No packets received yet. When a collaborator sends you a .packet.json file, drop it into <data_path>/inbox/"

For each packet file found:

1. Read the file and parse as JSON
2. Extract: sender name, project, generated date, and summary stats

Display as a list:

```
SCRIBE INBOX
=============

1. apollo-restaurant-2026-05-10.packet.json
   From: Apollo | Project: restaurant | Date: 2026-05-10
   Contents: 3 decisions, 1 active work, 2 learnings, 1 learning story, 1 open question

2. designer-nonprofit-2026-05-08.packet.json
   From: the designer | Project: nonprofit | Date: 2026-05-08
   Contents: 2 decisions, 0 active work, 1 learning, 0 learning stories, 0 open questions

Commands:
  /scribe-inbox read <filename>     View full packet contents
  /scribe-inbox accept <filename>   Integrate packet into this session
```

Count decisions, active_work, learnings, learning_stories, and open_questions arrays from each packet to generate the summary stats.

---

## Sub-command: READ <filename>

Read the specified packet file from the inbox:

```bash
cat <data_path>/inbox/<filename>
```

If the file does not exist, check if the user provided a partial name and try to match:

```bash
ls <data_path>/inbox/*<partial>*.packet.json 2>/dev/null
```

Display the full packet contents in a readable format:

```
SCRIBE PACKET: <filename>
=========================

SENDER
  Name: <sender.name>
  Role: <sender.role>
  Expertise: <sender.expertise, comma-separated>
  Working style: <sender.working_style>
  Communication: <sender.communication_preferences summary>

RECEIVER (you)
  Name: <receiver.name>
  Known role: <receiver.known_role>
  Notes: <receiver.notes>

RELATIONSHIP
  Shared projects: <list>
  How you work together: <how_we_work_together>
  Trust level: <trust_level>
  Since: <collaboration_since>
  Interaction patterns: <interaction_patterns>
  Shared vocabulary: <list>
  Tension points: <tension_points>

GUIDANCE FOR YOUR CLAUDE
  Integration: <for_receiver_claude.integration_guidance>
  Watch for: <for_receiver_claude.watch_for>
  How to use: <for_receiver_claude.how_to_use_this_context>
  When to reference: <for_receiver_claude.when_to_reference>

PROJECT: <project_context.project>
  Description: <project_context.description>
  Phase: <project_context.current_phase>
  Stack: <project_context.stack>
  Key patterns:
    - <pattern 1>
    - <pattern 2>

DECISIONS (<count>)
  1. <title> (<date>)
     Reasoning: <reasoning>
     Affects you: <affects_receiver>

  2. <title> (<date>)
     ...

ACTIVE WORK (<count>)
  1. <title> [<status>]
     Touches: <touches list>
     Blocked by: <blocked_by or "nothing">
     Blocks: <blocks or "nothing">
     ETA: <eta or "unknown">

LEARNINGS (<count>)
  1. <title>
     Detail: <detail>
     Relevance: <relevance>

LEARNING STORIES (<count>)
  1. <title>
     Attempts:
       - <attempt 1>
       - <attempt 2>
     Thinking: <thinking>
     Outcome: <outcome>
     Transferable lesson: <transferable_lesson>

WORKING AGREEMENTS (<count>)
  - <agreement 1>
  - <agreement 2>

OPEN QUESTIONS (<count>)
  - <question 1>
  - <question 2>
```

**If the packet has open_questions, surface them prominently** by adding a highlighted section at the top of the output:

```
*** QUESTIONS FROM <sender.name> ***
  1. <question 1>
  2. <question 2>
These questions are waiting for your response.
*************************************
```

---

## Sub-command: ACCEPT <filename>

Integrate the packet's context into the current active session.

1. Read the packet file from inbox
2. Parse all sections
3. Load the following into active session context:

**Sender profile**: Remember who this person is — their role, expertise, working style, and communication preferences. Reference this when working on the shared project.

**Relationship**: Understand how the user and sender work together. Apply the trust level, interaction patterns, and shared vocabulary. Be aware of tension points.

**Integration guidance**: Follow the `for_receiver_claude` instructions. These tell you how to use the sender's context — when to reference it, what to watch for, and how to handle conflicts between the sender's decisions and the receiver's operational reality.

**Decisions**: Treat the sender's decisions as context for the shared project. When the user works on the same project, reference these decisions. If the user's work would conflict with a decision, surface it explicitly.

**Active work**: Be aware of what the sender is currently working on. If the user's work touches the same areas, flag potential conflicts or coordination needs.

**Learnings**: Apply the sender's learnings to the user's work on the shared project. If a learning is relevant to what the user is doing, reference it.

**Learning stories**: These capture the sender's full journey on a topic. If the user encounters a similar situation, reference the transferable lesson before they repeat the journey.

**Working agreements**: Enforce these as shared conventions. Both people agreed to these patterns — apply them consistently.

**Open questions**: Present these to the user immediately after acceptance:

```
PACKET ACCEPTED: <sender.name> / <project>
===========================================

Context loaded. I now understand <sender.name>'s role, decisions, and working
patterns on <project>. I'll reference this context when you work on <project>.

<sender.name> has questions for you:
  1. <question 1>
  2. <question 2>

Would you like to respond to any of these now?
```

If there are no open questions:

```
PACKET ACCEPTED: <sender.name> / <project>
===========================================

Context loaded. I now understand <sender.name>'s role, decisions, and working
patterns on <project>. I'll reference this context when you work on <project>.

Summary integrated:
  - <count> decisions
  - <count> active work items
  - <count> learnings
  - <count> learning stories
  - <count> working agreements
```

The packet file remains in inbox/ after acceptance — it is not deleted. It serves as a persistent reference.
