$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Join-Path $root 'data'
$dataFile=Join-Path $dataDir 'alumni.json'
$ledgerFile=Join-Path $dataDir 'event-reminders.json'
. (Join-Path $root 'mail.ps1')
if (-not (Test-Path $dataFile)) { throw "Member database not found: $dataFile" }
if ([string]::IsNullOrWhiteSpace([string]$env:JH_SMTP_HOST) -or [string]::IsNullOrWhiteSpace([string]$env:JH_SMTP_FROM)) {
    Write-Host 'Reminder email skipped: configure JH_SMTP_HOST and JH_SMTP_FROM first.'
    exit 0
}
$db=[System.IO.File]::ReadAllText($dataFile,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
$sentKeys=@()
if (Test-Path $ledgerFile) {
    $ledgerText=[System.IO.File]::ReadAllText($ledgerFile,[System.Text.Encoding]::UTF8)
    if (-not [string]::IsNullOrWhiteSpace($ledgerText)) { $sentKeys=@($ledgerText | ConvertFrom-Json) }
}
$sentCount=0
$today=[datetime]::Today
foreach ($event in @($db.events)) {
    $eventDate=[datetime]::ParseExact([string]$event.date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture).Date
    $days=($eventDate-$today).Days
    if ($days -eq 7) { $bucket='7-day' } elseif ($days -eq 1) { $bucket='1-day' } else { continue }
    foreach ($rsvp in @($event.rsvps | Where-Object { $_.status -eq 'going' })) {
        $member=$db.users | Where-Object { $_.id -eq $rsvp.userId -and $_.emailVerified -ne $false } | Select-Object -First 1
        if (-not $member -or [string]::IsNullOrWhiteSpace([string]$member.email)) { continue }
        $key="$($event.id)|$($member.id)|$bucket"
        if ($sentKeys -contains $key) { continue }
        $subject=if($bucket -eq '7-day'){"Coming up next week: $($event.title)"}else{"Tomorrow: $($event.title)"}
        $body="Hello $($member.name),`r`n`r`nA reminder about the event you plan to attend:`r`n`r`n$($event.title)`r`nDate: $($event.date) at $($event.time)`r`nLocation: $($event.location)`r`n`r`n$($event.details)`r`n`r`nWe look forward to seeing you."
        if (Send-AppEmail $member.email $subject $body) { $sentKeys+= $key; $sentCount++ }
    }
}
$temporary=$ledgerFile+'.tmp'
[System.IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject @($sentKeys) -Depth 3),[System.Text.UTF8Encoding]::new($false))
if (Test-Path $ledgerFile) { Move-Item -LiteralPath $temporary -Destination $ledgerFile -Force } else { [System.IO.File]::Move($temporary,$ledgerFile) }
Write-Host "Sent $sentCount event reminder email(s)."
