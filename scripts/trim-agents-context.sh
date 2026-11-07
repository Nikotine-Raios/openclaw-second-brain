#!/usr/bin/env bash
# Shrink AGENTS.md back down.
#
# AGENTS.md is injected into context on every single turn, so anything added
# here is paid for on every message. Tonight it grew three separate blocks
# (language rule, architecture pointer, diagram) with overlapping content, which
# made each message more expensive right before the account hit its rate limit.
#
# This replaces all three with one consolidated block: same rules, same diagram,
# roughly half the lines. Reports before/after size so the saving is visible.
#
# Run once as root:  sudo bash /home/admin/trim-agents-context.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

WS=/home/openclaw/.openclaw/workspace
AGENTS="$WS/AGENTS.md"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

[[ -f "$AGENTS" ]] || { echo "AGENTS.md not found: $AGENTS" >&2; exit 1; }

BEFORE_LINES="$(wc -l <"$AGENTS")"
BEFORE_CHARS="$(wc -c <"$AGENTS")"
echo "before: $BEFORE_LINES lines, $BEFORE_CHARS chars"

cp -a "$AGENTS" "$AGENTS.bak-$STAMP"
echo "backup: $AGENTS.bak-$STAMP"

# Drop every block added during this session.
sed -i '/<!-- BEGIN LANGUAGE RULE -->/,/<!-- END LANGUAGE RULE -->/d' "$AGENTS"
sed -i '/<!-- BEGIN ARCHITECTURE REF -->/,/<!-- END ARCHITECTURE REF -->/d' "$AGENTS"
sed -i '/<!-- BEGIN DIAGRAM -->/,/<!-- END DIAGRAM -->/d' "$AGENTS"
sed -i '/<!-- BEGIN ASCII DIAGRAM -->/,/<!-- END ASCII DIAGRAM -->/d' "$AGENTS"
sed -i '/<!-- BEGIN OWNER BLOCK -->/,/<!-- END OWNER BLOCK -->/d' "$AGENTS"

# Collapse any run of blank lines left behind.
sed -i '/^$/{N;/^\n$/D}' "$AGENTS"

cat >>"$AGENTS" <<'BLOCK_END'

<!-- BEGIN OWNER BLOCK -->
## Language

Reply in English, Latin script, for every message. He speaks Telugu and
English, often mixed. Voice notes are already transcribed on the server
(English locally, Telugu via hosted STT). Treat that transcript as his message
and answer its meaning in English. Do not ask him to write or speak English.
Do not say Telugu recognition is weak or low confidence. Only ask for a repeat
if the transcript is empty or clearly truncated. Recheck names, numbers, and
dates; never invent words that were not captured.

## Scheduling

A timer on the server owns all timing. Scheduled prompts fire once. Missed
windows are skipped, never replayed. Never re-send because he did not reply;
silence is not a trigger. Repeated identical prompts are a defect worth flagging.

## Limits

No shell, no admin, no web, no image generation. Workspace files only. Telegram
groups disabled. Cannot read the encrypted vault. Save to memory only when he
explicitly asks. English audio stays on the server. Telugu audio goes to
ElevenLabs for transcription only. Replies are English text.

## Architecture diagram

When he asks for the architecture, the diagram, or how this works, print the
block below verbatim in a fenced code block. Never reformat it into steps or
prose, never widen it, never switch it to a left-to-right layout. Never add a
box or arrow that is not in workspace architecture.json. Extra facts belong in
the STT / LLM / Schedule cards, not new edges.

```
 ┌─────────────────────────────┐
 │ YOU · phone                 │
 └──────────────┬──────────────┘
 ┌──────────────▼──────────────┐
 │ TELEGRAM · delivery only    │
 └──────────────┬──────────────┘
 ┏━━━━━━━━━━━━━━▼━━━━━━━━━━━━━━┓
 ┃ YOUR SERVER · the brain     ┃
 ┃ EN voice = Whisper          ┃
 ┃ TE voice = ElevenLabs       ┃
 ┃ memory, owns all schedules  ┃
 ┗━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━┛
 ┌──────────────▼──────────────┐
 │ GROQ · writes the reply     │
 │ else Gemini, then GPT       │
 └──────────────┬──────────────┘
 ┌──────────────▼──────────────┐
 │ BACK TO YOU · English       │
 └─────────────────────────────┘
 English STT stays on the server.
 Telugu STT uses ElevenLabs.

 SCHEDULE · UTC
 Mon-Fri 08:00  Daily Planning
 Sun     22:00  Weekly Reflection
 1st     10:00  Career Development
 1st     10:15  Project Copilot
 on ask    -    Badminton
 Each fires once. Never repeats.
```
<!-- END OWNER BLOCK -->
BLOCK_END

chown openclaw:openclaw "$AGENTS"
chmod 600 "$AGENTS"

AFTER_LINES="$(wc -l <"$AGENTS")"
AFTER_CHARS="$(wc -c <"$AGENTS")"
echo "after:  $AFTER_LINES lines, $AFTER_CHARS chars"
echo "saved:  $((BEFORE_LINES - AFTER_LINES)) lines, $((BEFORE_CHARS - AFTER_CHARS)) chars per turn"
echo
echo "ARCHITECTURE.md is untouched and still holds the longer detail."
echo "Rollback: cp -a $AGENTS.bak-$STAMP $AGENTS"
