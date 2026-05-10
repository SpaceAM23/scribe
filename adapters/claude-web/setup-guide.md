# Scribe -- Claude Web App Setup Guide

This guide walks you through setting up Scribe on Claude.ai (the web interface). Scribe runs entirely through project instructions and Google Drive -- no CLI, no filesystem, no installation scripts.

---

## Prerequisites

- A Claude.ai account (Pro or Team plan recommended for longer conversations)
- A Google account with Google Drive access
- Optionally, a Supabase account for cloud backup

---

## Step 1: Create the Google Drive Folder

1. Open Google Drive (drive.google.com).
2. Create a new folder called **Scribe**.
3. Note the folder location -- Scribe will store all journal entries here as individual JSON files.

No special permissions are needed. The folder lives in your personal Drive.

---

## Step 2: Create a Claude.ai Project

1. Go to claude.ai and log in.
2. In the left sidebar, click **Projects** (or the "+" to create a new project).
3. Name the project **Scribe** (or any name you prefer -- this is just for organization).
4. Open the project settings.

---

## Step 3: Paste the Project Instructions

1. Open the file `project-instructions.md` from this directory (or copy it from the Scribe repository at `adapters/claude-web/project-instructions.md`).
2. In your Claude.ai project settings, find the **Custom Instructions** or **Project Knowledge** section.
3. Paste the entire contents of `project-instructions.md` into that field.
4. Save.

These instructions tell Claude how to behave as Scribe. They are self-contained -- Claude does not need access to any other Scribe files.

---

## Step 4: Enable Google Drive MCP

1. In your Claude.ai project settings, find the **Integrations** or **Connected Apps** section.
2. Enable **Google Drive**.
3. Authorize Claude to access your Google Drive when prompted.
4. Verify access by starting a conversation in the project and asking Claude to list files in your Scribe folder.

Claude uses Google Drive MCP tools to create, read, and update files. This is how Scribe stores entries without filesystem access.

---

## Step 5: Verify Scribe Is Working

1. Start a new conversation in your Scribe project.
2. Type: **"Are you Scribe?"**
3. Claude should confirm its identity as Scribe and ask for your initial configuration (name, role, projects, user ID, behavioral tracking preference).
4. Complete the setup. Scribe will save `scribe-config.json` and `scribe-index.json` to your Drive folder.
5. Scribe will write its first `session_open` entry and show you a receipt.

If Claude does not respond as Scribe, verify that the project instructions were pasted correctly and that Google Drive is connected.

---

## Step 6: Supabase Backup (Optional)

If you want cloud backup in addition to Google Drive, set up a Supabase project.

### 6.1 Create the Supabase Project

1. Go to supabase.com and create a free project (or use an existing one).
2. Go to the SQL Editor in your Supabase dashboard.
3. Run the SQL from `supabase-setup.sql` (included in this directory). This creates the `journal_entries` table with indexes and row-level security.

### 6.2 Get Your Credentials

1. In your Supabase project, go to **Settings** > **API**.
2. Copy the **Project URL** (e.g., `https://xxxxx.supabase.co`).
3. Copy the **anon/public key**.

### 6.3 Tell Scribe

In your next Scribe conversation, say:

> "Scribe config: enable Supabase backup. URL is https://xxxxx.supabase.co, anon key is eyJ..."

Scribe will update `scribe-config.json` on Drive. From that point on, entries are written to both Drive and Supabase.

**Security note**: The anon key is stored in `scribe-config.json` on your personal Google Drive. It is not shared in Scribe packets or exposed elsewhere. If you prefer not to store it, you can provide it at the start of each session instead.

---

## Step 7: Import and Export Data

### Exporting Entries

Ask Scribe:

> "Export my entries for [project] as JSON"

Scribe will read all matching entries from Drive and present them as a single JSON array you can copy or download.

### Importing Entries

If you have entries from another Scribe instance (e.g., from Claude Code), paste or upload the JSON. Tell Scribe:

> "Import these entries into my journal"

Scribe will validate each entry against the schema, save them as individual files in Drive, and update the index.

### Migrating from Claude Code

If you already use Scribe with Claude Code (filesystem-based):

1. In Claude Code, run: `cat ~/Desktop/Scribe/entries/*.json | jq -s '.'` to export all entries as a JSON array.
2. Copy the output.
3. In your Claude.ai Scribe project, paste it and ask Scribe to import the entries.

---

## Step 8: Share Packets with Collaborators

Scribe-to-Scribe packets let you share project context with other Scribe users.

### Sending a Packet

1. In your Scribe project, say: **"Share my context for [project] with [name]"**
2. Scribe will build a packet containing your decisions, learnings, and project context (never behavioral data or growth assessments).
3. Review the packet. Scribe shows it to you before saving.
4. Scribe saves the packet as a file in your Drive folder.
5. Download the packet file from Drive and send it to your collaborator (email, Slack, AirDrop -- any method).

### Receiving a Packet

1. Your collaborator sends you a `.json` packet file.
2. Upload it to your Scribe conversation or paste the JSON content.
3. Tell Scribe: **"Accept this packet"**
4. Scribe validates the packet, shows you a summary, and saves it to Drive.
5. From that point on, Scribe uses the packet context when you work on shared projects.

### What Gets Shared

- Your role, expertise, and working style
- Decisions on shared projects
- Learnings that affect shared work
- Active work status
- Working agreements and shared vocabulary
- Open questions for the receiver

### What Never Gets Shared

- Behavioral observations (drive state, energy, triggers)
- Growth assessments (complexity, autonomy ratings)
- Personal corrections unrelated to shared projects
- Entries on unrelated projects

---

## Ongoing Use

Once set up, Scribe runs automatically in every conversation within your Scribe project:

- It writes `session_open` entries when you start a conversation.
- It records decisions, learnings, corrections, and features as they happen.
- It shows receipts for every entry.
- It surfaces active guardrails (recurring correction patterns) at session start.
- Ask "How am I doing?" anytime for a full reflection.
- Ask "Scribe help" to see all available commands.

---

## Troubleshooting

**Scribe does not respond as Scribe**: Check that the project instructions are pasted into the correct project and that you are starting a conversation within that project.

**Google Drive access fails**: Re-authorize Google Drive in the project integrations. Make sure the Scribe folder exists and is not in Trash.

**Entries are not appearing in Drive**: Ask Scribe to list files in the Scribe folder. If the folder is empty, Scribe may not have write access. Re-authorize and try again.

**Supabase writes fail**: Verify the URL and anon key in your config. Check that the `journal_entries` table exists and RLS policies are in place. Test with a direct API call if needed.

**Session ID conflicts**: Each conversation gets its own session ID. If you start multiple conversations on the same day, Scribe increments the counter automatically.
