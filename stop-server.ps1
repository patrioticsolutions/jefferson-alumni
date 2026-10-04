param([int]$Port = 80)
$ErrorActionPreference = 'Stop'
$connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($connections.Count -eq 0) {
    Write-Host "No Jefferson Alumni server is listening on port $Port."
    exit 0
}

$processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
foreach ($processId in $processIds) {
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    if ($process.ProcessName -notin @('powershell', 'pwsh')) {
        Write-Warning "Port $Port is owned by '$($process.ProcessName)' (PID $processId), not a PowerShell server. It was left running."
        continue
    }
    Stop-Process -Id $processId -Force
    Write-Host "Stopped the Jefferson Alumni PowerShell server (PID $processId)."
}
