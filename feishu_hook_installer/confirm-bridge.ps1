# Peer confirm bridge for Windows Cursor UI (local + Remote SSH).
# Remote Linux hooks return ask and send Feishu cards; this process runs on the
# Windows machine that shows the Agent window and:
#   - Feishu allow/deny  -> UIA-click Agent buttons
#   - Agent UI closed first -> POST decide cursor (update Feishu card)
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$hookDir = $PSScriptRoot
if (-not $hookDir) { $hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $hookDir "notify-feishu.log"
$configPath = Join-Path $hookDir "notify.env"
$lockPath = Join-Path $env:TEMP "cursor-feishu-confirm-bridge.lock"

function Write-Log([string]$msg) {
    $line = "[{0}] bridge {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
}

# Single instance
try {
    $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $sw = New-Object System.IO.StreamWriter($fs)
    $sw.WriteLine($PID)
    $sw.Flush()
} catch {
    exit 0
}

function Release-Lock {
    try { if ($sw) { $sw.Close() } } catch {}
    try { if ($fs) { $fs.Close() } } catch {}
    try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch {}
}
Register-EngineEvent PowerShell.Exiting -Action { Release-Lock } | Out-Null

$url = ""
$token = ""
Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
    $line = $_.Trim().TrimStart([char]0xFEFF)
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $i = $line.IndexOf("=")
        $k = $line.Substring(0, $i).Trim()
        $v = $line.Substring($i + 1).Trim()
        if ($k -eq "NOTIFY_URL") { $url = $v }
        if ($k -eq "NOTIFY_TOKEN") { $token = $v }
    }
}
if (-not $url -or -not $token) {
    Write-Log "missing notify.env"
    Release-Lock
    exit 0
}

$pendingUrl = ($url -replace "/local-notify$", "/local-confirm/pending")
$decideUrl = ($url -replace "/local-notify$", "/local-confirm/decide")

function Test-NameMatch([string]$name, [string[]]$names) {
    if (-not $name) { return $false }
    $n = $name.Trim()
    foreach ($want in $names) {
        if ($n -eq $want) { return $true }
    }
    return $false
}

$script:AllowNames = @(
    "Run", "Allow", "Approve", "Accept", "Continue", "Confirm",
    "Allow once", "Run command", "Run everything", "Always Run"
)
$script:DenyNames = @(
    "Deny", "Reject", "Skip", "Cancel", "Block"
)
$script:AskNames = $script:AllowNames + $script:DenyNames

function Get-CursorWindows($root) {
    $list = New-Object System.Collections.Generic.List[object]
    $procs = @(Get-Process -Name "Cursor","Cursor Agent" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            $winCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
            $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
            foreach ($win in $wins) { $list.Add($win) }
        } catch {}
    }
    try {
        $trueCond = [System.Windows.Automation.Condition]::TrueCondition
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $trueCond)
        foreach ($win in $all) {
            try {
                $title = [string]$win.Current.Name
                if ($title -and ($title -like "*Cursor*")) { $list.Add($win) }
            } catch {}
        }
    } catch {}
    return $list
}

function Test-AgentAskVisible {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
    } catch { return $false }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $btnType = [System.Windows.Automation.ControlType]::Button
    $condType = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $btnType)
    foreach ($win in (Get-CursorWindows $root)) {
        try {
            $buttons = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condType)
            foreach ($btn in $buttons) {
                $name = ""
                try { $name = [string]$btn.Current.Name } catch { continue }
                if (Test-NameMatch $name $script:AskNames) { return $true }
            }
        } catch {}
    }
    return $false
}

function Invoke-AgentButton([string[]]$names) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
    } catch { return $false }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $btnType = [System.Windows.Automation.ControlType]::Button
    $condType = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $btnType)
    foreach ($win in (Get-CursorWindows $root)) {
        try {
            $buttons = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condType)
            foreach ($btn in $buttons) {
                $name = ""
                try { $name = [string]$btn.Current.Name } catch { continue }
                if (-not (Test-NameMatch $name $names)) { continue }
                try {
                    $inv = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                    $inv.Invoke()
                    Write-Log ("clicked button name=$name")
                    return $true
                } catch {}
            }
        } catch {}
    }
    return $false
}

function Send-Decide([string]$confirmId, [string]$decision, [string]$source, [string]$messageId) {
    try {
        $bodyObj = @{ confirm_id = $confirmId; decision = $decision; source = $source }
        if ($messageId) { $bodyObj.message_id = $messageId }
        $body = $bodyObj | ConvertTo-Json -Compress
        $tmp = Join-Path $env:TEMP ("cursor-feishu-bridge-decide-" + $confirmId + ".json")
        [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
        $out = & curl.exe -sS -m 15 -X POST $decideUrl -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp" 2>&1
        Write-Log ("decide id={0} decision={1} source={2} resp={3}" -f $confirmId, $decision, $source, $out)
    } catch {
        Write-Log ("decide failed: {0}" -f $_.Exception.Message)
    }
}

function Get-PendingItems {
    try {
        $raw = & curl.exe -sS -m 10 -H "X-Notify-Token: $token" $pendingUrl 2>&1
        $obj = $raw | ConvertFrom-Json
        if ($obj.items) { return @($obj.items) }
    } catch {}
    return @()
}

Write-Log "start pid=$PID pending=$pendingUrl"
$state = @{}

while ($true) {
    try {
        if (-not (Get-Process -Name "Cursor" -ErrorAction SilentlyContinue)) {
            Start-Sleep -Seconds 3
            continue
        }
        $items = Get-PendingItems
        $alive = @{}
        foreach ($it in $items) {
            $cid = [string]$it.confirm_id
            if (-not $cid) { continue }
            $alive[$cid] = $true
            if (-not $state.ContainsKey($cid)) {
                $state[$cid] = @{ seenAsk = $false; acted = $false }
            }
            $st = $state[$cid]
            if ($st.acted) { continue }

            $status = [string]$it.status
            $msgId = [string]$it.message_id

            if ($status -eq "allow") {
                $ok = Invoke-AgentButton $script:AllowNames
                Write-Log ("feishu allow -> click ok=$ok id=$cid")
                $st.acted = $true
                continue
            }
            if ($status -eq "deny") {
                $ok = Invoke-AgentButton $script:DenyNames
                Write-Log ("feishu deny -> click ok=$ok id=$cid")
                $st.acted = $true
                continue
            }
            if ($status -eq "cursor") {
                $st.acted = $true
                continue
            }

            $ask = Test-AgentAskVisible
            if ($ask) {
                if (-not $st.seenAsk) { Write-Log ("ask UI visible id=$cid") }
                $st.seenAsk = $true
            } elseif ($st.seenAsk) {
                Write-Log ("ask UI closed first; mark cursor id=$cid")
                Send-Decide $cid "cursor" "agent_window" $msgId
                $st.acted = $true
            }
        }
        foreach ($k in @($state.Keys)) {
            if (-not $alive.ContainsKey($k)) { $state.Remove($k) }
        }
    } catch {
        Write-Log ("loop err: {0}" -f $_.Exception.Message)
    }
    Start-Sleep -Seconds 1
}
