# Offline Ollama Setup for OpenClaw

**Goal:** Run models locally on your Windows PC and use them from the OpenClaw Gateway on the Droplet — without exposing Ollama to the public internet.

**Your environment (2026-09-16):**

| Host | Tailscale IP | RAM | Role |
| --- | --- | --- | --- |
| Windows PC | `PC_TAILSCALE_IP` | 16 GiB | Ollama + optional OpenClaw node |
| Droplet | `DROPLET_TAILSCALE_IP` | 2 GiB | OpenClaw Gateway (ChatGPT primary today) |

The Droplet cannot host useful local LLMs. Install Ollama on the PC.

---

## Choose an architecture

### Option A — Node-local inference (recommended)

Ollama stays on **loopback only** (`127.0.0.1:11434`) on the PC. The OpenClaw **node** connects to the Gateway over Tailscale and exposes `node_inference` for short offline tasks.

**Pros:** Most secure (matches your loopback-only posture). No firewall changes.  
**Cons:** Not the default chat model — the main agent delegates via the `node_inference` tool; ChatGPT stays primary for Telegram.

Official docs: https://docs.openclaw.ai/providers/ollama/node-local-inference

### Option B — Tailscale LAN provider

Ollama listens on the PC's **Tailscale IP only**. The Droplet OpenClaw provider points at `http://PC_TAILSCALE_IP:11434` (native API, **no `/v1`**).

**Pros:** Full agent turns can use `ollama/<model>` as primary or fallback.  
**Cons:** PC must be on and reachable; bind Ollama carefully (Tailscale IP only, never `0.0.0.0` on public interfaces).

Official docs: https://docs.openclaw.ai/providers/ollama/setup , https://docs.openclaw.ai/providers/ollama/configuration

### Option C — Ollama on the Droplet

**Not recommended.** 2 GiB RAM fits only tiny models (e.g. `qwen3:0.6b`) and will compete with OpenClaw + Gateway.

---

## Step 1 — Install Ollama on Windows

```powershell
winget install Ollama.Ollama --accept-package-agreements --accept-source-agreements
```

Restart the terminal, then verify:

```powershell
ollama --version
ollama serve   # usually runs as a background service after install
```

Pull a tool-capable model (pick one for 16 GiB RAM):

```powershell
# Balanced — good default
ollama pull qwen3:8b

# Smaller / faster
ollama pull qwen3:4b

# OpenClaw onboarding default suggestion
ollama pull gemma4
```

List installed models:

```powershell
ollama list
```

---

## Step 2A — Node-local inference (Option A)

### 2A.1 Install OpenClaw CLI on Windows

Use the same major version as the Droplet (`2026.9.2`):

```powershell
npm install -g openclaw@2026.9.2
openclaw --version
```

### 2A.2 Connect the node to the Gateway

From the PC (Gateway token from the Droplet — enter interactively, never paste into chat):

```powershell
openclaw node run `
  --host DROPLET_TAILSCALE_IP `
  --port 18789 `
  --display-name "pc-ollama-node"
```

On the **Droplet**, approve the device and node (run over Tailscale SSH):

```bash
ssh -i ~/.ssh/id_ed25519_openclaw admin@DROPLET_TAILSCALE_IP

sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw devices list
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw devices approve <deviceRequestId>
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw nodes pending
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw nodes approve <nodeRequestId>
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw nodes status --connected
```

### 2A.3 Enable the Ollama plugin on the Droplet

```bash
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw plugins install ollama
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set plugins.allow '["memory-core","openai","telegram","device-pair","ollama"]' --strict-json --replace
sudo systemctl restart openclaw-gateway
curl -fsS http://127.0.0.1:18789/healthz
```

### 2A.4 Verify node inference (Droplet)

```bash
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw nodes invoke \
  --node "pc-ollama-node" \
  --command ollama.models \
  --params '{}' \
  --invoke-timeout 90000 \
  --timeout 100000

sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw nodes invoke \
  --node "pc-ollama-node" \
  --command ollama.chat \
  --params '{"model":"qwen3:8b","prompt":"Reply with exactly: OLLAMA_NODE_OK","maxTokens":32,"timeoutMs":120000}' \
  --invoke-timeout 130000 \
  --timeout 140000
```

ChatGPT remains primary; ask the agent to use node inference for offline work, e.g. *"Discover Ollama models on my nodes and summarize this locally."*

---

## Step 2B — Tailscale LAN provider (Option B)

### 2B.1 Bind Ollama to Tailscale only (Windows)

Set user environment variable (System Properties → Environment Variables, or PowerShell as admin):

```
OLLAMA_HOST=PC_TAILSCALE_IP:11434
```

Restart the Ollama app/service. Confirm from the Droplet:

```bash
curl -fsS http://PC_TAILSCALE_IP:11434/api/tags
```

**Do not** bind to `0.0.0.0` on a machine with a public interface unless Tailscale is the only path and firewall blocks the rest.

### 2B.2 Configure OpenClaw on the Droplet

```bash
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw plugins install ollama

sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set plugins.allow '["memory-core","openai","telegram","device-pair","ollama"]' --strict-json --replace

sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set models.providers.ollama.apiKey "ollama-local"
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set models.providers.ollama.baseUrl "http://PC_TAILSCALE_IP:11434"
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set models.providers.ollama.api "ollama"

# Allow ollama models in policy (keep openai/* too)
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set agents.defaults.modelPolicy.allow '["openai/*","ollama/*"]' --strict-json --replace
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set agents.entries.main.modelPolicy.allow '["openai/*","ollama/*"]' --strict-json --replace

sudo systemctl restart openclaw-gateway
sleep 5
curl -fsS http://127.0.0.1:18789/healthz
```

### 2B.3 Test a Gateway turn with Ollama

```bash
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw agent \
  --agent main \
  --model ollama/qwen3:8b \
  --message "Reply exactly: OLLAMA_MODEL_OK" \
  --timeout 300
```

To use Ollama as **fallback** (keep ChatGPT primary):

```bash
sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw config set agents.defaults.model.fallbacks '["ollama/qwen3:8b"]' --strict-json --replace
```

---

## Critical rules (from OpenClaw docs)

1. Use the **native** Ollama URL: `http://host:11434` — **never** append `/v1` (breaks tool calling).
2. Local/LAN hosts use the marker credential `ollama-local`, not a real API key.
3. Do **not** expose port `11434` on the Droplet's public IPv4.
4. After every Gateway restart, wait for `/healthz` before testing models.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Connection refused` from Droplet to PC | PC asleep, Ollama not running, or `OLLAMA_HOST` wrong |
| `No models available` | Run `ollama pull <model>` on the PC |
| Tool JSON in plain text | You used `/v1` — fix `baseUrl` |
| Cold model timeout | Increase `timeoutSeconds` to 300; use smaller model or `keep_alive` |
| Node not listed | Re-run `openclaw node run`; check `nodes pending` on Droplet |

---

## Suggested model picks (16 GiB RAM, no discrete GPU)

| Model | Size | Use |
| --- | --- | --- |
| `qwen3:8b` | ~5 GB | Best balance for agent-style chat |
| `qwen3:4b` | ~2.5 GB | Faster, lighter |
| `gemma4` | varies | OpenClaw onboarding default |
| `qwen3:0.6b` | tiny | Node inference smoke tests only |

Quantized GGUF models use less RAM; first run loads weights — expect 30–120s cold start.
