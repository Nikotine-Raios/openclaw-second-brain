# Start SSH tunnel + OpenClaw node for offline Ollama inference.
# Your Gateway is loopback-only on the Droplet, so the tunnel is required.
#
# Usage:
#   .\connect-ollama-node.ps1              # mint join code on Droplet, connect
#   .\connect-ollama-node.ps1 -JoinUrl <url>  # reuse an existing join URL

param(
  [string]$JoinUrl,
  [string]$GatewayHost = "DROPLET_TAILSCALE_IP",
  [string]$SshUser = "admin",
  [string]$SshKey = "$env:USERPROFILE\.ssh\id_ed25519_openclaw",
  [string]$DisplayName = "pc-ollama-node",
  [int]$LocalPort = 18789
)

$ErrorActionPreference = "Stop"
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User") + ";$env:APPDATA\npm"

$ollama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) {
  Write-Error "Ollama not found. Install from https://ollama.com/download"
}

try {
  Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5 | Out-Null
} catch {
  Write-Host "Starting Ollama..."
  Start-Process -FilePath $ollama -ArgumentList "serve" -WindowStyle Hidden
  Start-Sleep -Seconds 5
}

if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
  Write-Error "OpenClaw CLI not found. Run: npm install -g openclaw@2026.9.2"
}

# SSH tunnel (skip if already listening)
$tunnelUp = $false
try {
  $tunnelUp = (Test-NetConnection -ComputerName 127.0.0.1 -Port $LocalPort -WarningAction SilentlyContinue).TcpTestSucceeded
} catch {}

if (-not $tunnelUp) {
  Write-Host "Starting SSH tunnel localhost:${LocalPort} -> Droplet Gateway..."
  Start-Process -FilePath "ssh" -ArgumentList @(
    "-i", $SshKey,
    "-o", "BatchMode=yes",
    "-o", "ServerAliveInterval=30",
    "-N",
    "-L", "${LocalPort}:127.0.0.1:${LocalPort}",
    "${SshUser}@${GatewayHost}"
  ) -WindowStyle Hidden
  Start-Sleep -Seconds 3
}

$health = curl.exe -fsS "http://127.0.0.1:${LocalPort}/healthz" 2>$null
if (-not $health) {
  Write-Error "Gateway not reachable on localhost:${LocalPort}. Check Tailscale and SSH."
}
Write-Host "Gateway tunnel OK."

if (-not $JoinUrl) {
  Write-Host "Minting join code on Droplet..."
  $json = ssh -i $SshKey -o BatchMode=yes "${SshUser}@${GatewayHost}" `
    "sudo -u openclaw -H /home/openclaw/.openclaw/bin/openclaw devices join-code --json"
  $parsed = $json | ConvertFrom-Json
  if (-not $parsed.joinUrl) { Write-Error "Failed to mint join code: $json" }
  $JoinUrl = $parsed.joinUrl
  Write-Host "Join URL minted (single-use, 10 min)."
}

Write-Host "Connecting node '$DisplayName'..."
openclaw connect $JoinUrl --display-name $DisplayName
