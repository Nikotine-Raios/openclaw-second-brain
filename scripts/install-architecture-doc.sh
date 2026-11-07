#!/usr/bin/env bash
# Give the second brain a factual description of its own architecture, so it can
# answer "how does my scheduling work?" from fact instead of guessing.
#
# Deliberately contains no tokens, IP addresses, hostnames, or secret paths:
# this file is loaded into agent context and can reach OpenAI and Telegram.
#
# Run once as root:  sudo bash /home/admin/install-architecture-doc.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

WS=/home/openclaw/.openclaw/workspace
DOC="$WS/ARCHITECTURE.md"
AGENTS="$WS/AGENTS.md"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

[[ -d "$WS" ]] || { echo "workspace not found: $WS" >&2; exit 1; }
[[ -f "$AGENTS" ]] || { echo "AGENTS.md not found: $AGENTS" >&2; exit 1; }

[[ -f "$DOC" ]] && cp -a "$DOC" "$DOC.bak-$STAMP" && echo "backup: $DOC.bak-$STAMP"

cat >"$DOC" <<'EOF'
# How this system is built

Factual description of the owner's second brain. Use it to answer questions about
how this system works. If asked something this file does not cover, say so
rather than inventing an answer. Contains no credentials by design.

## Where each piece runs

Telegram is only the chat window. The reasoning runs on a private Linux server.

```mermaid
flowchart LR
    Phone["Phone: Telegram app"] --> TG["Telegram servers"]
    TG --> GW["Private server: OpenClaw gateway"]
    GW --> STT["Local speech-to-text"]
    GW --> MEM["Memory and workflow files"]
    GW --> AI["OpenAI: writes the reply"]
    AI --> GW
    GW --> TG
    TG --> Phone
    TIMER["Server timer: owns all scheduling"] --> GW
```

- The phone records and displays. It does no reasoning.
- The server downloads voice notes, transcribes them locally, holds memory, and
  calls OpenAI for the actual reply text.
- OpenAI receives message text. It does not receive voice audio.
- The server reaches Telegram outbound only; no inbound port is exposed.

## Scheduling

A system timer on the server owns every recurring prompt. OpenClaw's own
heartbeat is disabled, and its internal workflow schedules are disabled.

Times are UTC, and each fires once:

- Daily Planning: weekdays 08:00
- Weekly Reflection: Sundays 22:00
- Career Development: 1st of the month 10:00
- Personal Project Copilot: 1st of the month 10:15
- Badminton Follow-up: on demand only, never scheduled

Rules that follow from this design:

- A scheduled prompt is sent once. It is not a reminder and does not repeat.
- Silence is not a trigger. Never re-send a prompt because the owner did not reply.
- A missed window is skipped, not replayed later.
- If the owner reports repeated identical prompts, that is a defect worth flagging.

## Voice notes

Telegram voice notes are transcribed on the server by a local Whisper model. No
audio is sent to any external service.

Transcription runs in two passes: detect the language, then transcribe. Any
Indic detection is translated into English; English stays English. Output is
always English.

Known limitation, stated plainly when relevant: Telugu recognition at this model
size is unreliable. Forced-Telugu decoding has produced Tamil characters, and
short clips are the worst case. Treat Telugu transcripts as low confidence.

## What this system cannot do

- No shell, no host commands, no server administration.
- File access is limited to the workspace directory.
- No web browsing, no external messaging, no image generation.
- Telegram groups are disabled; only the owner's account is allowed.
- It cannot read the encrypted restricted vault, and must not try.

## Data boundaries

- Normal personal content may go to OpenAI and Telegram.
- Confidential employer or client material requires explicit per-use approval
  and must never be sent through Telegram.
- Financial, health, legal, identity, and credential material belongs only in
  the encrypted vault. Never repeat such content into chat, memory, or logs.
- Memory is saved only when the owner explicitly asks. No silent saving.
EOF

chown openclaw:openclaw "$DOC"
chmod 600 "$DOC"
echo "wrote $DOC"

if grep -q 'BEGIN ARCHITECTURE REF' "$AGENTS"; then
  echo "AGENTS.md already points to ARCHITECTURE.md"
else
  cp -a "$AGENTS" "$AGENTS.bak-$STAMP"
  cat >>"$AGENTS" <<'EOF'

<!-- BEGIN ARCHITECTURE REF -->
## Questions about how this system works

`ARCHITECTURE.md` in this workspace describes how this system is actually built:
what runs on the phone versus the server, how scheduling works, how voice notes
are transcribed, and the data boundaries. Read it before answering questions
about your own setup, scheduling behaviour, or voice handling. Prefer it over
guessing, and say when something is not covered there.
<!-- END ARCHITECTURE REF -->
EOF
  chown openclaw:openclaw "$AGENTS"
  chmod 600 "$AGENTS"
  echo "pointed AGENTS.md at ARCHITECTURE.md (backup: $AGENTS.bak-$STAMP)"
fi

echo
echo "Ask the bot: how does my scheduling work?"
echo "Rollback: rm -f $DOC  (and restore AGENTS.md from its .bak if needed)"
