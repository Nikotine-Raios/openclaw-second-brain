# Offline models in Cursor

Fully local. No tunnel, no cloud round-trip, works with no internet.

## How it works

The Continue extension calls Ollama's REST API on this machine directly:

```
Cursor  ->  Continue extension  ->  http://localhost:11434  ->  Ollama
```

Cursor's own Chat and Agent always route through Cursor's servers, even with
"Override OpenAI Base URL" set, so they can never be truly offline. That path also
needs a public HTTPS tunnel. Continue avoids both problems.

## Installed

| Item | Value |
| --- | --- |
| Ollama | 0.34.1 on `http://127.0.0.1:11434` |
| Extension | `continue.continue` v2.0.0 |
| Config | `%USERPROFILE%\.continue\config.yaml` |
| Chat / edit model | `cursor-local:latest` (qwen2.5-coder 7B, 32k context) |
| Autocomplete model | `qwen2.5-coder:1.5b` |

`cursor-local` is built from `Modelfile.cursor-local`. It is based on qwen2.5-coder
rather than qwen3 because qwen3 is a thinking model: over the OpenAI-compatible `/v1`
endpoint Ollama returns the trace in a separate `reasoning` field and leaves `content`
empty, which shows up as blank replies.

## Use it

Open the Continue sidebar from the Cursor activity bar, or press `Ctrl+L` with Continue
focused. Pick **Local Coder**. Tab completion uses **Local Autocomplete** automatically.

Terminal alternative, no extension needed:

```powershell
cd scripts
.\ollama-local.ps1 status
.\ollama-local.ps1 test
.\ollama-local.ps1 chat "Summarize this repo in 3 bullets"
```

## Rebuild the model after editing the Modelfile

```powershell
ollama create cursor-local -f scripts/Modelfile.cursor-local
```

## Swap in a different model

Pull it, then point `.continue/config.yaml` at the exact name from `ollama list`:

```powershell
ollama pull qwen2.5-coder:14b   # needs more RAM
ollama list
```

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Continue shows no models | Name in `config.yaml` does not match `ollama list` exactly |
| Empty replies | Thinking model on the `/v1` endpoint; use a non-thinking model |
| Slow first reply | Cold start, 30-60s while weights load |
| Connection refused | Ollama not running; launch it from the Start menu |

## Droplet and Telegram

Separate path, deferred. See `setup-ollama-offline.md`.
