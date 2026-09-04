# Confirm a local tool/shell action via Feishu OR a local dialog (whichever first).
# Returns Cursor hook JSON: {"permission":"allow|deny"}
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$hookDir = $PSScriptRoot
if (-not $hookDir) { $hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $hookDir "notify-feishu.log"

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
}

function Read-HookInput {
    $raw = ""
    try {
        $stdin = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdin, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
    } catch {}
    if ([string]::IsNullOrWhiteSpace($raw)) {
        try { $raw = [string]($input | Out-String) } catch {}
    }
    if ($null -eq $raw) { $raw = "" }
    return [string]$raw.TrimStart([char]0xFEFF)
}

function Write-Perm([string]$perm) {
    # Only JSON on stdout — Cursor parses this as the hook result.
    [Console]::Out.WriteLine(('{{"permission":"{0}","continue":true}}' -f $perm))
}

$raw = Read-HookInput
Write-Log ("confirm hook stdin_len={0}" -f $raw.Length)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Perm "deny"
    exit 0
}

try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Log ("confirm json failed: {0}" -f $_.Exception.Message)
    Write-Perm "deny"
    exit 0
}

$configPath = Join-Path $hookDir "notify.env"
$url = ""
$token = ""
Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
    $line = $_.Trim().TrimStart([char]0xFEFF)
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $i = $line.IndexOf("=")
        $k = $line.Substring(0, $i).Trim().TrimStart([char]0xFEFF)
        $v = $line.Substring($i + 1).Trim()
        if ($k -eq "NOTIFY_URL") { $url = $v }
        if ($k -eq "NOTIFY_TOKEN") { $token = $v }
    }
}
if (-not $url -or -not $token) {
    Write-Log "confirm missing notify.env"
    Write-Perm "deny"
    exit 0
}

$id = [string]$data.conversation_id
if (-not $id) { $id = [string]$data.session_id }
if (-not $id) { $id = "local-agent" }
$workspace = ""
if ($data.workspace_roots) { $workspace = [string]@($data.workspace_roots)[0] }
$chatName = [string]$data.conversation_title
if (-not $chatName) { $chatName = [string]$data.title }
if (-not $chatName -and $workspace) { $chatName = Split-Path -Path $workspace -Leaf }
$detail = [string]$data.command
if (-not $detail) { $detail = [string]$data.tool_name }
if (-not $detail) { $detail = "tool" }
if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + "..." }

$reqUrl = $url -replace "/local-notify$", "/local-confirm/request"
$reqObj = @{
    id              = $id
    conversation_id = $id
    workspace       = $workspace
    chat_name       = $chatName
    machine         = $env:COMPUTERNAME
    detail          = $detail
}
$reqJson = $reqObj | ConvertTo-Json -Compress
$tmp = Join-Path $env:TEMP "cursor-feishu-confirm-req.json"
[System.IO.File]::WriteAllText($tmp, $reqJson, [System.Text.UTF8Encoding]::new($false))
$reqOut = & curl.exe -sS -m 30 -X POST $reqUrl -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp" 2>&1
Write-Log ("confirm request: {0}" -f $reqOut)

$confirmId = ""
try {
    $reqParsed = $reqOut | ConvertFrom-Json
    $confirmId = [string]$reqParsed.confirm_id
} catch {}
if (-not $confirmId) {
    Write-Log "confirm_id missing, deny"
    Write-Perm "deny"
    exit 0
}

$statusUrl = ($url -replace "/local-notify$", "/local-confirm/status/") + $confirmId
$decision = "pending"

# Race: Feishu card button OR local Allow/Deny dialog.
try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Cursor confirm"
    $form.Size = New-Object System.Drawing.Size(520, 260)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(470, 140)
    $label.Text = "Allow this action?`r`n`r`n$detail`r`n`r`nConfirm here OR in Feishu (either is enough)."
    $form.Controls.Add($label)

    $btnAllow = New-Object System.Windows.Forms.Button
    $btnAllow.Text = "Allow"
    $btnAllow.Location = New-Object System.Drawing.Point(250, 170)
    $btnAllow.Size = New-Object System.Drawing.Size(100, 32)
    $btnAllow.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($btnAllow)
    $form.AcceptButton = $btnAllow

    $btnDeny = New-Object System.Windows.Forms.Button
    $btnDeny.Text = "Deny"
    $btnDeny.Location = New-Object System.Drawing.Point(370, 170)
    $btnDeny.Size = New-Object System.Drawing.Size(100, 32)
    $btnDeny.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($btnDeny)
    $form.CancelButton = $btnDeny

    $script:pollToken = $token
    $script:pollUrl = $statusUrl
    $script:pollDecision = "pending"
    $script:confirmForm = $form
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $script:confirmTimer = $timer
    $timer.Add_Tick({
        try {
            $stOut = & curl.exe -sS -m 8 -H "X-Notify-Token: $script:pollToken" $script:pollUrl 2>&1
            $st = $stOut | ConvertFrom-Json
            $d = [string]$st.status
            if ($d -and $d -ne "pending" -and $d -ne "unknown") {
                $script:pollDecision = $d
                if ($script:confirmTimer) { $script:confirmTimer.Stop() }
                if ($script:confirmForm -and -not $script:confirmForm.IsDisposed) {
                    if ($d -eq "allow") {
                        $script:confirmForm.DialogResult = [System.Windows.Forms.DialogResult]::Yes
                    } else {
                        $script:confirmForm.DialogResult = [System.Windows.Forms.DialogResult]::No
                    }
                    $script:confirmForm.Close()
                }
            }
        } catch {}
    })
    $timer.Start()

    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    if ($script:confirmTimer) {
        $script:confirmTimer.Stop()
        $script:confirmTimer.Dispose()
    }
    if ($form -and -not $form.IsDisposed) { $form.Dispose() }

    if ($script:pollDecision -eq "allow" -or $result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $decision = "allow"
    } elseif ($script:pollDecision -eq "deny" -or $result -eq [System.Windows.Forms.DialogResult]::No) {
        $decision = "deny"
    } else {
        $decision = "deny"
    }
} catch {
    Write-Log ("confirm UI failed, Feishu-only poll: {0}" -f $_.Exception.Message)
    $deadline = (Get-Date).AddSeconds(100)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $stOut = & curl.exe -sS -m 10 -H "X-Notify-Token: $token" $statusUrl 2>&1
        try {
            $st = $stOut | ConvertFrom-Json
            $decision = [string]$st.status
        } catch { $decision = "pending" }
        if ($decision -and $decision -ne "pending" -and $decision -ne "unknown") { break }
    }
}

# Tell server if local dialog decided, so Feishu card state stays consistent.
if ($decision -eq "allow" -or $decision -eq "deny") {
    try {
        $pushUrl = $url -replace "/local-notify$", "/local-confirm/decide"
        $pushObj = @{ confirm_id = $confirmId; decision = $decision } | ConvertTo-Json -Compress
        $pushTmp = Join-Path $env:TEMP "cursor-feishu-confirm-decide.json"
        [System.IO.File]::WriteAllText($pushTmp, $pushObj, [System.Text.UTF8Encoding]::new($false))
        $null = & curl.exe -sS -m 10 -X POST $pushUrl -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$pushTmp" 2>&1
    } catch {}
}

Write-Log ("confirm decision={0} id={1}" -f $decision, $confirmId)

if ($decision -eq "allow") { Write-Perm "allow"; exit 0 }
Write-Perm "deny"
exit 0
