function New-SecureToken {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Get-TokenHash([string]$token) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($token))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-PublicBaseUrl {
    $url = [string]$env:JH_PUBLIC_URL
    if ([string]::IsNullOrWhiteSpace($url)) { $url='http://localhost:5087' }
    return $url.TrimEnd('/')
}
function Send-AppEmail([string]$to,[string]$subject,[string]$body) {
    $hostName=[string]$env:JH_SMTP_HOST; $from=[string]$env:JH_SMTP_FROM
    if ([string]::IsNullOrWhiteSpace($hostName) -or [string]::IsNullOrWhiteSpace($from)) { return $false }
    $port=587; if ($env:JH_SMTP_PORT) { try { $port=[int]$env:JH_SMTP_PORT } catch { return $false } }
    $message=[System.Net.Mail.MailMessage]::new()
    $client=[System.Net.Mail.SmtpClient]::new($hostName,$port)
    try {
        $message.From=[System.Net.Mail.MailAddress]::new($from)
        $message.To.Add($to); $message.Subject=$subject; $message.Body=$body; $message.IsBodyHtml=$false; $message.SubjectEncoding=[Text.Encoding]::UTF8; $message.BodyEncoding=[Text.Encoding]::UTF8
        $client.EnableSsl=if ($env:JH_SMTP_SSL -eq 'false') { $false } else { $true }
        $client.UseDefaultCredentials=$false
        if ($env:JH_SMTP_USERNAME) { $client.Credentials=[System.Net.NetworkCredential]::new([string]$env:JH_SMTP_USERNAME,[string]$env:JH_SMTP_PASSWORD) }
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $client.Send($message)
        return $true
    } catch { Write-Warning "Email could not be sent: $($_.Exception.Message)"; return $false }
    finally { $message.Dispose(); $client.Dispose() }
}
