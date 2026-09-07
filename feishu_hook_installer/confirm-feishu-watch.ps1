# Watch Feishu while Agent window ask is showing.
# First side to finish wins; the other side becomes a no-op.
param(
    [Parameter(Mandatory = $true)][string]$ConfirmId,
    [Parameter(Mandatory = $true)][string]$StatusUrl,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $false)][string]$DecideUrl = "",
    [Parameter(Mandatory = $false)][string]$MessageId = "",
    [Parameter(Mandatory = $false)][string]$LogPath = "",
    [Parameter(Mandatory = $false)][int]$TimeoutSec = 120
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Log([string]$msg) {
    if (-not $LogPath) { return }
    $line = "[{0}] watch {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}

function Get-Status {
    try {
        $stOut = & curl.exe -sS -m 8 -H "X-Notify-Token: $Token" $StatusUrl 2>&1
        $st = $stOut | ConvertFrom-Json
        return [string]$st.status
    } catch {
        return "pending"
    }
}

function Send-Decide([string]$decision, [string]$source) {
    if (-not $DecideUrl) { return }
    try {
        $bodyObj = @{ confirm_id = $ConfirmId; decision = $decision; source = $source }
        if ($MessageId) { $bodyObj.message_id = $MessageId }
        $body = $bodyObj | ConvertTo-Json -Compress
        $tmp = Join-Path $env:TEMP ("cursor-feishu-decide-" + $ConfirmId + ".json")
        [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
        $out = & curl.exe -sS -m 15 -X POST $DecideUrl -H "Content-Type: application/json" -H "X-Notify-Token: $Token" --data-binary "@$tmp" 2>&1
        Write-Log ("decide decision={0} source={1} resp={2}" -f $decision, $source, $out)
    } catch {
        Write-Log ("decide failed: {0}" -f $_.Exception.Message)
    }
}

function Test-NameMatch([string]$name, [string[]]$names, [bool]$allowContains) {
    if (-not $name) { return $false }
    $n = $name.Trim()
    foreach ($want in $names) {
        if ($n -eq $want) { return $true }
        # Avoid "Accept" matching "acceptance rate" etc.
        if ($allowContains -and ($n.StartsWith($want + " ") -or $n.EndsWith(" " + $want))) {
            return $true
        }
    }
    return $false
}

$script:AllowNames = @(
    "Run", "Allow", "Approve", "Accept", "Continue", "Confirm",
    "Allow once", "Run command", "Run everything", "Add to allowlist",
    "运行", "允许", "批准", "确认", "继续", "执行", "允许一次"
)
$script:DenyNames = @(
    "Deny", "Reject", "Skip", "Cancel", "Block",
    "拒绝", "取消", "跳过", "阻止"
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
    # Fallback: top-level windows whose title contains Cursor
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
                if (Test-NameMatch $name $script:AskNames $false) { return $true }
            }
        } catch {}
    }
    return $false
}

function Invoke-AgentButton([string[]]$names) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
    } catch {
        Write-Log ("uia load failed: {0}" -f $_.Exception.Message)
        return $false
    }

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
                if (-not (Test-NameMatch $name $names $false)) { continue }
                try {
                    $inv = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                    $inv.Invoke()
                    Write-Log ("clicked button name=$name")
                    return $true
                } catch {
                    Write-Log ("click failed name=$name err=$($_.Exception.Message)")
                }
            }
        } catch {
            Write-Log ("enum window failed: $($_.Exception.Message)")
        }
    }
    return $false
}

# Single-flight lock so two watchers never both click.
$claimPath = Join-Path $env:TEMP ("cursor-confirm-watch-" + $ConfirmId + ".lock")
try {
    $fs = [System.IO.File]::Open($claimPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.Close()
} catch {
    Write-Log "another watcher already claimed; exit"
    exit 0
}

Write-Log ("start confirm_id=$ConfirmId timeout=$TimeoutSec message_id=$MessageId")
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$seenAsk = $false
$acted = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $decision = Get-Status

    if ($decision -in @("allow", "deny", "cursor")) {
        if ($decision -eq "cursor") {
            Write-Log "Agent window already decided; skip Feishu click"
            $acted = $true
            break
        }
        if ($decision -eq "allow") {
            $ok = Invoke-AgentButton $script:AllowNames
            Write-Log ("feishu allow -> agent click ok=$ok")
        } else {
            $ok = Invoke-AgentButton $script:DenyNames
            Write-Log ("feishu deny -> agent click ok=$ok")
        }
        $acted = $true
        break
    }

    $askVisible = Test-AgentAskVisible
    if ($askVisible) {
        if (-not $seenAsk) { Write-Log "agent ask UI visible" }
        $seenAsk = $true
    } elseif ($seenAsk) {
        # Ask UI was shown then disappeared without Feishu decision => Agent side won.
        Write-Log "Agent ask UI closed first; mark cursor winner"
        Send-Decide "cursor" "agent_window"
        $acted = $true
        break
    }
}

if (-not $acted) {
    Write-Log "watch end without action (server will still auto-resolve on next confirm/stop)"
}
try { Remove-Item -LiteralPath $claimPath -Force -ErrorAction SilentlyContinue } catch {}
exit 0
