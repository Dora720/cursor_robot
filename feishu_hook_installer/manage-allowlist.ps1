# Manage machine-wide Always Run allowlist used by Feishu confirm hooks.
# File: %USERPROFILE%\.cursor\hooks\always-run\shared.json
# Usage:
#   .\manage-allowlist.ps1 list
#   .\manage-allowlist.ps1 add "git status"
#   .\manage-allowlist.ps1 remove "git status"
#   .\manage-allowlist.ps1 clear
#   .\manage-allowlist.ps1 open
param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "add", "remove", "clear", "open", "path")]
    [string]$Action = "list",
    [Parameter(Position = 1)]
    [string]$Command = ""
)

$ErrorActionPreference = "Stop"
$hookDir = Join-Path $env:USERPROFILE ".cursor\hooks"
$alwaysDir = Join-Path $hookDir "always-run"
$shared = Join-Path $alwaysDir "shared.json"

function Read-Allowlist {
    $cmds = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $shared)) { return $cmds }
    $raw = [System.IO.File]::ReadAllText($shared, [System.Text.Encoding]::UTF8).Trim()
    if (-not $raw) { return $cmds }
    try {
        $obj = $raw | ConvertFrom-Json
        foreach ($c in @($obj.commands)) {
            if ($c) { [void]$cmds.Add([string]$c) }
        }
    } catch {
        if ($raw) { [void]$cmds.Add($raw) }
    }
    return $cmds
}

function Write-Allowlist($commands) {
    if (-not (Test-Path -LiteralPath $alwaysDir)) {
        New-Item -ItemType Directory -Force -Path $alwaysDir | Out-Null
    }
    $uniq = @()
    foreach ($c in @($commands)) {
        $s = ([string]$c).Trim()
        if ($s -and ($uniq -notcontains $s)) { $uniq += $s }
    }
    $json = (@{
        commands = $uniq
        scope = "machine"
        permanent = $true
        updated_at = (Get-Date).ToString("o")
    } | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($shared, $json, [System.Text.UTF8Encoding]::new($false))
}

switch ($Action) {
    "path" {
        Write-Output $shared
    }
    "open" {
        if (-not (Test-Path -LiteralPath $shared)) { Write-Allowlist @() }
        # Open in Cursor/VS Code if available, else notepad
        $editor = $null
        foreach ($c in @("cursor", "code")) {
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if ($cmd) { $editor = $cmd.Source; break }
        }
        if ($editor) {
            Start-Process -FilePath $editor -ArgumentList @("-r", $shared) | Out-Null
        } else {
            Start-Process -FilePath "notepad.exe" -ArgumentList @($shared) | Out-Null
        }
        Write-Output "Opened: $shared"
    }
    "list" {
        $cmds = Read-Allowlist
        Write-Output "Allowlist file: $shared"
        Write-Output "Count: $($cmds.Count)"
        Write-Output "Scope: machine (permanent on this PC, no time limit)"
        if ($cmds.Count -eq 0) {
            Write-Output "(empty)"
        } else {
            $i = 1
            foreach ($c in $cmds) {
                Write-Output ("{0}. {1}" -f $i, $c)
                $i++
            }
        }
    }
    "add" {
        if (-not $Command) { throw "Usage: manage-allowlist.ps1 add `"command`"" }
        $cmds = Read-Allowlist
        if ($cmds -notcontains $Command) { [void]$cmds.Add($Command) }
        Write-Allowlist $cmds
        Write-Output "Added: $Command"
        Write-Output "Count: $($cmds.Count)"
    }
    "remove" {
        if (-not $Command) { throw "Usage: manage-allowlist.ps1 remove `"command`"  (or remove *)" }
        $cmds = @(Read-Allowlist | Where-Object { $_ -ne $Command })
        Write-Allowlist $cmds
        Write-Output "Removed: $Command"
        Write-Output "Count: $($cmds.Count)"
    }
    "clear" {
        Write-Allowlist @()
        Write-Output "Cleared allowlist: $shared"
    }
}
