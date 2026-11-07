# Local Ollama toolkit — run from Cursor terminal. No Droplet/Telegram required.
#
# Usage:
#   .\ollama-local.ps1 status          # health + installed models
#   .\ollama-local.ps1 test            # smoke test (must print OLLAMA_OK)
#   .\ollama-local.ps1 chat "prompt"   # one-shot completion
#   .\ollama-local.ps1 simulate        # run offline "second brain" sample prompt
#   .\ollama-local.ps1 serve           # start Ollama if not running

param(
  [Parameter(Position = 0)]
  [ValidateSet("status", "test", "chat", "simulate", "serve")]
  [string]$Action = "status",

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$PromptParts,

  [string]$Model = "cursor-local:latest"
)

$ErrorActionPreference = "Stop"

$ollama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) {
  Write-Error "Ollama not found. Install: winget install Ollama.Ollama"
}

function Ensure-Ollama {
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5 | Out-Null
    return
  } catch {
    Write-Host "Starting Ollama..."
    Start-Process -FilePath $ollama -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
  }
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 10 | Out-Null
  } catch {
    Write-Error "Ollama did not start. Open the Ollama app from the Start menu."
  }
}

function Invoke-OllamaChat {
  param([string]$Prompt, [string]$ModelName, [int]$MaxTokens = 1024)
  $body = @{
    model = $ModelName
    messages = @(@{ role = "user"; content = $Prompt })
    stream = $false
    think = $false
    options = @{ num_predict = $MaxTokens; temperature = 0.6 }
  } | ConvertTo-Json -Depth 5 -Compress

  $resp = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:11434/api/chat" `
    -ContentType "application/json" -Body $body -TimeoutSec 300
  $text = [string]$resp.message.content
  if (-not $text.Trim() -and $resp.message.thinking) {
    $text = [string]$resp.message.thinking
  }
  return $text
}

Ensure-Ollama

switch ($Action) {
  "serve" {
    Write-Host "Ollama is running at http://127.0.0.1:11434"
  }
  "status" {
    Write-Host "Ollama: $(& $ollama --version)"
    Write-Host ""
    & $ollama list
    Write-Host ""
    $tags = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags"
    if ($tags.models.Count -eq 0) {
      Write-Warning "No models pulled. Run: ollama pull qwen3:4b"
    } else {
      Write-Host "API: OK ($($tags.models.Count) model(s))"
    }
  }
  "test" {
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags"
    $use = $Model
    if (-not ($models.models.name -contains $use)) {
      $use = ($models.models | Select-Object -First 1).name
      Write-Warning "Model '$Model' missing; using '$use'"
    }
    Write-Host "Testing $use ..."
    $raw = cmd /c "`"$ollama`" run $use `"Reply with exactly: OLLAMA_OK`" 2>nul"
    $out = ($raw | Out-String) -replace '\x1b\[[0-9;?]*[a-zA-Z]', ''
    if ($out -match "OLLAMA_OK") {
      Write-Host "PASS: offline model responded correctly."
      exit 0
    }
    Write-Error "FAIL: expected OLLAMA_OK in output.`nGot: $out"
  }
  "chat" {
    $prompt = ($PromptParts -join " ").Trim()
    if (-not $prompt) { Write-Error "Usage: .\ollama-local.ps1 chat `"your prompt`"" }
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags"
    $use = $Model
    if (-not ($models.models.name -contains $use)) { $use = ($models.models | Select-Object -First 1).name }
    Write-Host "Model: $use`n"
    Invoke-OllamaChat -Prompt $prompt -ModelName $use | Write-Output
  }
  "simulate" {
    $sample = @"
You are a local offline assistant (no cloud APIs). The owner is testing his offline fallback.

Task: Given it is a weekday morning, return:
1. Three plausible top outcomes for today
2. One constraint to watch
3. One first concrete action

Keep it under 120 words. Do not mention Telegram or servers.
"@
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags"
    $use = $Model
    if (-not ($models.models.name -contains $use)) { $use = ($models.models | Select-Object -First 1).name }
    Write-Host "Offline simulation (Daily Planning style) using $use ...`n"
    Invoke-OllamaChat -Prompt $sample -ModelName $use -MaxTokens 512 | Write-Output
  }
}
