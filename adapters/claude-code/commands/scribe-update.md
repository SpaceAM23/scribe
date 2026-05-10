---
name: scribe-update
description: Pull the latest Scribe version from GitHub
---

# Scribe Update — Pull Latest from GitHub

Update the Scribe skill installation from the GitHub repository.

## Step 1: Locate the skill directory

The Scribe skill is installed at `~/.claude/scribe/`. Verify it exists and is a git repository:

```bash
ls -la ~/.claude/scribe/.git
```

If it is not a git repo, tell the user: "The Scribe skill directory at ~/.claude/scribe/ is not a git repository. To update, re-install with: git clone https://github.com/SpaceAM23/scribe.git ~/.claude/scribe"

## Step 2: Check current version

Read the current version before updating:

```bash
cat ~/.claude/scribe/VERSION
```

Also check for any local modifications:

```bash
cd ~/.claude/scribe && git status --short
```

If there are local modifications, warn the user: "You have local modifications in the skill directory. These will be preserved by git pull if they don't conflict, but may cause merge conflicts." Let the user decide whether to proceed.

## Step 3: Pull latest

Run git pull to fetch and merge the latest changes:

```bash
cd ~/.claude/scribe && git pull origin main
```

If the pull fails due to conflicts, report the conflicting files and tell the user to resolve them manually. Do NOT run `git reset --hard` or any destructive commands.

## Step 4: Check new version

Read the version after updating:

```bash
cat ~/.claude/scribe/VERSION
```

## Step 5: Check for config migration

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Then check if config.json needs migration by comparing schema versions:

1. Read the schema version from the updated `~/.claude/scribe/core/schema.json` (look for `schema_version` field)
2. Read the schema version from the user's `<data_path>/config.json` (look for `schema_version` field)

If the skill's schema version is higher than the config's:

1. Read the config template from `~/.claude/scribe/templates/` (if it exists) to identify new fields
2. Read the user's current config.json
3. Add any new fields with their default values — **never remove existing fields**
4. Update the `schema_version` in config.json to match
5. Update the `scribe_version` in config.json to match the new VERSION
6. Write the updated config.json

If no migration is needed, just update the `scribe_version` field if it changed.

## Step 6: Report

Display a summary:

```
SCRIBE UPDATE COMPLETE
======================

Previous version: <old_version>
Current version:  <new_version>

Files changed:
  <git pull output summary — new files, modified files>

Config migration: <performed / not needed>
  <if performed, list new fields added>

Your data directory (<data_path>) was NOT modified by this update.
Only the skill installation at ~/.claude/scribe/ was updated.
```

If the version did not change (already up to date), say:

```
SCRIBE UPDATE
  Already up to date at version <version>.
  No changes pulled from GitHub.
```
