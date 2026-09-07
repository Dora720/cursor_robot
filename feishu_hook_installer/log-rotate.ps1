# Shared log rotation for notify-feishu.log (and other hook logs).
# Keep file under ~1MB by discarding older bytes and retaining a recent tail.
param(
    [Parameter(Mandatory = $false)][string]$Path = ""
)

$script:NotifyLogMaxBytes = 1MB
$script:NotifyLogKeepBytes = 600KB

function Rotate-NotifyLog {
    param([Parameter(Mandatory = $true)][string]$LogFile)
    try {
        if (-not $LogFile) { return }
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        $item = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if ($item.Length -le $script:NotifyLogMaxBytes) { return }

        $keep = [int][Math]::Min($script:NotifyLogKeepBytes, $item.Length)
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Seek(-$keep, [System.IO.SeekOrigin]::End) | Out-Null
            $buf = New-Object byte[] $keep
            $read = $fs.Read($buf, 0, $keep)
            if ($read -le 0) { return }
            $start = 0
            $limit = [Math]::Min(1024, $read)
            for ($i = 0; $i -lt $limit; $i++) {
                if ($buf[$i] -eq 10) { $start = $i + 1; break }
            }
            $marker = [System.Text.Encoding]::UTF8.GetBytes(
                ("[{0}] ---- log truncated (max 1MB, old lines discarded) ----`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
            )
            $fs.SetLength(0)
            $fs.Position = 0
            $fs.Write($marker, 0, $marker.Length)
            if ($start -lt $read) {
                $fs.Write($buf, $start, ($read - $start))
            }
            $fs.Flush()
        } finally {
            $fs.Close()
        }
    } catch {}
}

if ($Path) {
    Rotate-NotifyLog -LogFile $Path
}
