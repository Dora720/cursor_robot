# Watch Feishu while Agent window ask is showing.
# First side to finish wins; the other side becomes a no-op.
param(
    [Parameter(Mandatory = $true)][string]$ConfirmId,
    [Parameter(Mandatory = $true)][string]$StatusUrl,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $false)][string]$DecideUrl = "",
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
        $body = @{ confirm_id = $ConfirmId; decision = $decision; source = $source } | ConvertTo-Json -Compress
        $tmp = Join-Path $env:TEMP ("cursor-feishu-decide-" + $ConfirmId + ".json")
        [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
        $null = & curl.exe -sS -m 8 -X POST $DecideUrl -H "Content-Type: application/json" -H "X-Notify-Token: $Token" --data-binary "@$tmp" 2>&1
    } catch {}
}

function Test-AgentAskVisible {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop | Out-Null
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop | Out-Null
    } catch { return $false }

    $names = @(
        "Run", "Allow", "Approve", "Accept", "Continue", "Confirm",
        "Deny", "Reject", "Skip", "Cancel",
        "运行", "允许", "批准", "确认", "继续", "执行", "拒绝", "取消"
    )
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $btnType = [System.Windows.Automation.ControlType]::Button
    $condType = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $btnType)
    $procs = @(Get-Process -Name "Cursor","Cursor Agent" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            $winCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
            $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
            foreach ($win in $wins) {
                $buttons = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condType)
                foreach ($btn in $buttons) {
                    $name = ""
                    try { $name = [string]$btn.Current.Name } catch { continue }
                    foreach ($want in $names) {
                        if ($name -eq $want -or $name -like "*$want*") { return $true }
                    }
                }
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
    $procs = @(Get-Process -Name "Cursor","Cursor Agent" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            $winCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
            $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
            foreach ($win in $wins) {
                $buttons = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condType)
                foreach ($btn in $buttons) {
                    $name = ""
                    try { $name = [string]$btn.Current.Name } catch { continue }
                    if (-not $name) { continue }
                    foreach ($want in $names) {
                        if ($name -eq $want -or $name -like "*$want*") {
                            try {
                                $inv = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                                $inv.Invoke()
                                Write-Log ("clicked button name=$name pid=$($p.Id)")
                                return $true
                            } catch {
                                Write-Log ("click failed name=$name err=$($_.Exception.Message)")
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Log ("enum pid=$($p.Id) failed: $($_.Exception.Message)")
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

Write-Log ("start confirm_id=$ConfirmId timeout=$TimeoutSec")
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
            $ok = Invoke-AgentButton @(
                "Run", "Allow", "Approve", "Accept", "Continue", "Confirm",
                "运行", "允许", "批准", "确认", "继续", "执行"
            )
            Write-Log ("feishu allow -> agent click ok=$ok")
        } else {
            $ok = Invoke-AgentButton @(
                "Deny", "Reject", "Skip", "Cancel", "Block",
                "拒绝", "取消", "跳过", "阻止"
            )
            Write-Log ("feishu deny -> agent click ok=$ok")
        }
        $acted = $true
        break
    }

    $askVisible = Test-AgentAskVisible
    if ($askVisible) {
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
    Write-Log "watch end without action"
}
try { Remove-Item -LiteralPath $claimPath -Force -ErrorAction SilentlyContinue } catch {}
exit 0
