param([int]$Port = 80)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
$dataFile = Join-Path $dataDir 'alumni.json'
$uploadDir = Join-Path $dataDir 'uploads'
$eventUploadDir = Join-Path $dataDir 'event-uploads'
$siteUploadDir = Join-Path $dataDir 'site-assets'
$homePostUploadDir = Join-Path $dataDir 'home-post-uploads'
$backupDir = Join-Path $dataDir 'backups'
. (Join-Path $root 'mail.ps1')
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path $uploadDir | Out-Null
New-Item -ItemType Directory -Force -Path $eventUploadDir | Out-Null
New-Item -ItemType Directory -Force -Path $siteUploadDir | Out-Null
New-Item -ItemType Directory -Force -Path $homePostUploadDir | Out-Null
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$script:gate = New-Object object
$script:sessions = @{}
$schoolOptions=@('Jefferson High School','Jefferson Middle School','East Elementary','West Elementary','Sullivan Elementary','St. John the Baptist Catholic School','St. John Lutheran School')

function New-Database {
    return @{ users = @(); posts = @(
        @{ id='welcome'; author='Jefferson Alumni Team'; created=(Get-Date).ToString('o'); body='Welcome to the Jefferson alumni community. Share a memory, reconnect with classmates, and keep an eye on upcoming reunions.' }
    ); events = @(
        @{ id='reunion-2026'; title='All-Class Reunion'; date='2026-10-24'; time='6:00 PM'; location='Jefferson High School'; details='Reconnect with classmates across the decades. More details coming soon.' }
        @{ id='homecoming-2026'; title='Homecoming Weekend'; date='2026-10-09'; time='5:30 PM'; location='Jefferson High School'; details='Join fellow alumni for the homecoming game and a pre-game gathering.' }
    ); messages = @(); homePosts=@(); reports=@(); auditLog=@(); discussionGroups=@(); discussions=@(); site = @{ title='Jefferson Alumni'; tagline='A place for Jefferson alumni to find one another and keep our community close.' } }
}
if (-not (Test-Path $dataFile)) { New-Database | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dataFile -Encoding UTF8 }
function Read-Database { [System.IO.File]::ReadAllText($dataFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function Write-Database($db) {
    $json=ConvertTo-Json -InputObject $db -Depth 12
    $temporary=$dataFile+'.tmp'
    [System.IO.File]::WriteAllText($temporary,$json,[System.Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $dataFile){$snapshot=Join-Path $backupDir ('jefferson-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json');Copy-Item -LiteralPath $dataFile -Destination $snapshot;Get-ChildItem -LiteralPath $backupDir -File -Filter 'jefferson-*.json'|Sort-Object LastWriteTime -Descending|Select-Object -Skip 30|Remove-Item -Force}
    if (Test-Path -LiteralPath $dataFile) { Move-Item -LiteralPath $temporary -Destination $dataFile -Force } else { [System.IO.File]::Move($temporary,$dataFile) }
}
function Add-AuditEntry($db,$user,[string]$action,[string]$objectType,[string]$objectId,[string]$summary) {
    if(-not $db.PSObject.Properties['auditLog']){$db|Add-Member -NotePropertyName auditLog -NotePropertyValue @()}
    $entry=@{id=[guid]::NewGuid().ToString('N');actorId=$user.id;actorName=$user.name;action=$action;objectType=$objectType;objectId=$objectId;summary=$summary;created=(Get-Date).ToString('o')}
    $entries=@($db.auditLog)+@($entry);$db.auditLog=@($entries|Sort-Object created -Descending|Select-Object -First 1000)
}
function Set-ObjectProperty($Object,[string]$Name,$Value) {
    if ($null -eq $Object) { throw 'Cannot set a property on a null object.' }
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name]=$Value; return }
    $property=$Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value=$Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function Send-Json($context, [int]$status, $value) {
    $body = ConvertTo-Json -InputObject $value -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $context.Response.StatusCode = $status; $context.Response.ContentType = 'application/json; charset=utf-8'
    $context.Response.Headers.Add('Cache-Control','no-store'); $context.Response.Headers.Add('X-Content-Type-Options','nosniff')
    $context.Response.ContentLength64 = $bytes.Length
    try { $context.Response.OutputStream.Write($bytes,0,$bytes.Length); $context.Response.Close() }
    catch [System.Net.HttpListenerException] { }
    catch [System.IO.IOException] { }
    catch [System.ObjectDisposedException] { }
}
function Send-Text($context, [int]$status, [string]$body, [string]$type) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body); $context.Response.StatusCode=$status; $context.Response.ContentType=$type
    $context.Response.Headers.Add('X-Content-Type-Options','nosniff'); $context.Response.ContentLength64=$bytes.Length
    $context.Response.OutputStream.Write($bytes,0,$bytes.Length); $context.Response.Close()
}
function Send-Bytes($context, [int]$status, [byte[]]$body, [string]$type) {
    $context.Response.StatusCode=$status; $context.Response.ContentType=$type
    $context.Response.Headers.Add('X-Content-Type-Options','nosniff'); $context.Response.Headers.Add('Cache-Control','private, max-age=3600')
    $context.Response.ContentLength64=$body.Length; $context.Response.OutputStream.Write($body,0,$body.Length); $context.Response.Close()
}
function Read-Body($request) {
    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
    try { return $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
}
function New-PasswordRecord([string]$password) {
    $salt = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($password,$salt,210000,[Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $hash=$derive.GetBytes(32) } finally { $derive.Dispose() }
    return @{ salt=[Convert]::ToBase64String($salt); hash=[Convert]::ToBase64String($hash) }
}
function New-SessionToken {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Test-Password($user,[string]$password) {
    try {
        $salt=[Convert]::FromBase64String($user.salt); $expected=[Convert]::FromBase64String($user.hash)
        $d=[Security.Cryptography.Rfc2898DeriveBytes]::new($password,$salt,210000,[Security.Cryptography.HashAlgorithmName]::SHA256)
        try { $actual=$d.GetBytes(32) } finally { $d.Dispose() }
        if ($actual.Length -ne $expected.Length) { return $false }
        $difference=0
        for ($i=0; $i -lt $actual.Length; $i++) { $difference = $difference -bor ($actual[$i] -bxor $expected[$i]) }
        return ($difference -eq 0)
    } catch { return $false }
}
function Get-CurrentUser($request,$db) {
    $cookie=$request.Cookies['jh_session']; if (-not $cookie) { return $null }
    $userId=$script:sessions[$cookie.Value]; if (-not $userId) { return $null }
    $user=$db.users | Where-Object { $_.id -eq $userId } | Select-Object -First 1
    if ($user -and $user.suspended -eq $true) { return $null }
    return $user
}
function Public-User($user,$viewerId,[bool]$asAdmin=$false) {
    $own=($user.id -eq $viewerId); $visibility=$user.profileVisibility
    $visible=@{};foreach($field in @('name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','maritalStatus','hasChildren','schoolsAttended','photo')){$visible[$field]=$own -or $asAdmin -or [bool]$visibility.$field}
    $email=if($asAdmin -or ($visible.email -and ($user.emailVisibility -ne 'private' -or $own))){$user.email}else{$null}
    return @{id=$user.id;name=$(if($visible.name){$user.name}else{'Private member'});email=$email;classYear=$(if($visible.classYear){$user.classYear}else{$null});role=$(if($visible.role){$user.role}else{$null});city=$(if($visible.city){$user.city}else{$null});bio=$(if($visible.bio){$user.bio}else{$null});phone=$(if($visible.phone){$user.phone}else{$null});occupation=$(if($visible.occupation){$user.occupation}else{$null});employer=$(if($visible.employer){$user.employer}else{$null});interests=$(if($visible.interests){$user.interests}else{$null});website=$(if($visible.website){$user.website}else{$null});linkedin=$(if($visible.linkedin){$user.linkedin}else{$null});facebook=$(if($visible.facebook){$user.facebook}else{$null});instagram=$(if($visible.instagram){$user.instagram}else{$null});tiktok=$(if($visible.tiktok){$user.tiktok}else{$null});maritalStatus=$(if($visible.maritalStatus){$user.maritalStatus}else{$null});hasChildren=$(if($visible.hasChildren){$user.hasChildren}else{$null});schoolsAttended=$(if($visible.schoolsAttended){@($user.schoolsAttended)}else{$null});photoUrl=$(if($visible.photo){$user.photoUrl}else{$null});emailVisibility=$user.emailVisibility;suspended=($user.suspended -eq $true);profileVisibility=$(if($own -or $asAdmin){$visibility}else{$null})}
}
function Public-Event($event,$db,$viewerId) {
    $yesCount = @($event.rsvps | Where-Object { $_.status -eq 'going' }).Count
    $myRsvp = $event.rsvps | Where-Object { $_.userId -eq $viewerId } | Select-Object -First 1
    $organizer = $event.organizerName
    if ($event.organizerId) { $person = $db.users | Where-Object { $_.id -eq $event.organizerId } | Select-Object -First 1; if ($person) { $organizer = $person.name } }
    $invitation=$null
    if($viewerId -and $event.invitations){$invite=$event.invitations|Where-Object{$_.toId -eq $viewerId}|Select-Object -First 1;if($invite){$sender=$db.users|Where-Object{$_.id -eq $invite.fromId}|Select-Object -First 1;if($sender){$invitation=$sender.name}}}
    return @{ id=$event.id; title=$event.title; date=$event.date; time=$event.time; endTime=$event.endTime; location=$event.location; details=$event.details; category=$event.category; registrationUrl=$event.registrationUrl; imageUrl=$event.imageUrl; capacity=$event.capacity; organizer=$organizer; attendeeCount=$yesCount; myRsvp=$(if ($myRsvp) { $myRsvp.status } else { '' }); myInvitation=$invitation }
}
function Save-EventImage([string]$eventId,[string]$image) {
    if ($image.Length -gt 2800000) { throw 'Choose an image under 2 MB.' }
    if ($image -match '^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$') { $format=$Matches[1];$encoded=$Matches[2] } else { throw 'Choose a PNG, JPEG, or WebP image.' }
    try {$bytes=[Convert]::FromBase64String($encoded)} catch {throw 'The image file could not be read.'}
    if($bytes.Length -lt 16 -or $bytes.Length -gt 2097152){throw 'Event images must be between 16 bytes and 2 MB.'}
    $valid=$false
    if($format -eq 'png' -and [BitConverter]::ToString($bytes[0..7]) -eq '89-50-4E-47-0D-0A-1A-0A'){$extension='png';$valid=$true}
    elseif($format -eq 'jpeg' -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255){$extension='jpg';$valid=$true}
    elseif($format -eq 'webp' -and [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP'){$extension='webp';$valid=$true}
    if(-not $valid){throw 'The file contents do not match a supported image type.'}
    foreach($old in @('png','jpg','webp')){$p=Join-Path $eventUploadDir ($eventId+'.'+$old);if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}
    [IO.File]::WriteAllBytes((Join-Path $eventUploadDir ($eventId+'.'+$extension)),$bytes)
    return "/event-uploads/$eventId.$extension"
}
function Save-SiteImage([string]$kind,[string]$image) {
    if($kind -notin @('logo','hero')){throw 'Choose a supported site image.'}
    if($image.Length -gt 2800000){throw 'Choose an image under 2 MB.'}
    if($image -match '^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$'){$format=$Matches[1];$encoded=$Matches[2]}else{throw 'Choose a PNG, JPEG, or WebP image.'}
    try{$bytes=[Convert]::FromBase64String($encoded)}catch{throw 'The image file could not be read.'}
    if($bytes.Length -lt 16 -or $bytes.Length -gt 2097152){throw 'Site images must be between 16 bytes and 2 MB.'}
    $valid=$false;if($format -eq 'png' -and [BitConverter]::ToString($bytes[0..7]) -eq '89-50-4E-47-0D-0A-1A-0A'){$extension='png';$valid=$true}elseif($format -eq 'jpeg' -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255){$extension='jpg';$valid=$true}elseif($format -eq 'webp' -and [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP'){$extension='webp';$valid=$true}
    if(-not $valid){throw 'The file contents do not match a supported image type.'}
    foreach($old in @('png','jpg','webp')){$p=Join-Path $siteUploadDir ("$kind.$old");if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}
    [IO.File]::WriteAllBytes((Join-Path $siteUploadDir ("$kind.$extension")),$bytes);return "/site-assets/$kind.$extension"
}
function Save-HomePostImage([string]$postId,[string]$image) {
    if($image.Length -gt 2800000){throw 'Choose an image under 2 MB.'}
    if($image -match '^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$'){$format=$Matches[1];$encoded=$Matches[2]}else{throw 'Choose a PNG, JPEG, or WebP image.'}
    try{$bytes=[Convert]::FromBase64String($encoded)}catch{throw 'The image file could not be read.'}
    if($bytes.Length -lt 16 -or $bytes.Length -gt 2097152){throw 'Post images must be between 16 bytes and 2 MB.'}
    $valid=$false;if($format -eq 'png' -and [BitConverter]::ToString($bytes[0..7]) -eq '89-50-4E-47-0D-0A-1A-0A'){$extension='png';$valid=$true}elseif($format -eq 'jpeg' -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255){$extension='jpg';$valid=$true}elseif($format -eq 'webp' -and [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP'){$extension='webp';$valid=$true}
    if(-not $valid){throw 'The file contents do not match a supported image type.'}
    foreach($old in @('png','jpg','webp')){$p=Join-Path $homePostUploadDir ("$postId.$old");if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}
    [IO.File]::WriteAllBytes((Join-Path $homePostUploadDir ("$postId.$extension")),$bytes);return "/home-post-assets/$postId.$extension"
}
function Test-PasswordPolicy([string]$password) {
    if($password.Length -lt 15 -or $password.Length -gt 200){return $false}
    $normalized=$password.ToLowerInvariant()
    if($normalized -match '^(.)\1+$'){return $false}
    if($normalized -in @('passwordpassword','123456789012345','qwertyuiop12345','letmeinletmein1','adminadminadmin','jefferson123456')){return $false}
    return $true
}
function Public-Post($post,$db,$viewerId) {
    $author=$db.users|Where-Object{$_.id -eq $post.authorId}|Select-Object -First 1
    if(-not $author){return @{id=$post.id;author=$post.author;authorId=$post.authorId;authorPhoto=$post.authorPhoto;created=$post.created;body=$post.body}}
    $publicAuthor=Public-User $author $viewerId
    return @{id=$post.id;author=$publicAuthor.name;authorId=$author.id;authorPhoto=$publicAuthor.photoUrl;created=$post.created;body=$post.body}
}
function Has-Permission($user,[string]$permission) { return [bool]$user.permissions.$permission }
function Has-AnyPermission($user) { return ((Has-Permission $user 'profiles') -or (Has-Permission $user 'events') -or (Has-Permission $user 'posts') -or (Has-Permission $user 'homepagePosts') -or (Has-Permission $user 'approveUsers') -or (Has-Permission $user 'moderate') -or (Has-Permission $user 'audit') -or (Has-Permission $user 'bulkEmail') -or (Has-Permission $user 'customize') -or (Has-Permission $user 'permissions')) }
function Test-DiscussionAccess($user,$discussion,$db) {
    if($user.id -eq $discussion.authorId -or (Has-Permission $user 'profiles')){return $true}
    switch([string]$discussion.audience){
        'site' {return $true}
        'class' {return (-not [string]::IsNullOrWhiteSpace([string]$user.classYear) -and [string]$user.classYear -eq [string]$discussion.classYear)}
        'selected' {return (@($discussion.memberIds) -contains [string]$user.id)}
        'group' {$group=$db.discussionGroups|Where-Object{$_.id -eq $discussion.groupId}|Select-Object -First 1;return ($group -and (@($group.memberIds) -contains [string]$user.id))}
        default {return $false}
    }
}
function Public-Site($db) {
    if ($db.site) { return @{title=$db.site.title;tagline=$db.site.tagline;primaryColor=$db.site.primaryColor;accentColor=$db.site.accentColor;fontFamily=$db.site.fontFamily;logoUrl=$db.site.logoUrl;heroImageUrl=$db.site.heroImageUrl} }
    return @{title='Jefferson Alumni';tagline='A place for Jefferson alumni to find one another and keep our community close.';primaryColor='#5a1024';accentColor='#f0b23e';fontFamily='system';logoUrl='/assets/school-logo.png';heroImageUrl=$null}
}
function ConvertTo-IcsText([string]$text){return $text.Replace('\','\\').Replace("`r`n",'\n').Replace("`n",'\n').Replace(',','\,').Replace(';','\;')}
function New-IcsCalendar($events){$lines=[System.Collections.Generic.List[string]]::new();$lines.Add('BEGIN:VCALENDAR');$lines.Add('VERSION:2.0');$lines.Add('PRODID:-//Jefferson Alumni//Community Calendar//EN');$lines.Add('CALSCALE:GREGORIAN');$lines.Add('METHOD:PUBLISH');foreach($event in @($events)){$start=[datetime]::Now;try{$start=[datetime]::Parse(([string]$event.date)+' '+([string]$event.time),[Globalization.CultureInfo]::GetCultureInfo('en-US'))}catch{try{$start=[datetime]::ParseExact([string]$event.date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)}catch{continue}};$end=$start.AddHours(2);if($event.endTime){try{$candidate=[datetime]::Parse(([string]$event.date)+' '+([string]$event.endTime),[Globalization.CultureInfo]::GetCultureInfo('en-US'));if($candidate -gt $start){$end=$candidate}}catch{}};$lines.Add('BEGIN:VEVENT');$lines.Add('UID:'+([string]$event.id)+'@jefferson-alumni');$lines.Add('DTSTAMP:'+(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'));$lines.Add('DTSTART:'+$start.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'));$lines.Add('DTEND:'+$end.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'));$lines.Add('SUMMARY:'+(ConvertTo-IcsText ([string]$event.title)));$lines.Add('LOCATION:'+(ConvertTo-IcsText ([string]$event.location)));$lines.Add('DESCRIPTION:'+(ConvertTo-IcsText ([string]$event.details)));$lines.Add('END:VEVENT')};$lines.Add('END:VCALENDAR');return ($lines -join "`r`n")+"`r`n"}

# Upgrade older data files and give the existing first account initial administrator access.
$migrationDb = Read-Database
$adminExists = @($migrationDb.users | Where-Object { $_.permissions -and $_.permissions.permissions }).Count -gt 0
if (-not $migrationDb.site) { $migrationDb | Add-Member -NotePropertyName site -NotePropertyValue @{title='Jefferson Alumni';tagline='A place for Jefferson alumni to find one another and keep our community close.'} }
$siteDefaults=@{primaryColor='#5a1024';accentColor='#f0b23e';fontFamily='system';logoUrl='/assets/school-logo.png';heroImageUrl=$null};foreach($key in $siteDefaults.Keys){if(-not $migrationDb.site.PSObject.Properties[$key]){$migrationDb.site|Add-Member -NotePropertyName $key -NotePropertyValue $siteDefaults[$key]}}
if (-not $migrationDb.PSObject.Properties['messages']) { $migrationDb | Add-Member -NotePropertyName messages -NotePropertyValue @() }
if (-not $migrationDb.PSObject.Properties['homePosts']) { $migrationDb | Add-Member -NotePropertyName homePosts -NotePropertyValue @() }
if (-not $migrationDb.PSObject.Properties['reports']) { $migrationDb | Add-Member -NotePropertyName reports -NotePropertyValue @() }
if (-not $migrationDb.PSObject.Properties['auditLog']) { $migrationDb | Add-Member -NotePropertyName auditLog -NotePropertyValue @() }
if (-not $migrationDb.PSObject.Properties['discussionGroups']) { $migrationDb | Add-Member -NotePropertyName discussionGroups -NotePropertyValue @() }
if (-not $migrationDb.PSObject.Properties['discussions']) { $migrationDb | Add-Member -NotePropertyName discussions -NotePropertyValue @() }
for ($i=0; $i -lt @($migrationDb.users).Count; $i++) {
    $member = $migrationDb.users[$i]
    $profileDefaults=@{phone='';occupation='';employer='';interests='';website='';linkedin='';facebook='';instagram='';tiktok='';maritalStatus='';hasChildren='';schoolsAttended=@()};foreach($profileField in $profileDefaults.Keys){if(-not $member.PSObject.Properties[$profileField]){$member|Add-Member -NotePropertyName $profileField -NotePropertyValue $profileDefaults[$profileField]}}
    if(-not $member.PSObject.Properties['profileVisibility']){$member|Add-Member -NotePropertyName profileVisibility -NotePropertyValue @{name=$true;email=($member.emailVisibility -ne 'private');role=$true;classYear=$true;city=$true;bio=$true;phone=$true;occupation=$true;employer=$true;interests=$true;website=$true;linkedin=$true;facebook=$true;instagram=$true;tiktok=$true;maritalStatus=$false;hasChildren=$false;schoolsAttended=$false;photo=$true}} else { foreach($socialField in @('linkedin','facebook','instagram','tiktok')){if(-not $member.profileVisibility.PSObject.Properties[$socialField]){$member.profileVisibility|Add-Member -NotePropertyName $socialField -NotePropertyValue $true}};foreach($familyField in @('maritalStatus','hasChildren','schoolsAttended')){if(-not $member.profileVisibility.PSObject.Properties[$familyField]){$member.profileVisibility|Add-Member -NotePropertyName $familyField -NotePropertyValue $false}} }
    if (-not $member.PSObject.Properties['permissions']) {
        $grants = @{profiles=$false;events=$false;posts=$false;homepagePosts=$false;approveUsers=$false;moderate=$false;audit=$false;bulkEmail=$false;customize=$false;permissions=$false}
        if (-not $adminExists -and $i -eq 0) { $grants=@{profiles=$true;events=$true;posts=$true;homepagePosts=$true;approveUsers=$true;moderate=$true;audit=$true;bulkEmail=$true;customize=$true;permissions=$true}; $adminExists=$true }
        $member | Add-Member -NotePropertyName permissions -NotePropertyValue $grants
    }
    if (-not $member.PSObject.Properties['permissions']) { $member | Add-Member -NotePropertyName permissions -NotePropertyValue @{profiles=$false;events=$false;posts=$false;homepagePosts=$false;approveUsers=$false;moderate=$false;audit=$false;bulkEmail=$false;customize=$false;permissions=$false} }
    if (-not $member.PSObject.Properties['permissions'].Value) { $member.permissions=@{profiles=$false;events=$false;posts=$false;homepagePosts=$false;approveUsers=$false;moderate=$false;audit=$false;bulkEmail=$false;customize=$false;permissions=$false} }
    foreach($permissionName in @('homepagePosts','approveUsers','moderate','audit','bulkEmail')){if(-not $member.permissions.PSObject.Properties[$permissionName]){$initialGrant=($permissionName -ne 'homepagePosts' -and [bool]$member.permissions.permissions);$member.permissions|Add-Member -NotePropertyName $permissionName -NotePropertyValue $initialGrant}}
    if(-not $member.PSObject.Properties['approved']){$member|Add-Member -NotePropertyName approved -NotePropertyValue $true}
    if(-not $member.PSObject.Properties['suspended']){$member|Add-Member -NotePropertyName suspended -NotePropertyValue $false}
    if(-not $member.PSObject.Properties['approvalStatus']){$member|Add-Member -NotePropertyName approvalStatus -NotePropertyValue 'approved'}
    if (-not $member.PSObject.Properties['photoUrl']) { $member | Add-Member -NotePropertyName photoUrl -NotePropertyValue $null }
    if (-not $member.PSObject.Properties['emailVerified']) { $member | Add-Member -NotePropertyName emailVerified -NotePropertyValue $true }
    if (-not $member.PSObject.Properties['verificationHash']) { $member | Add-Member -NotePropertyName verificationHash -NotePropertyValue $null }
    if (-not $member.PSObject.Properties['verificationExpires']) { $member | Add-Member -NotePropertyName verificationExpires -NotePropertyValue $null }
    if (-not $member.PSObject.Properties['resetHash']) { $member | Add-Member -NotePropertyName resetHash -NotePropertyValue $null }
    if (-not $member.PSObject.Properties['resetExpires']) { $member | Add-Member -NotePropertyName resetExpires -NotePropertyValue $null }
    if ([string]::IsNullOrWhiteSpace([string]$member.photoUrl)) {
        foreach ($photoExtension in @('png','jpg','webp')) {
            if (Test-Path (Join-Path $uploadDir ($member.id+'.'+$photoExtension))) { $member.photoUrl="/uploads/$($member.id).$photoExtension"; break }
        }
    }
}
foreach($event in @($migrationDb.events)){if(-not $event.PSObject.Properties['imageUrl']){$event|Add-Member -NotePropertyName imageUrl -NotePropertyValue $null}}
Write-Database $migrationDb
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Error "Could not listen on http://localhost:$Port/. $($_.Exception.Message)"; exit 1 }
Write-Host "Jefferson Alumni is running at http://localhost:$Port/ (Ctrl+C to stop)."
while ($listener.IsListening) {
    try {
        $ctx=$listener.GetContext(); $req=$ctx.Request; $path=$req.Url.AbsolutePath; $method=$req.HttpMethod
        if ($path -eq '/api/register' -and $method -eq 'POST') {
            $payload=Read-Body $req; $name=([string]$payload.name).Trim(); $email=([string]$payload.email).Trim().ToLowerInvariant(); $password=[string]$payload.password
            if ($name.Length -lt 2 -or $name.Length -gt 90 -or $email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$' -or -not (Test-PasswordPolicy $password)) { Send-Json $ctx 400 @{error='Use a passphrase of 15–200 characters. Common passwords and repeated characters are not allowed.'}; continue }
            [System.Threading.Monitor]::Enter($script:gate); try { $db=Read-Database; if ($db.users | Where-Object {$_.email -eq $email}) { Send-Json $ctx 409 @{error='An account with that email already exists.'}; continue }
                $bootstrapAdmin=(@($db.users).Count -eq 0);$secret=New-PasswordRecord $password; $rawToken=New-SecureToken; $user=@{ id=[guid]::NewGuid().ToString('N'); name=$name; email=$email; salt=$secret.salt; hash=$secret.hash; classYear=([string]$payload.classYear).Trim(); role=([string]$payload.role).Trim(); city=''; bio='';phone='';occupation='';employer='';interests='';website='';linkedin='';facebook='';instagram='';tiktok='';maritalStatus='';hasChildren='';schoolsAttended=@();profileVisibility=@{name=$true;email=$true;role=$true;classYear=$true;city=$true;bio=$true;phone=$true;occupation=$true;employer=$true;interests=$true;website=$true;linkedin=$true;facebook=$true;instagram=$true;tiktok=$true;maritalStatus=$false;hasChildren=$false;schoolsAttended=$false;photo=$true}; emailVisibility='members'; photoUrl=$null; emailVerified=$bootstrapAdmin; approved=$false; approvalStatus='pending'; verificationHash=(Get-TokenHash $rawToken); verificationExpires=(Get-Date).AddHours(24).ToString('o'); resetHash=$null; resetExpires=$null; permissions=@{profiles=$false;events=$false;posts=$false;homepagePosts=$false;approveUsers=$false;moderate=$false;audit=$false;bulkEmail=$false;customize=$false;permissions=$false}; created=(Get-Date).ToString('o') }; if($bootstrapAdmin){$user.approved=$true;$user.approvalStatus='approved';$user.verificationHash=$null;$user.verificationExpires=$null;$user.permissions=@{profiles=$true;events=$true;posts=$true;homepagePosts=$true;approveUsers=$true;moderate=$true;audit=$true;bulkEmail=$true;customize=$true;permissions=$true}}; $db.users += $user; Write-Database $db
            } finally { [System.Threading.Monitor]::Exit($script:gate) }
            $sent=$false;if(-not $bootstrapAdmin){$verifyUrl="$(Get-PublicBaseUrl)/community?verify=$rawToken"; $sent=Send-AppEmail $email 'Verify your Jefferson Alumni account' "Hello $name,`r`n`r`nPlease verify your email address by opening this link within 24 hours:`r`n$verifyUrl`r`n`r`nIf you did not create this account, you can ignore this email."}
            Send-Json $ctx 201 @{verificationRequired=(-not $bootstrapAdmin);verificationSent=$sent;approvalRequired=(-not $bootstrapAdmin);bootstrapAdmin=$bootstrapAdmin}; continue
        }
        if ($path -eq '/api/login' -and $method -eq 'POST') {
            $payload=Read-Body $req; $email=([string]$payload.email).Trim().ToLowerInvariant(); $db=Read-Database; $user=$db.users | Where-Object {$_.email -eq $email} | Select-Object -First 1
            if (-not $user -or -not (Test-Password $user ([string]$payload.password))) { Send-Json $ctx 401 @{error='Email or password is incorrect.'}; continue }
            if ($user.suspended -eq $true) { Send-Json $ctx 403 @{error='This account is suspended. Contact a Jefferson Alumni administrator for help.'}; continue }
            if ($user.approved -eq $false) { Send-Json $ctx 403 @{error='Your account is awaiting approval by a Jefferson Alumni administrator.';approvalPending=$true}; continue }
            if ($user.emailVerified -eq $false) { Send-Json $ctx 403 @{error='Please verify your email before signing in. Use the verification link we emailed you, or request a new one.';verificationRequired=$true}; continue }
            $token=New-SessionToken; $script:sessions[$token]=$user.id
            $ctx.Response.Headers.Add('Set-Cookie',"jh_session=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200"); Send-Json $ctx 200 @{user=(Public-User $user $user.id)}; continue
        }
        if ($path -eq '/api/verify' -and $method -eq 'POST') {
            $payload=Read-Body $req; $hash=Get-TokenHash ([string]$payload.token); $db=Read-Database
            $target=$db.users | Where-Object { $_.verificationHash -eq $hash } | Select-Object -First 1
            if (-not $target -or -not $target.verificationExpires -or [datetime]::Parse([string]$target.verificationExpires) -lt (Get-Date)) { Send-Json $ctx 400 @{error='That verification link is invalid or expired. Request a new link.'}; continue }
            $target.emailVerified=$true; $target.verificationHash=$null; $target.verificationExpires=$null; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
        }
        if ($path -eq '/api/verify/resend' -and $method -eq 'POST') {
            $payload=Read-Body $req; $email=([string]$payload.email).Trim().ToLowerInvariant(); $db=Read-Database
            $target=$db.users | Where-Object { $_.email -eq $email -and $_.emailVerified -eq $false } | Select-Object -First 1
            if ($target) { $rawToken=New-SecureToken; $target.verificationHash=Get-TokenHash $rawToken; $target.verificationExpires=(Get-Date).AddHours(24).ToString('o'); Write-Database $db; $url="$(Get-PublicBaseUrl)/community?verify=$rawToken"; [void](Send-AppEmail $target.email 'Verify your Jefferson Alumni account' "Hello $($target.name),`r`n`r`nVerify your account within 24 hours:`r`n$url") }
            $configured=(-not [string]::IsNullOrWhiteSpace([string]$env:JH_SMTP_HOST) -and -not [string]::IsNullOrWhiteSpace([string]$env:JH_SMTP_FROM)); Send-Json $ctx 200 @{ok=$true;message='If that address has an unverified account, a new link has been sent.';emailConfigured=$configured}; continue
        }
        if ($path -eq '/api/password/forgot' -and $method -eq 'POST') {
            $payload=Read-Body $req; $email=([string]$payload.email).Trim().ToLowerInvariant(); $db=Read-Database
            $target=$db.users | Where-Object { $_.email -eq $email } | Select-Object -First 1
            if ($target) { $rawToken=New-SecureToken; $target.resetHash=Get-TokenHash $rawToken; $target.resetExpires=(Get-Date).AddHours(1).ToString('o'); Write-Database $db; $url="$(Get-PublicBaseUrl)/community?reset=$rawToken"; [void](Send-AppEmail $target.email 'Reset your Jefferson Alumni password' "Hello $($target.name),`r`n`r`nUse this link within one hour to choose a new password:`r`n$url`r`n`r`nIf you did not request this, ignore this email.") }
            $configured=(-not [string]::IsNullOrWhiteSpace([string]$env:JH_SMTP_HOST) -and -not [string]::IsNullOrWhiteSpace([string]$env:JH_SMTP_FROM)); Send-Json $ctx 200 @{ok=$true;message='If an account uses that address, a password reset link has been sent.';emailConfigured=$configured}; continue
        }
        if ($path -eq '/api/password/reset' -and $method -eq 'POST') {
            $payload=Read-Body $req; $password=[string]$payload.password
            if (-not (Test-PasswordPolicy $password)) { Send-Json $ctx 400 @{error='Use a passphrase of 15–200 characters. Common passwords and repeated characters are not allowed.'}; continue }
            $hash=Get-TokenHash ([string]$payload.token); $db=Read-Database; $target=$db.users | Where-Object { $_.resetHash -eq $hash } | Select-Object -First 1
            if (-not $target -or -not $target.resetExpires -or [datetime]::Parse([string]$target.resetExpires) -lt (Get-Date)) { Send-Json $ctx 400 @{error='That password link is invalid or expired. Request another link.'}; continue }
            $secret=New-PasswordRecord $password; $target.salt=$secret.salt; $target.hash=$secret.hash; $target.emailVerified=$true; $target.resetHash=$null; $target.resetExpires=$null; $target.verificationHash=$null; $target.verificationExpires=$null
            foreach($sessionKey in @($script:sessions.Keys)){if($script:sessions[$sessionKey] -eq $target.id){$script:sessions.Remove($sessionKey)|Out-Null}}
            Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
        }
        if ($path -eq '/api/logout' -and $method -eq 'POST') { $c=$req.Cookies['jh_session']; if($c){$script:sessions.Remove($c.Value)}; $ctx.Response.Headers.Add('Set-Cookie','jh_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'); Send-Json $ctx 200 @{ok=$true}; continue }
        if ($path -eq '/api/site' -and $method -eq 'GET') { $db=Read-Database; Send-Json $ctx 200 @{site=(Public-Site $db)}; continue }
                if ($path -eq '/api/public/events' -and $method -eq 'GET') { $db=Read-Database; $today=[datetime]::Today.ToString('yyyy-MM-dd'); $items=@($db.events|Where-Object{$_.date -ge $today}|Sort-Object date|ForEach-Object{Public-Event $_ $db $null}); $classCounts=@{};foreach($yearGroup in @($db.users|Where-Object{$_.role -eq 'Alumni' -and $_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.suspended -ne $true -and -not [string]::IsNullOrWhiteSpace([string]$_.classYear)}|Group-Object classYear)){$classCounts[[string]$yearGroup.Name]=$yearGroup.Count};$counts=@{alumni=@($db.users|Where-Object{$_.role -eq 'Alumni' -and $_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.suspended -ne $true}).Count;teachers=@($db.users|Where-Object{$_.role -eq 'Teacher' -and $_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.suspended -ne $true}).Count;staff=@($db.users|Where-Object{$_.role -eq 'Staff' -and $_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.suspended -ne $true}).Count}; $publicHomePosts=@($db.homePosts|Where-Object{$_.audience -eq 'public'}|Sort-Object created -Descending);Send-Json $ctx 200 @{events=$items;counts=$counts;classCounts=$classCounts;site=(Public-Site $db);homePosts=$publicHomePosts}; continue }
        if ($path -eq '/calendar.ics' -and $method -eq 'GET') { $db=Read-Database; $today=[datetime]::Today.ToString('yyyy-MM-dd'); $items=@($db.events|Where-Object{$_.date -ge $today}|Sort-Object date); $ctx.Response.Headers.Add('Content-Disposition','attachment; filename="jefferson-calendar.ics"'); Send-Text $ctx 200 (New-IcsCalendar $items) 'text/calendar; charset=utf-8'; continue }
        if ($path.StartsWith('/api/')) {
            $db=Read-Database; $user=Get-CurrentUser $req $db; if (-not $user) { Send-Json $ctx 401 @{error='Please sign in to continue.'}; continue }
            if ($path -eq '/api/me' -and $method -eq 'GET') { Send-Json $ctx 200 @{user=(Public-User $user $user.id); permissions=$user.permissions; site=(Public-Site $db); homePosts=@($db.homePosts|Sort-Object created -Descending); members=@($db.users | Where-Object {$_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.suspended -ne $true} | ForEach-Object { Public-User $_ $user.id }); posts=@($db.posts | Sort-Object created -Descending | ForEach-Object {Public-Post $_ $db $user.id}); events=@($db.events | Sort-Object date | ForEach-Object { Public-Event $_ $db $user.id })}; continue }
            if ($path -eq '/api/discussion-groups' -and $method -eq 'GET') { $groups=@($db.discussionGroups|Where-Object{$_.ownerId -eq $user.id -or (Has-Permission $user 'profiles') -or (@($_.memberIds) -contains $user.id)}|ForEach-Object{$g=$_;@{id=$g.id;name=$g.name;ownerId=$g.ownerId;memberIds=@($g.memberIds);members=@(@($g.memberIds)|ForEach-Object{$mid=$_;$m=$db.users|Where-Object{$_.id -eq $mid}|Select-Object -First 1;if($m){@{id=$m.id;name=$m.name}}});created=$g.created}});Send-Json $ctx 200 @{groups=$groups};continue }
            if ($path -eq '/api/discussion-groups' -and $method -eq 'POST') {
                $payload=Read-Body $req;$name=([string]$payload.name).Trim();$requested=@($payload.memberIds|ForEach-Object{[string]$_}|Where-Object{$_}|Select-Object -Unique);$valid=@(foreach($member in @($db.users)){if($member.approved -ne $false -and $_.suspended -ne $true -and $member.id -in $requested){[string]$member.id}});if($user.id -notin $valid){$valid=@($valid)+@([string]$user.id)}
                if($name.Length -lt 2 -or $name.Length -gt 80 -or $requested.Count -gt 100 -or @($valid).Count -gt 101){Send-Json $ctx 400 @{error='Enter a group name and choose no more than 100 approved members.'};continue}
                $group=@{id=[guid]::NewGuid().ToString('N');name=$name;ownerId=$user.id;memberIds=$valid;created=(Get-Date).ToString('o')};$db.discussionGroups+= $group;Write-Database $db;Send-Json $ctx 201 @{group=@{id=$group.id;name=$group.name;ownerId=$group.ownerId;memberIds=$group.memberIds}};continue
            }
            if ($path -match '^/api/discussion-groups/([a-f0-9]{32})$' -and $method -eq 'PATCH') {
                $group=$db.discussionGroups|Where-Object{$_.id -eq $Matches[1]}|Select-Object -First 1;if(-not $group){Send-Json $ctx 404 @{error='Discussion group not found.'};continue};if($group.ownerId -ne $user.id -and -not (Has-Permission $user 'profiles')){Send-Json $ctx 403 @{error='Only the group creator or a profile administrator can manage this group.'};continue}
                $payload=Read-Body $req;$name=([string]$payload.name).Trim();$requested=@($payload.memberIds|ForEach-Object{[string]$_}|Select-Object -Unique);$valid=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and ($_.id -in $requested)}|ForEach-Object{$_.id});$valid=@($valid+$group.ownerId|Select-Object -Unique)
                if($name.Length -lt 2 -or $name.Length -gt 80 -or $requested.Count -gt 100 -or $valid.Count -gt 101){Send-Json $ctx 400 @{error='Check the group name and select no more than 100 other approved members.'};continue};$group.name=$name;$group.memberIds=$valid;Write-Database $db;Send-Json $ctx 200 @{ok=$true};continue
            }
            if ($path -eq '/api/discussions' -and $method -eq 'GET') {
                $items=@(foreach($discussion in @($db.discussions|Sort-Object updated -Descending)){if(Test-DiscussionAccess $user $discussion $db){$replyItems=@($discussion.replies|ForEach-Object{$reply=$_;$replyAuthor=$db.users|Where-Object{$_.id -eq $reply.authorId}|Select-Object -First 1;@{id=$reply.id;author=$(if($replyAuthor){$replyAuthor.name}else{'Former member'});authorId=$reply.authorId;body=$reply.body;created=$reply.created}});$classLabel=if($discussion.audience -eq 'class'){"Class of $($discussion.classYear)"}elseif($discussion.audience -eq 'group'){$group=$db.discussionGroups|Where-Object{$_.id -eq $discussion.groupId}|Select-Object -First 1;if($group){$group.name}else{'Private group'}}elseif($discussion.audience -eq 'selected'){'Selected members'}else{'All members'};@{id=$discussion.id;title=$discussion.title;body=$discussion.body;author=$discussion.author;authorId=$discussion.authorId;created=$discussion.created;updated=$discussion.updated;audience=$discussion.audience;audienceLabel=$classLabel;classYear=$discussion.classYear;groupId=$discussion.groupId;memberIds=$(if($discussion.authorId -eq $user.id -or (Has-Permission $user 'profiles')){@($discussion.memberIds)}else{@()});canManage=($discussion.authorId -eq $user.id -or (Has-Permission $user 'profiles'));replies=$replyItems}}});Send-Json $ctx 200 @{discussions=$items};continue
            }
            if ($path -eq '/api/discussions' -and $method -eq 'POST') {
                $payload=Read-Body $req;$title=([string]$payload.title).Trim();$body=([string]$payload.body).Trim();$audience=[string]$payload.audience;$classYear=([string]$payload.classYear).Trim();$groupId=[string]$payload.groupId;$memberIds=@();$validAudience=$true
                switch($audience){'site'{$memberIds=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true}|ForEach-Object{$_.id})}'class'{if(-not $classYear -or $classYear.Length -gt 4){$validAudience=$false}else{$memberIds=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and [string]$_.classYear -eq $classYear}|ForEach-Object{$_.id})}}'group'{$group=$db.discussionGroups|Where-Object{$_.id -eq $groupId}|Select-Object -First 1;if(-not $group -or ($group.ownerId -ne $user.id -and -not (Has-Permission $user 'profiles') -and @($group.memberIds) -notcontains $user.id)){$validAudience=$false}else{$memberIds=@($group.memberIds)}}'selected'{$requested=@($payload.memberIds|ForEach-Object{[string]$_}|Select-Object -Unique);$memberIds=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.id -in $requested}|ForEach-Object{$_.id});if($requested.Count -gt 100 -or $memberIds.Count -lt 1){$validAudience=$false}}default{$validAudience=$false}}
                $memberIds=@($memberIds+$user.id|Select-Object -Unique);if($title.Length -lt 4 -or $title.Length -gt 120 -or $body.Length -lt 1 -or $body.Length -gt 3000 -or -not $validAudience){Send-Json $ctx 400 @{error='Check the topic, message, audience, and audience selections.'};continue}
                $discussion=@{id=[guid]::NewGuid().ToString('N');title=$title;body=$body;authorId=$user.id;author=$user.name;audience=$audience;classYear=$(if($audience -eq 'class'){$classYear}else{$null});groupId=$(if($audience -eq 'group'){$groupId}else{$null});memberIds=$memberIds;replies=@();created=(Get-Date).ToString('o');updated=(Get-Date).ToString('o')};$db.discussions+= $discussion;Write-Database $db;Send-Json $ctx 201 @{ok=$true};continue
            }
            if ($path -match '^/api/discussions/([a-f0-9]{32})/replies$' -and $method -eq 'POST') {
                $discussion=$db.discussions|Where-Object{$_.id -eq $Matches[1]}|Select-Object -First 1;if(-not $discussion){Send-Json $ctx 404 @{error='Discussion not found.'};continue};if(-not (Test-DiscussionAccess $user $discussion $db)){Send-Json $ctx 403 @{error='This discussion is only available to its selected audience.'};continue};$payload=Read-Body $req;$body=([string]$payload.body).Trim();if($body.Length -lt 1 -or $body.Length -gt 2000){Send-Json $ctx 400 @{error='Replies must be between 1 and 2,000 characters.'};continue};$discussion.replies+=@{id=[guid]::NewGuid().ToString('N');authorId=$user.id;body=$body;created=(Get-Date).ToString('o')};$discussion.updated=(Get-Date).ToString('o');Write-Database $db;Send-Json $ctx 201 @{ok=$true};continue
            }
            if ($path -match '^/api/discussions/([a-f0-9]{32})/members$' -and $method -eq 'PATCH') {
                $discussion=$db.discussions|Where-Object{$_.id -eq $Matches[1]}|Select-Object -First 1;if(-not $discussion){Send-Json $ctx 404 @{error='Discussion not found.'};continue};if($discussion.authorId -ne $user.id -and -not (Has-Permission $user 'profiles')){Send-Json $ctx 403 @{error='Only the topic creator or an administrator can manage its audience.'};continue};if($discussion.audience -ne 'selected'){Send-Json $ctx 400 @{error='Only selected-member discussions have an editable participant list.'};continue};$payload=Read-Body $req;$requested=@($payload.memberIds|ForEach-Object{[string]$_}|Select-Object -Unique);$memberIds=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.id -in $requested}|ForEach-Object{$_.id});$memberIds=@($memberIds+$discussion.authorId|Select-Object -Unique);if($requested.Count -gt 100 -or $memberIds.Count -gt 101){Send-Json $ctx 400 @{error='Select no more than 100 participants.'};continue};$discussion.memberIds=$memberIds;$discussion.updated=(Get-Date).ToString('o');Write-Database $db;Send-Json $ctx 200 @{ok=$true};continue
            }
            if ($path -eq '/api/profile/photo' -and $method -eq 'POST') {
                $payload=Read-Body $req; $image=[string]$payload.image
                if ($image.Length -gt 2800000) { Send-Json $ctx 400 @{error='Choose an image under 2 MB.'}; continue }
                if ($image -match '^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$') { $format=$Matches[1]; $encodedImage=$Matches[2] } else { Send-Json $ctx 400 @{error='Choose a PNG, JPEG, or WebP image.'}; continue }
                try { $bytes=[Convert]::FromBase64String($encodedImage) } catch { Send-Json $ctx 400 @{error='The image file could not be read.'}; continue }
                if ($bytes.Length -lt 16 -or $bytes.Length -gt 2097152) { Send-Json $ctx 400 @{error='Profile photos must be between 16 bytes and 2 MB.'}; continue }
                $validImage=$false
                if ($format -eq 'png' -and [BitConverter]::ToString($bytes[0..7]) -eq '89-50-4E-47-0D-0A-1A-0A') { $extension='png'; $validImage=$true }
                elseif ($format -eq 'jpeg' -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255) { $extension='jpg'; $validImage=$true }
                elseif ($format -eq 'webp' -and [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP') { $extension='webp'; $validImage=$true }
                if (-not $validImage) { Send-Json $ctx 400 @{error='The file contents do not match a supported image type.'}; continue }
                foreach ($oldExtension in @('png','jpg','webp')) { $oldPath=Join-Path $uploadDir ($user.id+'.'+$oldExtension); if (Test-Path $oldPath) { Remove-Item -LiteralPath $oldPath -Force } }
                [System.IO.File]::WriteAllBytes((Join-Path $uploadDir ($user.id+'.'+$extension)),$bytes); $user.photoUrl="/uploads/$($user.id).$extension"; Write-Database $db; Send-Json $ctx 200 @{photoUrl=$user.photoUrl}; continue
            }
            if ($path -eq '/api/profile/photo' -and $method -eq 'DELETE') {
                foreach ($oldExtension in @('png','jpg','webp')) { $oldPath=Join-Path $uploadDir ($user.id+'.'+$oldExtension); if (Test-Path $oldPath) { Remove-Item -LiteralPath $oldPath -Force } }
                $user.photoUrl=$null; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/profile' -and $method -eq 'PATCH') {
                $payload=Read-Body $req; $user.name=([string]$payload.name).Trim(); $user.classYear=([string]$payload.classYear).Trim(); $user.city=([string]$payload.city).Trim(); $user.bio=([string]$payload.bio).Trim(); $user.phone=([string]$payload.phone).Trim(); $user.occupation=([string]$payload.occupation).Trim(); $user.employer=([string]$payload.employer).Trim(); $user.interests=([string]$payload.interests).Trim(); $user.website=([string]$payload.website).Trim(); foreach($socialField in @('linkedin','facebook','instagram','tiktok')){$user.$socialField=([string]$payload.$socialField).Trim()};$user.maritalStatus=([string]$payload.maritalStatus).Trim();$user.hasChildren=([string]$payload.hasChildren).Trim();$requestedSchools=@();if($null -ne $payload.schoolsAttended){$requestedSchools=@($payload.schoolsAttended)};$selectedSchools=@($requestedSchools|ForEach-Object{[string]$_}|Where-Object{$_ -in $schoolOptions}|Select-Object -Unique)
                if($user.name.Length -lt 2){Send-Json $ctx 400 @{error='Please enter a name.'};continue}
                if($user.name.Length -gt 90 -or $user.classYear.Length -gt 4 -or $user.city.Length -gt 100 -or $user.bio.Length -gt 500 -or $user.phone.Length -gt 40 -or $user.occupation.Length -gt 100 -or $user.employer.Length -gt 100 -or $user.interests.Length -gt 300 -or $user.website.Length -gt 200 -or $user.linkedin.Length -gt 250 -or $user.facebook.Length -gt 250 -or $user.instagram.Length -gt 250 -or $user.tiktok.Length -gt 250){Send-Json $ctx 400 @{error='One or more profile fields are too long.'};continue}
                if($user.website -and $user.website -notmatch '^https?://'){Send-Json $ctx 400 @{error='Website links must begin with http:// or https://.'};continue}
                $badSocial=$false;foreach($socialField in @('linkedin','facebook','instagram','tiktok')){if($user.$socialField -and $user.$socialField -notmatch '^https?://'){$badSocial=$true}};if($badSocial){Send-Json $ctx 400 @{error='Social profile links must begin with http:// or https://.'};continue}
                if($user.maritalStatus -notin @('','Single','Married','Separated','Divorced','Widowed','Prefer not to say') -or $user.hasChildren -notin @('','Yes','No','Prefer not to say') -or $requestedSchools.Count -ne $selectedSchools.Count){Send-Json $ctx 400 @{error='Check your family details and school selections.'};continue};$user.schoolsAttended=$selectedSchools
                $visibility=@{};foreach($field in @('name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','maritalStatus','hasChildren','schoolsAttended','photo')){$visibility[$field]=[bool]$payload.profileVisibility.$field};$user.profileVisibility=$visibility;$user.emailVisibility=if($visibility.email){'members'}else{'private'}
                Write-Database $db; Send-Json $ctx 200 @{user=(Public-User $user $user.id)}; continue
            }
            if ($path -eq '/api/posts' -and $method -eq 'POST') {
                $payload=Read-Body $req; $body=([string]$payload.body).Trim(); if($body.Length -lt 1 -or $body.Length -gt 1500){Send-Json $ctx 400 @{error='Posts must be between 1 and 1,500 characters.'};continue}
                $db.posts += @{id=[guid]::NewGuid().ToString('N'); author=$user.name; authorId=$user.id; authorPhoto=$user.photoUrl; created=(Get-Date).ToString('o'); body=$body}; Write-Database $db; Send-Json $ctx 201 @{ok=$true}; continue
            }
            if ($path -eq '/api/reports' -and $method -eq 'POST') {
                $payload=Read-Body $req;$targetId=[string]$payload.postId;$reason=([string]$payload.reason).Trim();$post=$db.homePosts|Where-Object{$_.id -eq $targetId -and $_.audience -eq 'public'}|Select-Object -First 1
                if(-not $post -or $reason.Length -lt 5 -or $reason.Length -gt 500){Send-Json $ctx 400 @{error='Choose a public announcement and provide a reason from 5 to 500 characters.'};continue}
                if($db.reports|Where-Object{$_.reporterId -eq $user.id -and $_.targetId -eq $targetId -and $_.status -eq 'open'}){Send-Json $ctx 409 @{error='You have already reported this announcement.'};continue}
                $db.reports+=@{id=[guid]::NewGuid().ToString('N');targetType='homePost';targetId=$targetId;reporterId=$user.id;reason=$reason;status='open';created=(Get-Date).ToString('o')};Write-Database $db;Send-Json $ctx 201 @{ok=$true};continue
            }
            if ($path -eq '/api/events' -and $method -eq 'POST') {
                $payload=Read-Body $req; $title=([string]$payload.title).Trim(); $date=([string]$payload.date).Trim(); $time=([string]$payload.time).Trim(); $endTime=([string]$payload.endTime).Trim(); $location=([string]$payload.location).Trim(); $details=([string]$payload.details).Trim(); $category=([string]$payload.category).Trim(); if(-not $category){$category='Other'}; $registrationUrl=([string]$payload.registrationUrl).Trim(); $capacity=0; $parsedDate=[datetime]::MinValue
                $validDate=[datetime]::TryParseExact($date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsedDate)
                if($payload.capacity -and (-not [int]::TryParse([string]$payload.capacity,[ref]$capacity) -or $capacity -lt 1 -or $capacity -gt 50000)){$capacity= -1}
                if ($title.Length -lt 3 -or $title.Length -gt 100 -or -not $validDate -or $parsedDate.Date -lt [datetime]::Today -or $time.Length -gt 40 -or $endTime.Length -gt 40 -or $location.Length -lt 2 -or $location.Length -gt 120 -or $details.Length -gt 1000 -or $category -notin @('Reunion','School','Social','Fundraiser','Other') -or $capacity -lt 0 -or $registrationUrl.Length -gt 300 -or ($registrationUrl -and $registrationUrl -notmatch '^https?://')) { Send-Json $ctx 400 @{error='Check the event title, date, times, location, category, capacity, registration link, and details.'}; continue }
                $eventId=[guid]::NewGuid().ToString('N');$newEvent=@{id=$eventId; title=$title; date=$date; time=$time; endTime=$endTime; location=$location; details=$details; category=$category; registrationUrl=$registrationUrl; imageUrl=$null;capacity=$capacity; organizerId=$user.id; rsvps=@(); invitations=@()};if($payload.image){try{$newEvent.imageUrl=Save-EventImage $eventId ([string]$payload.image)}catch{Send-Json $ctx 400 @{error=$_.Exception.Message};continue}};$db.events += $newEvent; Write-Database $db; Send-Json $ctx 201 @{ok=$true}; continue
            }
            if ($path -match '^/api/events/([^/]+)/invite$' -and $method -eq 'POST') {
                $eventId=$Matches[1];$event=$db.events|Where-Object{$_.id -eq $eventId}|Select-Object -First 1;if(-not $event){Send-Json $ctx 404 @{error='That event could not be found.'};continue}
                $payload=Read-Body $req;$recipientId=[string]$payload.userId;$recipient=$db.users|Where-Object{$_.id -eq $recipientId}|Select-Object -First 1
                if(-not $recipient -or $recipient.id -eq $user.id){Send-Json $ctx 400 @{error='Choose another member to invite.'};continue}
                if(-not $event.PSObject.Properties['invitations']){$event|Add-Member -NotePropertyName invitations -NotePropertyValue @()}
                $invitation=$event.invitations|Where-Object{$_.toId -eq $recipient.id}|Select-Object -First 1
                if($invitation){$invitation.fromId=$user.id;$invitation.sentAt=(Get-Date).ToString('o')}else{$event.invitations+=@{fromId=$user.id;toId=$recipient.id;sentAt=(Get-Date).ToString('o')}}
                Write-Database $db;$sent=$false
                if($recipient.emailVerified -ne $false){$url="$(Get-PublicBaseUrl)/community";$sent=Send-AppEmail $recipient.email "You're invited: $($event.title)" "$($user.name) invited you to this Jefferson Alumni event:`r`n`r`n$($event.title)`r`nDate: $($event.date) at $($event.time)`r`nLocation: $($event.location)`r`n`r`n$($event.details)`r`n`r`nSign in to view the event and RSVP: $url"}
                Send-Json $ctx 200 @{ok=$true;emailSent=$sent};continue
            }
            if ($path -match '^/api/events/([^/]+)/rsvp$' -and $method -eq 'POST') {
                $eventId=$Matches[1]; $event=$db.events | Where-Object { $_.id -eq $eventId } | Select-Object -First 1; if (-not $event) { Send-Json $ctx 404 @{error='That event could not be found.'}; continue }
                $payload=Read-Body $req; $status=[string]$payload.status; if ($status -notin @('going','maybe','not-going')) { Send-Json $ctx 400 @{error='Choose going, maybe, or not going.'}; continue }
                if (-not $event.PSObject.Properties['rsvps']) { $event | Add-Member -NotePropertyName rsvps -NotePropertyValue @() }
                $existing=$event.rsvps | Where-Object { $_.userId -eq $user.id } | Select-Object -First 1
                if($status -eq 'going' -and [int]$event.capacity -gt 0 -and (-not $existing -or $existing.status -ne 'going') -and @($event.rsvps|Where-Object{$_.status -eq 'going'}).Count -ge [int]$event.capacity){Send-Json $ctx 409 @{error='This event has reached its RSVP capacity.'};continue}
                $previous=if($existing){[string]$existing.status}else{''}; $updatedAt=(Get-Date).ToString('o')
                if ($existing) { $existing.status=$status; $existing.updated=$updatedAt } else { $event.rsvps += @{userId=$user.id; status=$status; updated=$updatedAt} }
                Write-Database $db
                if ($previous -ne $status -and $event.organizerId) { $organizer=$db.users | Where-Object {$_.id -eq $event.organizerId -and $_.emailVerified -ne $false} | Select-Object -First 1; if($organizer){[void](Send-AppEmail $organizer.email "Event RSVP update: $($event.title)" "$($user.name) changed their RSVP to '$status'.`r`n`r`nEvent: $($event.title)`r`nDate: $($event.date) at $($event.time)`r`nLocation: $($event.location)")} }
                Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/admin' -and $method -eq 'GET') {
                if (-not (Has-AnyPermission $user)) { Send-Json $ctx 403 @{error='You do not have administration access.'}; continue }
                $result=@{permissions=$user.permissions}
                if (Has-Permission $user 'permissions') { $result.permissionUsers=@($db.users | ForEach-Object { @{id=$_.id;name=$_.name;role=$_.role;classYear=$_.classYear;permissions=$_.permissions} }) }
                if (Has-Permission $user 'approveUsers') { $result.pendingUsers=@($db.users | Where-Object {$_.approved -eq $false}|Sort-Object created -Descending|ForEach-Object{@{id=$_.id;name=$_.name;email=$_.email;role=$_.role;classYear=$_.classYear;emailVerified=$_.emailVerified;created=$_.created}}) }
                if (Has-Permission $user 'moderate') { $result.reports=@($db.reports|Where-Object{$_.status -eq 'open'}|Sort-Object created -Descending|ForEach-Object{$report=$_;$post=$db.homePosts|Where-Object{$_.id -eq $report.targetId}|Select-Object -First 1;$reporter=$db.users|Where-Object{$_.id -eq $report.reporterId}|Select-Object -First 1;@{id=$report.id;targetId=$report.targetId;reason=$report.reason;created=$report.created;reporter=$(if($reporter){$reporter.name}else{'Former member'});title=$(if($post){$post.title}else{'Removed announcement'});body=$(if($post){$post.body}else{''});author=$(if($post){$post.author}else{''})}}) }
                if (Has-Permission $user 'audit') { $result.auditLog=@($db.auditLog|Sort-Object created -Descending|Select-Object -First 100) }
                if (Has-Permission $user 'bulkEmail') { $result.bulkMembers=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false}|ForEach-Object{@{id=$_.id;name=$_.name;role=$_.role;classYear=$_.classYear}});$result.bulkGroups=@($db.discussionGroups|ForEach-Object{@{id=$_.id;name=$_.name;memberIds=@($_.memberIds)}}) }
                if (Has-Permission $user 'profiles') { $result.members=@($db.users | ForEach-Object { Public-User $_ $user.id $true }) }
                if (Has-Permission $user 'events') { $result.events=@($db.events | Sort-Object date | ForEach-Object { Public-Event $_ $db $user.id }) }
                if (Has-Permission $user 'posts') { $result.posts=@($db.posts | Sort-Object created -Descending) }
                if (Has-Permission $user 'homepagePosts') { $result.homePosts=@($db.homePosts | Sort-Object created -Descending) }
                if (Has-Permission $user 'customize') { $result.site=(Public-Site $db) }
                Send-Json $ctx 200 $result; continue
            }
            if ($path -eq '/api/admin/backup' -and $method -eq 'GET') {
                if (-not (Has-Permission $user 'permissions')) { Send-Json $ctx 403 @{error='Only a site access administrator can download a full data backup.'}; continue }
                $ctx.Response.Headers.Add('Content-Disposition','attachment; filename="jefferson-alumni-backup.json"'); Send-Text $ctx 200 (ConvertTo-Json -InputObject $db -Depth 12) 'application/json; charset=utf-8'; continue
            }
            if ($path -eq '/api/admin/bulk-email' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'bulkEmail')) { Send-Json $ctx 403 @{error='You do not have permission to send bulk email.'}; continue }
                $payload=Read-Body $req;$subject=([string]$payload.subject).Trim();$body=([string]$payload.body).Trim();$audience=[string]$payload.audience;$targetUsers=@()
                switch($audience){'all'{$targetUsers=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false})}'class'{$year=([string]$payload.classYear).Trim();$targetUsers=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and [string]$_.classYear -eq $year})}'group'{$group=$db.discussionGroups|Where-Object{$_.id -eq [string]$payload.groupId}|Select-Object -First 1;if($group){$ids=@($group.memberIds);$targetUsers=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.id -in $ids})}}'selected'{$ids=@($payload.memberIds|ForEach-Object{[string]$_}|Select-Object -Unique);$targetUsers=@($db.users|Where-Object{$_.approved -ne $false -and $_.suspended -ne $true -and $_.emailVerified -ne $false -and $_.id -in $ids})}default{$targetUsers=@()}}
                $targetUsers=@($targetUsers|Sort-Object id -Unique);if($subject.Length -lt 3 -or $subject.Length -gt 140 -or $subject -match '[\r\n]' -or $body.Length -lt 1 -or $body.Length -gt 5000){Send-Json $ctx 400 @{error='Enter a subject (3–140 characters) and message (up to 5,000 characters).'};continue};if($audience -notin @('all','class','group','selected') -or $targetUsers.Count -lt 1 -or $targetUsers.Count -gt 500){Send-Json $ctx 400 @{error='Choose a valid audience with between 1 and 500 approved, email-verified recipients.'};continue}
                $sent=0;$failed=0;foreach($recipient in $targetUsers){if(Send-AppEmail ([string]$recipient.email) $subject $body){$sent++}else{$failed++}};Add-AuditEntry $db $user 'sentBulkEmail' 'email' $audience "Sent bulk email '$subject' to $sent of $($targetUsers.Count) recipient(s)";Write-Database $db;Send-Json $ctx 200 @{total=$targetUsers.Count;sent=$sent;failed=$failed};continue
            }
            if ($path -match '^/api/admin/approvals/([a-f0-9]{32})/approve$' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'approveUsers')) { Send-Json $ctx 403 @{error='You do not have permission to approve new members.'}; continue }
                $targetId=$Matches[1];$target=$db.users|Where-Object{$_.id -eq $targetId -and $_.approved -eq $false}|Select-Object -First 1;if(-not $target){Send-Json $ctx 404 @{error='Pending member not found.'};continue}
                Set-ObjectProperty $target 'approved' $true;Set-ObjectProperty $target 'approvalStatus' 'approved';Set-ObjectProperty $target 'approvedAt' (Get-Date).ToString('o');try{Add-AuditEntry $db $user 'approved' 'member' $target.id "Approved registration for $($target.name)"}catch{Write-Warning "Could not add approval to audit history: $($_.Exception.Message)"};try{Write-Database $db}catch{Write-Warning "Could not save member approval: $($_.Exception.Message)";Send-Json $ctx 500 @{error='The approval could not be saved. Check that the server can write to the data folder and try again.'};continue}
                if($target.emailVerified -ne $false){[void](Send-AppEmail $target.email 'Your Jefferson Alumni account is approved' "Hello $($target.name),`r`n`r`nYour account has been approved. You can now sign in to the Jefferson Alumni community.")};Send-Json $ctx 200 @{ok=$true};continue
            }
            if ($path -match '^/api/admin/reports/([a-f0-9]{32})/(hide|dismiss)$' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'moderate')) { Send-Json $ctx 403 @{error='You do not have permission to moderate public content.'}; continue }
                $reportId=$Matches[1];$action=$Matches[2];$report=$db.reports|Where-Object{$_.id -eq $reportId -and $_.status -eq 'open'}|Select-Object -First 1;if(-not $report){Send-Json $ctx 404 @{error='Open report not found.'};continue}
                if($action -eq 'hide'){$post=$db.homePosts|Where-Object{$_.id -eq $report.targetId}|Select-Object -First 1;if($post){$post.audience='members'}};$report.status=if($action -eq 'hide'){'hidden'}else{'dismissed'};$report.resolvedAt=(Get-Date).ToString('o');$report.resolvedBy=$user.id;Add-AuditEntry $db $user $action 'homePostReport' $report.id "${action} report for homepage announcement $($report.targetId)";Write-Database $db;Send-Json $ctx 200 @{ok=$true};continue
            }
            if ($path -eq '/api/admin/export' -and $method -eq 'GET') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to export member profiles.'}; continue }
                $rows=@($db.users | ForEach-Object { $row=[ordered]@{}; foreach($key in @('name','email','role','classYear','city','bio','phone','occupation','employer','interests','website')){$value=[string]$_.$key;if($value -match '^\s*[=+@-]'){$value="'$value"};$row[$key]=$value};[pscustomobject]$row })
                $csv=if($rows.Count){$rows | ConvertTo-Csv -NoTypeInformation | Out-String}else{'"name","email","role","classYear","city","bio","phone","occupation","employer","interests","website"'}
                $ctx.Response.Headers.Add('Content-Disposition','attachment; filename="jefferson-members.csv"'); Send-Text $ctx 200 $csv 'text/csv; charset=utf-8'; continue
            }
            if ($path -eq '/api/admin/import' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to import member profiles.'}; continue }
                $payload=Read-Body $req; $csvText=[string]$payload.csv
                if ([string]::IsNullOrWhiteSpace($csvText) -or $csvText.Length -gt 2000000) { Send-Json $ctx 400 @{error='Choose a CSV file with data under 2 MB.'}; continue }
                try { $rows=@($csvText | ConvertFrom-Csv -ErrorAction Stop) } catch { Send-Json $ctx 400 @{error='The CSV could not be read. Include a header row and valid CSV formatting.'}; continue }
                if ($rows.Count -gt 1000) { Send-Json $ctx 400 @{error='Import at most 1,000 member rows at a time.'}; continue }
                $existingEmails=@{}; foreach($member in $db.users){$existingEmails[[string]$member.email]=$true}; $imported=0; $skipped=0; $inviteEmailsSent=0
                foreach($row in $rows){
                    $name=([string]$row.name).Trim(); $email=([string]$row.email).Trim().ToLowerInvariant(); $role=([string]$row.role).Trim(); if(-not $role){$role='Alumni'}
                    if($name.Length -lt 2 -or $name.Length -gt 90 -or $email.Length -gt 254 -or $email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$' -or $role -notin @('Alumni','Teacher','Staff') -or ([string]$row.classYear).Length -gt 4 -or ([string]$row.city).Length -gt 100 -or ([string]$row.bio).Length -gt 500 -or ([string]$row.phone).Length -gt 40 -or ([string]$row.occupation).Length -gt 100 -or ([string]$row.employer).Length -gt 100 -or ([string]$row.interests).Length -gt 300 -or ([string]$row.website).Length -gt 200 -or ($row.website -and [string]$row.website -notmatch '^https?://') -or $existingEmails.ContainsKey($email)){$skipped++;continue}
                    $rawToken=New-SecureToken; $secret=New-PasswordRecord (New-SecureToken); $newUser=@{id=[guid]::NewGuid().ToString('N');name=$name;email=$email;salt=$secret.salt;hash=$secret.hash;role=$role;classYear=([string]$row.classYear).Trim();city=([string]$row.city).Trim();bio=([string]$row.bio).Trim();phone=([string]$row.phone).Trim();occupation=([string]$row.occupation).Trim();employer=([string]$row.employer).Trim();interests=([string]$row.interests).Trim();website=([string]$row.website).Trim();linkedin='';facebook='';instagram='';tiktok='';maritalStatus='';hasChildren='';schoolsAttended=@();profileVisibility=@{name=$true;email=$true;role=$true;classYear=$true;city=$true;bio=$true;phone=$true;occupation=$true;employer=$true;interests=$true;website=$true;linkedin=$true;facebook=$true;instagram=$true;tiktok=$true;maritalStatus=$false;hasChildren=$false;schoolsAttended=$false;photo=$true};emailVisibility='members';photoUrl=$null;emailVerified=$false;approved=$true;approvalStatus='approved';verificationHash=(Get-TokenHash $rawToken);verificationExpires=(Get-Date).AddDays(7).ToString('o');resetHash=(Get-TokenHash $rawToken);resetExpires=(Get-Date).AddDays(7).ToString('o');permissions=@{profiles=$false;events=$false;posts=$false;homepagePosts=$false;approveUsers=$false;moderate=$false;audit=$false;bulkEmail=$false;customize=$false;permissions=$false};created=(Get-Date).ToString('o')}; $db.users+= $newUser; $existingEmails[$email]=$true; $imported++
                    $url="$(Get-PublicBaseUrl)/community?reset=$rawToken"; if(Send-AppEmail $email 'Your Jefferson Alumni account' "Hello $name,`r`n`r`nAn account has been created for you. Use this link within 7 days to set your password and verify your email:`r`n$url"){$inviteEmailsSent++}
                }
                if($imported){Write-Database $db}; Send-Json $ctx 200 @{imported=$imported;skipped=$skipped;inviteEmailsSent=$inviteEmailsSent}; continue
            }
            if ($path -eq '/api/admin/users' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to create member profiles.'}; continue }
                $payload=Read-Body $req; $name=([string]$payload.name).Trim(); $email=([string]$payload.email).Trim().ToLowerInvariant(); $password=[string]$payload.password; $role=[string]$payload.role
                if ($name.Length -lt 2 -or $name.Length -gt 90 -or $email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$' -or -not (Test-PasswordPolicy $password) -or $role -notin @('Alumni','Teacher','Staff')) { Send-Json $ctx 400 @{error='Enter a name, valid email, school connection, and a passphrase of 15–200 characters that is not common or repetitive.'}; continue }
                if ($db.users | Where-Object { $_.email -eq $email }) { Send-Json $ctx 409 @{error='An account with that email already exists.'}; continue }
                $secret=New-PasswordRecord $password; $newUser=@{id=[guid]::NewGuid().ToString('N');name=$name;email=$email;salt=$secret.salt;hash=$secret.hash;role=$role;classYear=([string]$payload.classYear).Trim();city='';bio='';phone='';occupation='';employer='';interests='';website='';linkedin='';facebook='';instagram='';tiktok='';maritalStatus='';hasChildren='';schoolsAttended=@();profileVisibility=@{name=$true;email=$true;role=$true;classYear=$true;city=$true;bio=$true;phone=$true;occupation=$true;employer=$true;interests=$true;website=$true;linkedin=$true;facebook=$true;instagram=$true;tiktok=$true;maritalStatus=$false;hasChildren=$false;schoolsAttended=$false;photo=$true};emailVisibility='members';photoUrl=$null;emailVerified=$true;approved=$true;approvalStatus='approved';verificationHash=$null;verificationExpires=$null;resetHash=$null;resetExpires=$null;permissions=@{profiles=$false;events=$false;posts=$false;homepagePosts=$false;approveUsers=$false;moderate=$false;audit=$false;bulkEmail=$false;customize=$false;permissions=$false};created=(Get-Date).ToString('o')}
                $db.users += $newUser; Write-Database $db; Send-Json $ctx 201 @{ok=$true;user=(Public-User $newUser $user.id)}; continue
            }
            if ($path -match '^/api/admin/users/([a-f0-9]{32})/suspension$' -and $method -eq 'PATCH') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to manage member profiles.'}; continue }
                $targetId=$Matches[1];$target=$db.users|Where-Object{$_.id -eq $targetId}|Select-Object -First 1;if(-not $target){Send-Json $ctx 404 @{error='Member not found.'};continue}
                if($target.id -eq $user.id){Send-Json $ctx 400 @{error='You cannot suspend your own account.'};continue}
                $payload=Read-Body $req;$suspended=[bool]$payload.suspended;Set-ObjectProperty $target 'suspended' $suspended
                if($suspended){foreach($sessionKey in @($script:sessions.Keys)){if($script:sessions[$sessionKey] -eq $target.id){$script:sessions.Remove($sessionKey)|Out-Null}}}
                Add-AuditEntry $db $user $(if($suspended){'suspended'}else{'reinstated'}) 'member' $target.id "$(if($suspended){'Suspended'}else{'Reinstated'}) account for $($target.name)";Write-Database $db;Send-Json $ctx 200 @{ok=$true;suspended=$suspended};continue
            }
            if ($path -match '^/api/admin/users/([a-f0-9]{32})$' -and $method -eq 'DELETE') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to manage member profiles.'}; continue }
                $targetId=$Matches[1];$target=$db.users|Where-Object{$_.id -eq $targetId}|Select-Object -First 1;if(-not $target){Send-Json $ctx 404 @{error='Member not found.'};continue}
                if($target.id -eq $user.id){Send-Json $ctx 400 @{error='You cannot delete your own account.'};continue}
                if($target.permissions.permissions -and @($db.users|Where-Object{$_.id -ne $target.id -and $_.permissions.permissions}).Count -eq 0){Send-Json $ctx 400 @{error='Transfer site access administration to another member before deleting this account.'};continue}
                $db.users=@($db.users|Where-Object{$_.id -ne $target.id});$db.messages=@($db.messages|Where-Object{$_.fromId -ne $target.id -and $_.toId -ne $target.id});$db.discussionGroups=@($db.discussionGroups|ForEach-Object{$_.memberIds=@($_.memberIds|Where-Object{$_ -ne $target.id});if($_.ownerId -eq $target.id){$_.ownerId=$user.id};$_})
                foreach($post in @($db.posts|Where-Object{$_.authorId -eq $target.id})){$post.authorId='';$post.author='Former member'}
                foreach($topic in @($db.discussions)){$topic.memberIds=@($topic.memberIds|Where-Object{$_ -ne $target.id});if($topic.authorId -eq $target.id){$topic.authorId='';$topic.author='Former member'}}
                foreach($event in @($db.events)){$rsvps=@();if($event.PSObject.Properties['rsvps']){$rsvps=@($event.rsvps|Where-Object{$_.userId -ne $target.id})};$invitations=@();if($event.PSObject.Properties['invitations']){$invitations=@($event.invitations|Where-Object{$_.toId -ne $target.id -and $_.fromId -ne $target.id})};Set-ObjectProperty $event 'rsvps' $rsvps;Set-ObjectProperty $event 'invitations' $invitations}
                foreach($sessionKey in @($script:sessions.Keys)){if($script:sessions[$sessionKey] -eq $target.id){$script:sessions.Remove($sessionKey)|Out-Null}}
                foreach($extension in @('png','jpg','webp')){$photoPath=Join-Path $uploadDir ($target.id+'.'+$extension);if(Test-Path -LiteralPath $photoPath){Remove-Item -LiteralPath $photoPath -Force}}
                Add-AuditEntry $db $user 'deleted' 'member' $target.id "Deleted member account for $($target.name)";Write-Database $db;Send-Json $ctx 200 @{ok=$true};continue
            }
            if ($path -match '^/api/admin/users/([^/]+)/password$' -and $method -eq 'PATCH') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to reset member passwords.'}; continue }
                $targetId=$Matches[1]; $target=$db.users | Where-Object { $_.id -eq $targetId } | Select-Object -First 1; if (-not $target) { Send-Json $ctx 404 @{error='Member not found.'}; continue }
                $payload=Read-Body $req; $password=[string]$payload.password; if (-not (Test-PasswordPolicy $password)) { Send-Json $ctx 400 @{error='Use a passphrase of 15–200 characters. Common passwords and repeated characters are not allowed.'}; continue }
                $secret=New-PasswordRecord $password; $target.salt=$secret.salt; $target.hash=$secret.hash; $target.emailVerified=$true; $target.verificationHash=$null; $target.verificationExpires=$null; $target.resetHash=$null; $target.resetExpires=$null
                if ($target.id -ne $user.id) { foreach ($sessionKey in @($script:sessions.Keys)) { if ($script:sessions[$sessionKey] -eq $target.id) { $script:sessions.Remove($sessionKey) | Out-Null } } }
                Add-AuditEntry $db $user 'resetPassword' 'member' $target.id "Reset password for $($target.name)"; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/messages' -and $method -eq 'GET') {
                $items=@($db.messages | Where-Object { $_.fromId -eq $user.id -or $_.toId -eq $user.id } | Sort-Object sentAt | ForEach-Object {
                    $message=$_; $from=$db.users | Where-Object { $_.id -eq $message.fromId } | Select-Object -First 1
                    $to=$db.users | Where-Object { $_.id -eq $message.toId } | Select-Object -First 1
                    @{id=$message.id;fromId=$message.fromId;toId=$message.toId;fromName=$from.name;toName=$to.name;body=$message.body;sentAt=$message.sentAt;readAt=$message.readAt}
                })
                Send-Json $ctx 200 @{messages=$items}; continue
            }
            if ($path -eq '/api/messages/read' -and $method -eq 'POST') {
                $payload=Read-Body $req; $otherId=[string]$payload.userId; $changed=$false
                foreach ($message in @($db.messages | Where-Object { $_.toId -eq $user.id -and $_.fromId -eq $otherId -and -not $_.readAt })) { $message.readAt=(Get-Date).ToString('o'); $changed=$true }
                if ($changed) { Write-Database $db }; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/messages' -and $method -eq 'POST') {
                $payload=Read-Body $req; $otherId=[string]$payload.toId; $body=([string]$payload.body).Trim(); $recipient=$db.users | Where-Object { $_.id -eq $otherId } | Select-Object -First 1
                if (-not $recipient -or $otherId -eq $user.id -or $body.Length -lt 1 -or $body.Length -gt 2000) { Send-Json $ctx 400 @{error='Choose another member and enter a message of 1–2,000 characters.'}; continue }
                $db.messages += @{id=[guid]::NewGuid().ToString('N');fromId=$user.id;toId=$recipient.id;body=$body;sentAt=(Get-Date).ToString('o');readAt=$null}; Write-Database $db; Send-Json $ctx 201 @{ok=$true}; continue
            }
            if ($path -match '^/api/admin/users/([^/]+)/profile$' -and $method -eq 'PATCH') {
                if (-not (Has-Permission $user 'profiles')) { Send-Json $ctx 403 @{error='You do not have permission to manage profiles.'}; continue }
                $targetId=$Matches[1]; $target=$db.users | Where-Object { $_.id -eq $targetId } | Select-Object -First 1; if (-not $target) { Send-Json $ctx 404 @{error='Member not found.'}; continue }
                $payload=Read-Body $req; $name=([string]$payload.name).Trim(); $role=[string]$payload.role; $year=([string]$payload.classYear).Trim(); $city=([string]$payload.city).Trim(); $bio=([string]$payload.bio).Trim();$phone=([string]$payload.phone).Trim();$occupation=([string]$payload.occupation).Trim();$employer=([string]$payload.employer).Trim();$interests=([string]$payload.interests).Trim();$website=([string]$payload.website).Trim();$social=@{};foreach($field in @('linkedin','facebook','instagram','tiktok')){$social[$field]=([string]$payload.$field).Trim()};$maritalStatus=([string]$payload.maritalStatus).Trim();$hasChildren=([string]$payload.hasChildren).Trim();$requestedSchools=@();if($null -ne $payload.schoolsAttended){$requestedSchools=@($payload.schoolsAttended)};$selectedSchools=@($requestedSchools|ForEach-Object{[string]$_}|Where-Object{$_ -in $schoolOptions}|Select-Object -Unique)
                if ($name.Length -lt 2 -or $name.Length -gt 90 -or $year.Length -gt 4 -or $city.Length -gt 100 -or $bio.Length -gt 500 -or $phone.Length -gt 40 -or $occupation.Length -gt 100 -or $employer.Length -gt 100 -or $interests.Length -gt 300 -or $website.Length -gt 200 -or ($website -and $website -notmatch '^https?://') -or $role -notin @('Alumni','Teacher','Staff')) { Send-Json $ctx 400 @{error='Check the member profile fields and website link.'}; continue }
                $badSocial=$false;foreach($field in @('linkedin','facebook','instagram','tiktok')){if($social[$field].Length -gt 250 -or ($social[$field] -and $social[$field] -notmatch '^https?://')){$badSocial=$true}};if($badSocial){Send-Json $ctx 400 @{error='Social profile links must be http:// or https:// URLs up to 250 characters.'};continue}
                if($maritalStatus -notin @('','Single','Married','Separated','Divorced','Widowed','Prefer not to say') -or $hasChildren -notin @('','Yes','No','Prefer not to say') -or $requestedSchools.Count -ne $selectedSchools.Count){Send-Json $ctx 400 @{error='Check the family details and school selections.'};continue}
                $target.name=$name; $target.role=$role; $target.classYear=$year; $target.city=$city; $target.bio=$bio;$target.phone=$phone;$target.occupation=$occupation;$target.employer=$employer;$target.interests=$interests;$target.website=$website;foreach($field in $social.Keys){$target.$field=$social[$field]};$target.maritalStatus=$maritalStatus;$target.hasChildren=$hasChildren;$target.schoolsAttended=$selectedSchools
                $visibility=@{};foreach($field in @('name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','maritalStatus','hasChildren','schoolsAttended','photo')){$visibility[$field]=[bool]$payload.profileVisibility.$field};$target.profileVisibility=$visibility;$target.emailVisibility=if($visibility.email){'members'}else{'private'}
                Add-AuditEntry $db $user 'updatedProfile' 'member' $target.id "Updated profile for $($target.name)"; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/admin/permissions' -and $method -eq 'PATCH') {
                if (-not (Has-Permission $user 'permissions')) { Send-Json $ctx 403 @{error='You do not have permission to grant access.'}; continue }
                $payload=Read-Body $req; $target=$db.users | Where-Object { $_.id -eq [string]$payload.userId } | Select-Object -First 1; if (-not $target) { Send-Json $ctx 404 @{error='Member not found.'}; continue }
                $grant=$payload.permissions; $next=@{profiles=[bool]$grant.profiles;events=[bool]$grant.events;posts=[bool]$grant.posts;homepagePosts=[bool]$grant.homepagePosts;approveUsers=[bool]$grant.approveUsers;moderate=[bool]$grant.moderate;audit=[bool]$grant.audit;bulkEmail=[bool]$grant.bulkEmail;customize=[bool]$grant.customize;permissions=[bool]$grant.permissions}
                $permissionAdmins=@($db.users | Where-Object { $_.permissions.permissions }).Count
                if ((-not $next.permissions) -and $target.permissions.permissions -and $permissionAdmins -le 1) { Send-Json $ctx 400 @{error='At least one member must keep permission to manage access.'}; continue }
                $target.permissions=$next; Add-AuditEntry $db $user 'changedPermissions' 'member' $target.id "Updated administration permissions for $($target.name)"; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -match '^/api/admin/events/([^/]+)$' -and $method -eq 'DELETE') {
                if (-not (Has-Permission $user 'events')) { Send-Json $ctx 403 @{error='You do not have permission to manage events.'}; continue }
                $targetId=$Matches[1]; $before=@($db.events).Count; $db.events=@($db.events | Where-Object { $_.id -ne $targetId }); if ($db.events.Count -eq $before) { Send-Json $ctx 404 @{error='Event not found.'}; continue }; foreach($ext in @('png','jpg','webp')){$p=Join-Path $eventUploadDir ($targetId+'.'+$ext);if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -match '^/api/admin/events/([a-zA-Z0-9-]{1,64})/image$' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'events')) { Send-Json $ctx 403 @{error='You do not have permission to manage events.'}; continue }
                $targetId=$Matches[1];$target=$db.events|Where-Object{$_.id -eq $targetId}|Select-Object -First 1;if(-not $target){Send-Json $ctx 404 @{error='Event not found.'};continue}
                try{$payload=Read-Body $req;$imageUrl=Save-EventImage $targetId ([string]$payload.image);if(-not $target.PSObject.Properties['imageUrl']){$target|Add-Member -NotePropertyName imageUrl -NotePropertyValue $imageUrl}else{$target.imageUrl=$imageUrl};Write-Database $db;Send-Json $ctx 200 @{imageUrl=$target.imageUrl}}catch{Write-Warning "Event image upload failed for $targetId`: $($_.Exception.Message)";Send-Json $ctx 400 @{error=$_.Exception.Message}};continue
            }
            if ($path -match '^/api/admin/events/([^/]+)$' -and $method -eq 'PATCH') {
                if (-not (Has-Permission $user 'events')) { Send-Json $ctx 403 @{error='You do not have permission to manage events.'}; continue }
                $targetId=$Matches[1]; $target=$db.events | Where-Object { $_.id -eq $targetId } | Select-Object -First 1; if (-not $target) { Send-Json $ctx 404 @{error='Event not found.'}; continue }
                $payload=Read-Body $req; $title=([string]$payload.title).Trim(); $date=([string]$payload.date).Trim(); $time=([string]$payload.time).Trim(); $endTime=([string]$payload.endTime).Trim(); $location=([string]$payload.location).Trim(); $details=([string]$payload.details).Trim(); $category=([string]$payload.category).Trim();if(-not $category){$category='Other'};$registrationUrl=([string]$payload.registrationUrl).Trim();$capacity=0;$parsedDate=[datetime]::MinValue
                $validDate=[datetime]::TryParseExact($date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsedDate)
                if($payload.capacity -and (-not [int]::TryParse([string]$payload.capacity,[ref]$capacity) -or $capacity -lt 1 -or $capacity -gt 50000)){$capacity= -1}
                if ($title.Length -lt 3 -or $title.Length -gt 100 -or -not $validDate -or $time.Length -gt 40 -or $endTime.Length -gt 40 -or $location.Length -lt 2 -or $location.Length -gt 120 -or $details.Length -gt 1000 -or $category -notin @('Reunion','School','Social','Fundraiser','Other') -or $capacity -lt 0 -or $registrationUrl.Length -gt 300 -or ($registrationUrl -and $registrationUrl -notmatch '^https?://')) { Send-Json $ctx 400 @{error='Check the event fields and registration link.'}; continue }
                $target.title=$title; $target.date=$date; $target.time=$time; $target.endTime=$endTime; $target.location=$location; $target.details=$details;$target.category=$category;$target.registrationUrl=$registrationUrl;$target.capacity=$capacity; Add-AuditEntry $db $user 'updated' 'event' $target.id "Updated event $title"; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -match '^/api/admin/posts/([^/]+)$' -and $method -eq 'DELETE') {
                if (-not (Has-Permission $user 'posts')) { Send-Json $ctx 403 @{error='You do not have permission to manage posts.'}; continue }
                $targetId=$Matches[1]; $before=@($db.posts).Count; $db.posts=@($db.posts | Where-Object { $_.id -ne $targetId }); if ($db.posts.Count -eq $before) { Send-Json $ctx 404 @{error='Post not found.'}; continue }; Add-AuditEntry $db $user 'deleted' 'communityPost' $targetId "Removed community post $targetId"; Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/admin/home-posts' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'homepagePosts')) { Send-Json $ctx 403 @{error='You do not have permission to publish homepage announcements.'}; continue }
                $payload=Read-Body $req;$title=([string]$payload.title).Trim();$body=([string]$payload.body).Trim();$audience=[string]$payload.audience
                if($title.Length -lt 3 -or $title.Length -gt 100 -or $body.Length -lt 1 -or $body.Length -gt 1500 -or $audience -notin @('public','members')){Send-Json $ctx 400 @{error='Check the announcement title, message, and visibility.'};continue}
                $postId=[guid]::NewGuid().ToString('N');$imageUrl=$null
                try{if($payload.image){$imageUrl=Save-HomePostImage $postId ([string]$payload.image)}}catch{Send-Json $ctx 400 @{error=$_.Exception.Message};continue}
                $db.homePosts += @{id=$postId;title=$title;body=$body;audience=$audience;imageUrl=$imageUrl;author=$user.name;created=(Get-Date).ToString('o')};Add-AuditEntry $db $user 'published' 'homePost' $postId "Published homepage announcement $title";Write-Database $db;Send-Json $ctx 201 @{ok=$true};continue
            }
            if ($path -match '^/api/admin/home-posts/([a-f0-9]{32})$' -and $method -eq 'DELETE') {
                if (-not (Has-Permission $user 'homepagePosts')) { Send-Json $ctx 403 @{error='You do not have permission to manage homepage announcements.'}; continue }
                $targetId=$Matches[1];$target=$db.homePosts|Where-Object{$_.id -eq $targetId}|Select-Object -First 1;if(-not $target){Send-Json $ctx 404 @{error='Homepage announcement not found.'};continue};$db.homePosts=@($db.homePosts|Where-Object{$_.id -ne $targetId});foreach($ext in @('png','jpg','webp')){$p=Join-Path $homePostUploadDir ($targetId+'.'+$ext);if(Test-Path $p){Remove-Item -LiteralPath $p -Force}};Add-AuditEntry $db $user 'deleted' 'homePost' $targetId "Removed homepage announcement $($target.title)";Write-Database $db;Send-Json $ctx 200 @{ok=$true};continue
            }
            if ($path -eq '/api/admin/site' -and $method -eq 'PATCH') {
                if (-not (Has-Permission $user 'customize')) { Send-Json $ctx 403 @{error='You do not have permission to customize the site.'}; continue }
                $payload=Read-Body $req; $title=([string]$payload.title).Trim(); $tagline=([string]$payload.tagline).Trim();$primary=[string]$payload.primaryColor;$accent=[string]$payload.accentColor;$font=[string]$payload.fontFamily
                if ($title.Length -lt 3 -or $title.Length -gt 60 -or $tagline.Length -lt 5 -or $tagline.Length -gt 180 -or $primary -notmatch '^#[0-9a-fA-F]{6}$' -or $accent -notmatch '^#[0-9a-fA-F]{6}$' -or $font -notin @('system','georgia','arial','verdana','trebuchet')) { Send-Json $ctx 400 @{error='Check the title, tagline, color values, and font selection.'}; continue }
                $db.site.title=$title; $db.site.tagline=$tagline;$db.site.primaryColor=$primary;$db.site.accentColor=$accent;$db.site.fontFamily=$font;Add-AuditEntry $db $user 'updated' 'siteAppearance' 'site' 'Updated website appearance settings';Write-Database $db; Send-Json $ctx 200 @{ok=$true}; continue
            }
            if ($path -eq '/api/admin/site/image' -and $method -eq 'POST') {
                if (-not (Has-Permission $user 'customize')) { Send-Json $ctx 403 @{error='You do not have permission to customize the site.'}; continue }
                try{$payload=Read-Body $req;$kind=[string]$payload.kind;$url=Save-SiteImage $kind ([string]$payload.image);if($kind -eq 'logo'){$db.site.logoUrl=$url}else{$db.site.heroImageUrl=$url};Write-Database $db;Send-Json $ctx 200 @{url=$url;kind=$kind}}catch{Send-Json $ctx 400 @{error=$_.Exception.Message}};continue
            }
            Send-Json $ctx 404 @{error='Not found.'}; continue
        }
        if ($method -eq 'GET' -and $path -match '^/uploads/([a-f0-9]{32})\.(png|jpg|webp)$') { $photoId=$Matches[1];$photoExt=$Matches[2];$photoPath=Join-Path $uploadDir ($photoId+'.'+$photoExt); $photoDb=Read-Database; $photoViewer=Get-CurrentUser $req $photoDb;$photoOwner=$photoDb.users|Where-Object{$_.id -eq $photoId}|Select-Object -First 1; if (-not $photoViewer) { Send-Json $ctx 401 @{error='Sign in to view member photos.'} } elseif ($photoOwner -and ($photoOwner.id -eq $photoViewer.id -or $photoViewer.permissions.profiles -or $photoOwner.profileVisibility.photo) -and (Test-Path $photoPath)) { $mime=switch($photoExt){'png'{'image/png'}'jpg'{'image/jpeg'}default{'image/webp'}}; Send-Bytes $ctx 200 ([System.IO.File]::ReadAllBytes($photoPath)) $mime } else { Send-Text $ctx 404 'Not found' 'text/plain; charset=utf-8' }; continue }
        if ($method -eq 'GET' -and $path -match '^/site-assets/(logo|hero)\.(png|jpg|webp)$') { $kind=$Matches[1];$ext=$Matches[2];$brandDb=Read-Database;$site=$brandDb.site;$savedUrl=if($kind -eq 'logo'){$site.logoUrl}else{$site.heroImageUrl};$p=Join-Path $siteUploadDir ("$kind.$ext");if($savedUrl -eq $path -and (Test-Path $p)){$mime=switch($ext){'png'{'image/png'}'jpg'{'image/jpeg'}default{'image/webp'}};Send-Bytes $ctx 200 ([IO.File]::ReadAllBytes($p)) $mime}else{Send-Text $ctx 404 'Not found' 'text/plain; charset=utf-8'};continue }
        if ($method -eq 'GET' -and $path -match '^/home-post-assets/([a-f0-9]{32})\.(png|jpg|webp)$') { $postId=$Matches[1];$ext=$Matches[2];$postDb=Read-Database;$post=$postDb.homePosts|Where-Object{$_.id -eq $postId -and $_.imageUrl -eq $path}|Select-Object -First 1;$viewer=Get-CurrentUser $req $postDb;$p=Join-Path $homePostUploadDir ("$postId.$ext");if($post -and ($post.audience -eq 'public' -or $viewer) -and (Test-Path $p)){$mime=switch($ext){'png'{'image/png'}'jpg'{'image/jpeg'}default{'image/webp'}};Send-Bytes $ctx 200 ([IO.File]::ReadAllBytes($p)) $mime}else{Send-Text $ctx 404 'Not found' 'text/plain; charset=utf-8'};continue }
        if ($method -eq 'GET' -and $path -match '^/event-uploads/([a-zA-Z0-9-]{1,64})\.(png|jpg|webp)$') { $eventId=$Matches[1];$ext=$Matches[2];$eventDb=Read-Database;$event=$eventDb.events|Where-Object{$_.id -eq $eventId -and $_.imageUrl -eq $path}|Select-Object -First 1;$p=Join-Path $eventUploadDir ($eventId+'.'+$ext);if($event -and (Test-Path $p)){$mime=switch($ext){'png'{'image/png'}'jpg'{'image/jpeg'}default{'image/webp'}};Send-Bytes $ctx 200 ([IO.File]::ReadAllBytes($p)) $mime}else{Send-Text $ctx 404 'Not found' 'text/plain; charset=utf-8'};continue }
        if ($method -eq 'GET' -and $path -eq '/assets/school-logo.png') { Send-Bytes $ctx 200 ([System.IO.File]::ReadAllBytes((Join-Path $root 'assets\school-logo.png'))) 'image/png'; continue }
        if ($method -eq 'GET' -and ($path -eq '/community' -or $path -eq '/community.html')) { Send-Text $ctx 200 ([System.IO.File]::ReadAllText((Join-Path $root 'community.html'))) 'text/html; charset=utf-8'; continue }
        if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) { Send-Text $ctx 200 ([System.IO.File]::ReadAllText((Join-Path $root 'index.html'))) 'text/html; charset=utf-8'; continue }
        Send-Text $ctx 404 'Not found' 'text/plain; charset=utf-8'
    } catch {
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { $listener.Stop(); break }
        try { Send-Json $ctx 500 @{error='Something went wrong. Please try again.'} } catch {}
        Write-Warning $_.Exception.Message
    }
}
