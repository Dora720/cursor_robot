# Watch Feishu confirm while Cursor Agent window already shows ask.
# On Feishu allow/deny, try to click the matching Agent approval button (peer confirm).
param(
    [Parameter(Mandatory = $true)][string]$ConfirmId,
    [Parameter(Mandatory = $true)][string]$StatusUrl,
    [Parameter(Mandatory = $true)][string]$Token,
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
    $clicked = $false
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
                                $clicked = $true
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
    return $clicked
}

Write-Log ("start confirm_id=$ConfirmId timeout=$TimeoutSec")
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$decision = "pending"

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $stOut = & curl.exe -sS -m 8 -H "X-Notify-Token: $Token" $StatusUrl 2>&1
    try {
        $st = $stOut | ConvertFrom-Json
        $decision = [string]$st.status
    } catch {
        $decision = "pending"
    }
    if ($decision -eq "allow" -or $decision -eq "deny") { break }
    if ($decision -eq "cursor" -or $decision -eq "timeout") { break }
}

Write-Log ("decision=$decision")

if ($decision -eq "allow") {
    $ok = Invoke-AgentButton @(
        "Run", "Allow", "Approve", "Accept", "Continue", "Confirm",
        "运行", "允许", "批准", "确认", "继续", "执行"
    )
    if (-not $ok) {
        Write-Log "Feishu allow but Agent button not found; user may still click Agent window"
    }
    exit 0
}

if ($decision -eq "deny") {
    $ok = Invoke-AgentButton @(
        "Deny", "Reject", "Skip", "Cancel", "Block",
        "拒绝", "取消", "跳过", "阻止"
    )
    if (-not $ok) {
        Write-Log "Feishu deny but Agent reject button not found"
    }
    exit 0
}

Write-Log "watch end without feishu decision"
exit 0
