# Watch Feishu while Agent window ask is showing.
# First side to finish wins; the other side becomes a no-op.
param(
    [Parameter(Mandatory = $true)][string]$ConfirmId,
    [Parameter(Mandatory = $true)][string]$StatusUrl,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $false)][string]$DecideUrl = "",
    [Parameter(Mandatory = $false)][string]$MessageId = "",
    [Parameter(Mandatory = $false)][string]$LogPath = "",
    [Parameter(Mandatory = $false)][string]$ConversationId = "",
    [Parameter(Mandatory = $false)][int]$TimeoutSec = 120
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if ($LogPath) {
    $rotatePs1 = Join-Path (Split-Path -Parent $LogPath) "log-rotate.ps1"
    if (Test-Path -LiteralPath $rotatePs1) {
        try { . $rotatePs1 } catch {}
    }
}

function Write-Log([string]$msg) {
    if (-not $LogPath) { return }
    $line = "[{0}] watch {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try {
        if (Get-Command Rotate-NotifyLog -ErrorAction SilentlyContinue) {
            Rotate-NotifyLog -LogFile $LogPath
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {}
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

$script:AlwaysNames = @(
    "Always Run", "Always Allow", "Always approve", "Add to allowlist", "Add to Allowlist"
)
$script:AllowNames = @(
    "Run", "Allow", "Approve", "Accept", "Continue", "Confirm",
    "Allow once", "Run command", "Run All"
)
$script:DenyNames = @(
    "Skip", "Deny", "Reject", "Cancel", "Block"
)
$script:AskNames = $script:AlwaysNames + $script:AllowNames + $script:DenyNames

$script:ConfirmDetail = ""
try {
    $st0 = & curl.exe -sS -m 15 -H "X-Notify-Token: $Token" $StatusUrl 2>$null | ConvertFrom-Json
    if ($st0.detail) { $script:ConfirmDetail = [string]$st0.detail }
    if ($st0.conversation_id -and -not $ConversationId) { $ConversationId = [string]$st0.conversation_id }
} catch {}


function Arm-LocalAlwaysRun([string]$convId, [string]$command = "") {
    if (-not $convId) { return }
    try {
        $localHookDir = Split-Path -Parent $LogPath
        if (-not $localHookDir) { $localHookDir = $PSScriptRoot }
        $dir = Join-Path $localHookDir "always-run"
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $safe = ($convId -replace "[^\w\-]", "_")
        $flag = Join-Path $dir $safe
        $cmds = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $flag) {
            try {
                $raw = [System.IO.File]::ReadAllText($flag, [System.Text.Encoding]::UTF8).Trim()
                $obj = $raw | ConvertFrom-Json
                foreach ($c in @($obj.commands)) { if ($c) { [void]$cmds.Add([string]$c) } }
            } catch {}
        }
        if ($command -and ($cmds -notcontains $command)) { [void]$cmds.Add($command) }
        $json = (@{ commands = @($cmds) } | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($flag, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Log ("armed local always-run conv=$convId cmd=$command n=$($cmds.Count)")
    } catch {
        Write-Log ("arm always-run failed: {0}" -f $_.Exception.Message)
    }
}

function Test-IsAlwaysName([string]$name) {
    if (-not $name) { return $false }
    if (Test-NameMatch $name $script:AlwaysNames $false) { return $true }
    $t = $name.Trim()
    return ($t -like "Always Run*" -or $t -like "Always Allow*" -or $t -like "Add to allowlist*")
}

function Get-AgentApprovalChoice {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
    } catch { return "" }

    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        $pt = [System.Windows.Forms.Cursor]::Position
        $el = [System.Windows.Automation.AutomationElement]::FromPoint(
            (New-Object System.Windows.Point([double]$pt.X, [double]$pt.Y)))
        $cur = $el
        for ($i = 0; $i -lt 5 -and $cur; $i++) {
            try {
                $n = [string]$cur.Current.Name
                if ($n) { $candidates.Add($n) }
            } catch {}
            try { $cur = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($cur) } catch { break }
        }
    } catch {}
    try {
        $fe = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($fe) {
            $n = ""
            try { $n = [string]$fe.Current.Name } catch { $n = "" }
            if ($n) { $candidates.Add($n) }
        }
    } catch {}
    foreach ($n in $candidates) {
        if (Test-IsAlwaysName $n) { return "always" }
    }
    foreach ($n in $candidates) {
        if (Test-NameMatch $n $script:DenyNames $false) { return "deny" }
    }
    foreach ($n in $candidates) {
        if ((Test-NameMatch $n $script:AllowNames $false) -and -not (Test-IsAlwaysName $n)) { return "allow" }
    }
    return ""
}

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

Write-Log ("start confirm_id=$ConfirmId timeout=$TimeoutSec message_id=$MessageId conv=$ConversationId")
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$seenAsk = $false
$acted = $false
$lastChoice = ""

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $decision = Get-Status

    if ($decision -in @("allow", "always", "deny", "cursor")) {
        if ($decision -eq "cursor") {
            Write-Log "Agent window already decided; skip Feishu click"
            $acted = $true
            break
        }
        if ($decision -eq "always") {
            $ok = Invoke-AgentButton $script:AlwaysNames
            if (-not $ok) { $ok = Invoke-AgentButton $script:AllowNames }
            Write-Log ("feishu always -> agent click ok=$ok")
            try {
                $stA = & curl.exe -sS -m 15 -H "X-Notify-Token: $Token" $StatusUrl 2>$null | ConvertFrom-Json
                if ($stA.detail) { $script:ConfirmDetail = [string]$stA.detail }
                if ($stA.allowlist) {
                    foreach ($c in @($stA.allowlist)) {
                        Arm-LocalAlwaysRun $ConversationId ([string]$c)
                    }
                }
            } catch {}
            Arm-LocalAlwaysRun $ConversationId $script:ConfirmDetail
        } elseif ($decision -eq "allow") {
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
        $choice = Get-AgentApprovalChoice
        if ($choice) { $lastChoice = $choice }
    } elseif ($seenAsk) {
        $dec = "cursor"
        if ($lastChoice -eq "always") { $dec = "always" }
        elseif ($lastChoice -eq "deny") { $dec = "deny" }
        elseif ($lastChoice -eq "allow") { $dec = "allow" }
        Write-Log ("Agent ask UI closed first; mark $dec lastChoice=$lastChoice")
        Send-Decide $dec "agent_window"
        if ($dec -eq "always") { Arm-LocalAlwaysRun $ConversationId $script:ConfirmDetail }
        $acted = $true
        break
    }
}

if (-not $acted) {
    Write-Log "watch end without action (server will still auto-resolve on next confirm/stop)"
}
try { Remove-Item -LiteralPath $claimPath -Force -ErrorAction SilentlyContinue } catch {}
exit 0
