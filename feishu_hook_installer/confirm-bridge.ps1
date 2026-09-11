# Peer confirm bridge for Windows Cursor UI (local + Remote SSH).
# Remote Linux hooks return ask and send Feishu cards; this process runs on the
# Windows machine that shows the Agent window and:
#   - Feishu allow/always/deny  -> UIA-click Agent buttons (retry until success)
#   - Agent Always Run / Run / Skip first -> POST decide + arm local always-run flag
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$hookDir = $PSScriptRoot
if (-not $hookDir) { $hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $hookDir "notify-feishu.log"
$configPath = Join-Path $hookDir "notify.env"
$lockPath = Join-Path $env:TEMP "cursor-feishu-confirm-bridge.lock"
$logRotatePs1 = Join-Path $hookDir "log-rotate.ps1"
if (Test-Path -LiteralPath $logRotatePs1) {
    try { . $logRotatePs1 } catch {}
}

function Write-Log([string]$msg) {
    $line = "[{0}] bridge {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try {
        if (Get-Command Rotate-NotifyLog -ErrorAction SilentlyContinue) {
            Rotate-NotifyLog -LogFile $logPath
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {}
}

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
$alwaysRunDir = Join-Path $hookDir "always-run"

function Get-SharedAlwaysRunPath([string]$baseHookDir) {
    $dir = Join-Path $baseHookDir "always-run"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return (Join-Path $dir "shared.json")
}

function Merge-LegacyAlwaysRunFiles([string]$baseHookDir, [System.Collections.Generic.List[string]]$cmds) {
    $dir = Join-Path $baseHookDir "always-run"
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -eq "shared.json") { return }
        try {
            $raw = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8).Trim()
            if (-not $raw) { return }
            try {
                $obj = $raw | ConvertFrom-Json
                foreach ($c in @($obj.commands)) {
                    if ($c -and ($cmds -notcontains [string]$c)) { [void]$cmds.Add([string]$c) }
                }
            } catch {
                # legacy plain conversation-id file => treat as chat-wide "*"
                if ($raw -and ($cmds -notcontains "*")) { [void]$cmds.Add("*") }
            }
        } catch {}
    }
}

function Arm-LocalAlwaysRun([string]$convId, [string]$command = "") {
    # Machine-wide allowlist: shared by all Agents on this PC.
    try {
        if (-not $command) { $command = "*" }
        $base = $hookDir
        if (-not $base) { $base = $PSScriptRoot }
        $flag = Get-SharedAlwaysRunPath $base
        $cmds = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $flag) {
            try {
                $raw = [System.IO.File]::ReadAllText($flag, [System.Text.Encoding]::UTF8).Trim()
                $obj = $raw | ConvertFrom-Json
                foreach ($c in @($obj.commands)) { if ($c) { [void]$cmds.Add([string]$c) } }
            } catch {}
        }
        Merge-LegacyAlwaysRunFiles $base $cmds
        if ($command -and ($cmds -notcontains $command)) { [void]$cmds.Add($command) }
        $json = (@{ commands = @($cmds); scope = "machine"; permanent = $true } | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($flag, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Log ("armed local always-run scope=machine permanent cmd=$command n=$($cmds.Count) conv=$convId")
    } catch {
        Write-Log ("arm always-run failed: {0}" -f $_.Exception.Message)
    }
}

function Test-NameMatch([string]$name, [string[]]$names) {
    if (-not $name) { return $false }
    $n = $name.Trim()
    foreach ($want in $names) {
        if ($n -eq $want) { return $true }
        if ($n.StartsWith($want + " ")) { return $true }
    }
    return $false
}

function Test-IsAlwaysName([string]$name) {
    return (Test-NameMatch $name $script:AlwaysNames)
}

function Ensure-Uia {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
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

function Get-InteractiveElements($win) {
    $out = New-Object System.Collections.Generic.List[object]
    $types = @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::Hyperlink,
        [System.Windows.Automation.ControlType]::MenuItem,
        [System.Windows.Automation.ControlType]::SplitButton,
        [System.Windows.Automation.ControlType]::ListItem,
        [System.Windows.Automation.ControlType]::Custom,
        [System.Windows.Automation.ControlType]::Text
    )
    foreach ($t in $types) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $t)
            $els = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
            foreach ($el in $els) { $out.Add($el) }
        } catch {}
    }
    return $out
}

function Test-AgentAskVisible {
    try { Ensure-Uia } catch { return $false }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($win in (Get-CursorWindows $root)) {
        foreach ($el in (Get-InteractiveElements $win)) {
            $name = ""
            try { $name = [string]$el.Current.Name } catch { continue }
            if (Test-NameMatch $name $script:AskNames) { return $true }
        }
    }
    return $false
}

function Get-AgentApprovalChoice {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
    } catch { return "" }

    $candidates = New-Object System.Collections.Generic.List[string]
    $pt = $null
    try { $pt = [System.Windows.Forms.Cursor]::Position } catch { $pt = $null }

    # 1) Element under mouse + parents
    try {
        if ($pt) {
            $el = [System.Windows.Automation.AutomationElement]::FromPoint(
                (New-Object System.Windows.Point([double]$pt.X, [double]$pt.Y)))
            $cur = $el
            for ($i = 0; $i -lt 6 -and $cur; $i++) {
                try {
                    $n = [string]$cur.Current.Name
                    if ($n) { $candidates.Add($n) }
                } catch {}
                try { $cur = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($cur) } catch { break }
            }
        }
    } catch {}

    # 2) Focused element
    try {
        $fe = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($fe) {
            $n = ""
            try { $n = [string]$fe.Current.Name } catch { $n = "" }
            if ($n) { $candidates.Add($n) }
        }
    } catch {}

    # 3) Hit-test Cursor windows: any approval button whose rect contains the mouse
    try {
        if ($pt -and (Get-Command Get-CursorWindows -ErrorAction SilentlyContinue)) {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            foreach ($win in (Get-CursorWindows $root)) {
                $els = @()
                if (Get-Command Get-InteractiveElements -ErrorAction SilentlyContinue) {
                    $els = @(Get-InteractiveElements $win)
                }
                foreach ($el in $els) {
                    $n = ""
                    try { $n = [string]$el.Current.Name } catch { continue }
                    if (-not $n) { continue }
                    $isApproval = (Test-IsAlwaysName $n) -or (Test-NameMatch $n $script:AllowNames) -or (Test-NameMatch $n $script:DenyNames)
                    if (-not $isApproval) { continue }
                    try {
                        $r = $el.Current.BoundingRectangle
                        if ($pt.X -ge $r.X -and $pt.X -le ($r.X + $r.Width) -and $pt.Y -ge $r.Y -and $pt.Y -le ($r.Y + $r.Height)) {
                            $candidates.Insert(0, $n)
                        }
                    } catch {}
                }
            }
        }
    } catch {}

    foreach ($n in $candidates) {
        if (Test-IsAlwaysName $n) { return "always" }
        if ($n.Trim() -like "Always Run*" -or $n.Trim() -like "Always Allow*" -or $n.Trim() -like "Add to allowlist*" -or $n -match "始终|总是运行|总是允许") {
            return "always"
        }
    }
    foreach ($n in $candidates) {
        if (Test-NameMatch $n $script:DenyNames) { return "deny" }
    }
    foreach ($n in $candidates) {
        if ((Test-NameMatch $n $script:AllowNames) -and -not (Test-IsAlwaysName $n)) { return "allow" }
    }
    return ""
}

function Try-ClickElement($el, [string]$name) {
    # 1) InvokePattern
    try {
        $inv = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $inv.Invoke()
        Write-Log ("clicked invoke name=$name")
        return $true
    } catch {}
    # 2) LegacyIAccessible default action
    try {
        $accType = [Type]::GetType("System.Windows.Automation.LegacyIAccessiblePattern, UIAutomationClient")
        if ($accType) {
            $patField = $accType.GetField("Pattern")
            $pattern = $el.GetCurrentPattern($patField.GetValue($null))
            if ($pattern) {
                $pattern.DoDefaultAction()
                Write-Log ("clicked legacy name=$name")
                return $true
            }
        }
    } catch {}
    # 3) Mouse click clickable point
    try {
        $pt = $el.GetClickablePoint()
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point([int]$pt.X, [int]$pt.Y)
        Start-Sleep -Milliseconds 40
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class BridgeMouse {
  [DllImport("user32.dll")] public static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
  public const int LEFTDOWN = 0x0002;
  public const int LEFTUP = 0x0004;
  public static void Click() { mouse_event(LEFTDOWN, 0, 0, 0, 0); mouse_event(LEFTUP, 0, 0, 0, 0); }
}
"@ -ErrorAction SilentlyContinue
        [BridgeMouse]::Click()
        Write-Log ("clicked mouse name=$name x=$([int]$pt.X) y=$([int]$pt.Y)")
        return $true
    } catch {
        Write-Log ("click fail name=$name err=$($_.Exception.Message)")
    }
    return $false
}

function Try-SendKeysAllow {
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
        $procs = @(Get-Process -Name "Cursor" -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            try {
                [Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
                Start-Sleep -Milliseconds 80
                # Common approval shortcuts in review UI
                [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
                Start-Sleep -Milliseconds 120
                Write-Log "sent Enter to Cursor"
                return $true
            } catch {}
        }
    } catch {
        Write-Log ("SendKeys failed: {0}" -f $_.Exception.Message)
    }
    return $false
}

function Invoke-AgentButton([string[]]$names, [switch]$PreferAlways, [switch]$ExcludeAlways, [switch]$NoSendKeys) {
    try { Ensure-Uia } catch {
        Write-Log ("uia load failed: {0}" -f $_.Exception.Message)
        return $false
    }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($win in (Get-CursorWindows $root)) {
        foreach ($el in (Get-InteractiveElements $win)) {
            $name = ""
            try { $name = [string]$el.Current.Name } catch { continue }
            if (-not $name) { continue }
            if ($found.Count -lt 40) { $found.Add($name) }
            if ($ExcludeAlways -and (Test-IsAlwaysName $name)) { continue }
            if (-not (Test-NameMatch $name $names)) { continue }
            if (Try-ClickElement $el $name) { return $true }
        }
    }
    if ($found.Count -gt 0) {
        Write-Log ("no clickable match; sample names: " + (($found | Select-Object -Unique | Select-Object -First 25) -join " | "))
    } else {
        Write-Log "no interactive elements found in Cursor windows"
    }
    # Enter usually activates primary Run — only use for once-allow, not Always/Deny.
    if (-not $NoSendKeys -and -not $PreferAlways) {
        if (Try-SendKeysAllow) { return $true }
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
        # Prefer newest first so the active ask UI is handled before stale allows.
        $items = @($items | Sort-Object { $_.created } -Descending)
        foreach ($it in $items) {
            $cid = [string]$it.confirm_id
            if (-not $cid) { continue }
            $alive[$cid] = $true
            if (-not $state.ContainsKey($cid)) {
                $state[$cid] = @{ seenAsk = $false; acted = $false; failCount = 0; lastChoice = "" }
            }
            $st = $state[$cid]
            if ($st.acted) { continue }

            $status = [string]$it.status
            $msgId = [string]$it.message_id

            if ($status -eq "always") {
                $ok = Invoke-AgentButton $script:AlwaysNames -PreferAlways -NoSendKeys
                if ($ok) {
                    Write-Log ("feishu always -> click ok id=$cid")
                    Arm-LocalAlwaysRun ([string]$it.conversation_id) ([string]$it.detail)
                    $st.acted = $true
                } else {
                    # Fallback: once-Run still unblocks Agent; server already auto-allows later.
                    $ok2 = Invoke-AgentButton $script:AllowNames -ExcludeAlways
                    if ($ok2) {
                        Write-Log ("feishu always -> fallback Run click ok id=$cid")
                        Arm-LocalAlwaysRun ([string]$it.conversation_id) ([string]$it.detail)
                        $st.acted = $true
                    } else {
                        $st.failCount++
                        Write-Log ("feishu always -> click fail id=$cid n=$($st.failCount)")
                        if ($st.failCount -ge 45) { $st.acted = $true }
                    }
                }
                continue
            }
            if ($status -eq "allow") {
                $ok = Invoke-AgentButton $script:AllowNames -ExcludeAlways
                if ($ok) {
                    Write-Log ("feishu allow -> click ok id=$cid")
                    $st.acted = $true
                } else {
                    $st.failCount++
                    Write-Log ("feishu allow -> click fail id=$cid n=$($st.failCount)")
                    # Keep retrying while ask UI likely still open.
                    if ($st.failCount -ge 45) { $st.acted = $true }
                }
                continue
            }
            if ($status -eq "deny") {
                $ok = Invoke-AgentButton $script:DenyNames -NoSendKeys
                if ($ok) {
                    Write-Log ("feishu deny -> click ok id=$cid")
                    $st.acted = $true
                } else {
                    $st.failCount++
                    Write-Log ("feishu deny -> click fail id=$cid n=$($st.failCount)")
                    if ($st.failCount -ge 45) { $st.acted = $true }
                }
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
                $choice = Get-AgentApprovalChoice
                if ($choice) {
                    if ($choice -eq "always") { $st.lastChoice = "always" }
                    elseif ($choice -eq "deny") { $st.lastChoice = "deny" }
                    elseif ($st.lastChoice -ne "always") { $st.lastChoice = $choice }
                }
            } elseif ($st.seenAsk) {
                # Agent window decided first. If user picked Always Run, arm session silent-allow.
                $dec = "cursor"
                if ($st.lastChoice -eq "always") { $dec = "always" }
                elseif ($st.lastChoice -eq "deny") { $dec = "deny" }
                elseif ($st.lastChoice -eq "allow") { $dec = "allow" }
                Write-Log ("ask UI closed first; mark $dec id=$cid lastChoice=$($st.lastChoice)")
                Send-Decide $cid $dec "agent_window" $msgId
                if ($dec -eq "always") {
                    Arm-LocalAlwaysRun ([string]$it.conversation_id) ([string]$it.detail)
                }
                $st.acted = $true
            }
        }
        foreach ($k in @($state.Keys)) {
            if (-not $alive.ContainsKey($k)) { $state.Remove($k) }
        }
    } catch {
        Write-Log ("loop err: {0}" -f $_.Exception.Message)
    }
    # Poll faster while an ask UI is up so mouse-over Always Run is not missed.
    $fast = $false
    foreach ($k in @($state.Keys)) {
        if ($state[$k].seenAsk -and -not $state[$k].acted) { $fast = $true; break }
    }
    if ($fast) { Start-Sleep -Milliseconds 80 } else { Start-Sleep -Seconds 1 }
}
