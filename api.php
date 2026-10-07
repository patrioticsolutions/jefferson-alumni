<?php
declare(strict_types=1);

/* PHP/MySQL entry point for Apache/cPanel. Runtime files and secrets live outside public_html. */
error_reporting(E_ALL);
ini_set('display_errors', '0');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: strict-origin-when-cross-origin');
header('Cache-Control: no-store');

$requestHost = strtolower(preg_replace('/:\\d+$/', '', (string)($_SERVER['HTTP_HOST'] ?? '')));
$hostConfig = $requestHost === 'staging.jeffersonalumni.com' ? dirname(__DIR__, 2) . '/jefferson-private/staging-config.php' : null;
$rootConfig = basename(__DIR__) === 'public_html' ? dirname(__DIR__) . '/jefferson-private/config.php' : null;
$webRoot = realpath((string)($_SERVER['DOCUMENT_ROOT'] ?? ''));
// Never let staging silently fall through to the production config.
$configCandidates = $requestHost === 'staging.jeffersonalumni.com'
    ? array_filter([$hostConfig])
    : array_filter([getenv('JH_CONFIG_PATH') ?: null, dirname(__DIR__, 2) . '/jefferson-private/config.php', $rootConfig]);
$configPath = null;
foreach ($configCandidates as $candidate) {
    $candidateReal = realpath($candidate);
    if ($candidateReal === false || !is_file($candidateReal) || !is_readable($candidateReal)) continue;
    if ($webRoot !== false && ($candidateReal === $webRoot || str_starts_with($candidateReal, rtrim($webRoot, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR))) continue;
    $configPath = $candidateReal; break;
}
if (!$configPath) { http_response_code(503); header('Content-Type: application/json; charset=utf-8'); echo json_encode(['error' => 'The site is not configured yet.']); exit; }
$config = require $configPath;
date_default_timezone_set((string)($config['timezone'] ?? 'America/Chicago'));
$storagePath = rtrim((string)($config['storage_path'] ?? ''), DIRECTORY_SEPARATOR);
if ($storagePath === '' || str_starts_with($storagePath, __DIR__)) { http_response_code(503); header('Content-Type: application/json; charset=utf-8'); echo json_encode(['error' => 'Private storage must be configured outside the website folder.']); exit; }
foreach (['uploads', 'event-uploads', 'home-post-uploads', 'site-assets'] as $dir) {
    $path = $storagePath . DIRECTORY_SEPARATOR . $dir;
    if (!is_dir($path) && !mkdir($path, 0750, true) && !is_dir($path)) { error_log('Jefferson Alumni: unable to create private storage directory'); http_response_code(500); exit; }
}
$storageReal = realpath($storagePath); $documentRoot = $webRoot;
if ($storageReal === false || ($documentRoot !== false && ($storageReal === $documentRoot || str_starts_with($storageReal, rtrim($documentRoot, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR)))) { http_response_code(503); header('Content-Type: application/json; charset=utf-8'); echo json_encode(['error'=>'Private storage must be outside the public website folder.']); exit; }

session_name('jh_session');
session_set_cookie_params(['lifetime' => 43200, 'path' => '/', 'secure' => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'), 'httponly' => true, 'samesite' => 'Strict']);
ini_set('session.use_strict_mode', '1');
session_start();

$pdo = null;
$transactionOpen = false;
$dirty = false;
$db = null;
$user = null;
$schoolOptions = ['Jefferson High School', 'Jefferson Middle School', 'East Elementary', 'West Elementary', 'Sullivan Elementary', 'St. John the Baptist Catholic School', 'St. John Lutheran School'];

function db(): PDO {
    global $pdo, $config;
    if ($pdo instanceof PDO) return $pdo;
    $c = $config['db'] ?? [];
    $dsn = 'mysql:host=' . ($c['host'] ?? 'localhost') . ';dbname=' . ($c['name'] ?? '') . ';charset=' . ($c['charset'] ?? 'utf8mb4');
    $pdo = new PDO($dsn, (string)($c['user'] ?? ''), (string)($c['password'] ?? ''), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => false, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
    return $pdo;
}
function initial_state(): array {
    return ['users'=>[], 'posts'=>[['id'=>'welcome','author'=>'Jefferson Alumni Team','authorId'=>null,'created'=>date(DATE_ATOM),'body'=>'Welcome to the Jefferson alumni community. Share a memory, reconnect with classmates, and keep an eye on upcoming reunions.']], 'events'=>[], 'messages'=>[], 'homePosts'=>[], 'reports'=>[], 'auditLog'=>[], 'discussionGroups'=>[], 'discussions'=>[], 'site'=>['title'=>'Jefferson Alumni','tagline'=>'A place for Jefferson alumni to find one another and keep our community close.','primaryColor'=>'#5a1024','accentColor'=>'#f0b23e','fontFamily'=>'system','logoUrl'=>'/assets/school-logo.png','heroImageUrl'=>null]];
}
function load_state(bool $forWrite = false): array {
    global $transactionOpen;
    $pdo = db();
    if ($forWrite) { $pdo->beginTransaction(); $transactionOpen = true; }
    $statement = $pdo->query('SELECT payload FROM jh_app_state WHERE id=1' . ($forWrite ? ' FOR UPDATE' : ''));
    $payload = $statement->fetchColumn();
    if ($payload === false) {
        $state = initial_state();
        if ($forWrite) { $insert = $pdo->prepare('INSERT INTO jh_app_state (id,payload) VALUES (1,?)'); $insert->execute([json_encode($state, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR)]); }
        return $state;
    }
    $state = json_decode((string)$payload, true, 512, JSON_THROW_ON_ERROR);
    if (!is_array($state)) throw new RuntimeException('Invalid application state.');
    foreach (['users','posts','events','messages','homePosts','reports','auditLog','discussionGroups','discussions'] as $key) if (!isset($state[$key]) || !is_array($state[$key])) $state[$key] = [];
    if (!isset($state['site']) || !is_array($state['site'])) $state['site'] = initial_state()['site'];
    return $state;
}
function save_state(): void {
    global $db, $dirty, $transactionOpen;
    if (!$dirty) return;
    $stmt = db()->prepare('UPDATE jh_app_state SET payload=? WHERE id=1');
    $stmt->execute([json_encode($db, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR)]);
    $dirty = false;
}
function respond(int $status, mixed $payload): never {
    global $transactionOpen;
    if ($transactionOpen && db()->inTransaction()) db()->commit();
    $transactionOpen = false;
    http_response_code($status); header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_INVALID_UTF8_SUBSTITUTE); exit;
}
function fail_request(Throwable $e): never {
    global $transactionOpen;
    try { global $pdo; if ($transactionOpen && $pdo instanceof PDO && $pdo->inTransaction()) $pdo->rollBack(); } catch (Throwable $rollbackError) { error_log('Jefferson Alumni rollback error: '.$rollbackError->getMessage()); }
    $transactionOpen = false; error_log('Jefferson Alumni request error: ' . $e->getMessage());
    respond(500, ['error' => 'Something went wrong. Please try again.']);
}
function input(): array {
    $raw = file_get_contents('php://input');
    if ($raw === false || $raw === '') return [];
    $value = json_decode($raw, true);
    if (!is_array($value)) respond(400, ['error'=>'Invalid request body.']);
    return $value;
}
function text_value(mixed $value, int $max = 10000): string { $text = trim((string)($value ?? '')); return mb_substr($text, 0, $max, 'UTF-8'); }
function id_value(): string { return bin2hex(random_bytes(16)); }
function valid_date(string $value): bool { $date=DateTime::createFromFormat('!Y-m-d',$value);$errors=DateTime::getLastErrors();return $date!==false&&$date->format('Y-m-d')===$value&&($errors===false||($errors['warning_count']===0&&$errors['error_count']===0)); }
function token_value(): string { return rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '='); }
function token_hash(string $token): string { return hash('sha256', $token); }
function password_ok(string $password): bool {
    if (strlen($password) < 15 || strlen($password) > 200 || preg_match('/(.)\1{7,}/u', $password)) return false;
    $common = ['passwordpassword','123456789012345','letmeinletmein','qwertyuiopasdfg','welcome12345678'];
    return !in_array(mb_strtolower($password, 'UTF-8'), $common, true);
}
function password_valid(array $record, string $password): bool {
    if (($record['passwordScheme'] ?? '') === 'php' && isset($record['passwordHash'])) return password_verify($password, (string)$record['passwordHash']);
    if (empty($record['salt']) || empty($record['hash'])) return false;
    $salt = base64_decode((string)$record['salt'], true); $expected = base64_decode((string)$record['hash'], true);
    if ($salt === false || $expected === false) return false;
    return hash_equals($expected, hash_pbkdf2('sha256', $password, $salt, 210000, 32, true));
}
function new_user_password(array &$record, string $password): void { $record['passwordScheme']='php'; $record['passwordHash']=password_hash($password, PASSWORD_DEFAULT); unset($record['salt'], $record['hash']); }
function permission(array $member, string $key): bool { return !empty($member['permissions'][$key]); }
function has_admin_access(array $member): bool { foreach (['profiles','events','posts','homepagePosts','approveUsers','moderate','audit','bulkEmail','customize','permissions'] as $key) if (permission($member,$key)) return true; return false; }
function active_member(array $member): bool { return ($member['approved'] ?? true) !== false && ($member['emailVerified'] ?? true) !== false && empty($member['suspended']); }
function find_user(string $id): ?array { global $db; foreach ($db['users'] as $member) if (($member['id'] ?? '') === $id) return $member; return null; }
function user_index(string $id): ?int { global $db; foreach ($db['users'] as $index=>$member) if (($member['id'] ?? '') === $id) return $index; return null; }
function current_user(): ?array { global $db, $user; $uid=(string)($_SESSION['uid'] ?? ''); if ($uid==='') return null; $member=find_user($uid); if (!$member || !empty($member['suspended'])) { unset($_SESSION['uid']); return null; } $user=$member; return $member; }
function public_user(array $member, string $viewerId, bool $asAdmin=false): array {
    $own=($member['id'] ?? '')===$viewerId; $vis=$member['profileVisibility'] ?? [];
    $out=['id'=>$member['id'],'name'=>(($own||$asAdmin||!empty($vis['name']))?$member['name']:'Private member'),'email'=>(($asAdmin||($own||!empty($vis['email'])) && (($member['emailVisibility']??'members')!=='private'||$own))?($member['email']??null):null)];
    foreach (['classYear','role','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','maritalStatus','hasChildren','schoolsAttended','photoUrl'] as $key) { $visibilityKey=$key==='photoUrl'?'photo':$key; $out[$key]=($own||$asAdmin||!empty($vis[$visibilityKey]))?($member[$key]??($key==='schoolsAttended'?[]:null)):null; }
    $out['emailVisibility']=$member['emailVisibility']??'members'; $out['profileVisibility']=($own||$asAdmin)?$vis:null; if($asAdmin)$out['suspended']=!empty($member['suspended']);
    return $out;
}
function add_audit(string $actorId,string $action,string $kind,string $objectId,string $summary): void {
    global $db;
    $actor=find_user($actorId);
    $db['auditLog'][]=['id'=>id_value(),'actorId'=>$actorId,'actorName'=>$actor['name']??'Administrator','action'=>$action,'objectType'=>$kind,'objectId'=>$objectId,'summary'=>$summary,'created'=>date(DATE_ATOM)];
    usort($db['auditLog'],fn($a,$b)=>strcmp($b['created']??'',$a['created']??'')); $db['auditLog']=array_slice($db['auditLog'],0,1000); $GLOBALS['dirty']=true;
}
function mail_send(string $to,string $subject,string $body): bool {
    global $config;
    $smtp=$config['smtp']??[]; $host=(string)($smtp['host']??''); $from=(string)($smtp['from']??'');
    if ($host===''||$from===''||!filter_var($to,FILTER_VALIDATE_EMAIL)||!filter_var($from,FILTER_VALIDATE_EMAIL)) return false;
    $port=(int)($smtp['port']??587); $encryption=(string)($smtp['encryption']??'tls'); $remote=($encryption==='ssl'?'ssl://':'tcp://').$host.':'.$port;
    $socket=@stream_socket_client($remote,$errno,$errstr,15,STREAM_CLIENT_CONNECT,stream_context_create(['ssl'=>['verify_peer'=>true,'verify_peer_name'=>true,'SNI_enabled'=>true]]));
    if(!$socket){error_log('Jefferson Alumni SMTP connection failed: '.$errstr);return false;} stream_set_timeout($socket,15);
    $read=function()use($socket){$data='';do{$line=fgets($socket,515);if($line===false)throw new RuntimeException('SMTP server disconnected.');$data.=$line;}while(strlen($line)>3&&$line[3]==='-');return [(int)substr($line,0,3),$data];};
    $command=function(string $line,array $ok)use($socket,$read){fwrite($socket,$line."\r\n");[$code,$reply]=$read();if(!in_array($code,$ok,true))throw new RuntimeException('SMTP command failed: '.trim($reply));return $reply;};
    try {
        [$code]= $read(); if($code!==220)throw new RuntimeException('SMTP greeting failed.');
        $command('EHLO jefferson-alumni', [250]);
        if($encryption==='tls'){$command('STARTTLS',[220]);if(!stream_socket_enable_crypto($socket,true,STREAM_CRYPTO_METHOD_TLS_CLIENT))throw new RuntimeException('SMTP TLS negotiation failed.');$command('EHLO jefferson-alumni',[250]);}
        $username=(string)($smtp['username']??'');if($username!==''){$command('AUTH LOGIN',[334]);$command(base64_encode($username),[334]);$command(base64_encode((string)($smtp['password']??'')),[235]);}
        $command('MAIL FROM:<'.$from.'>',[250]);$command('RCPT TO:<'.$to.'>',[250,251]);$command('DATA',[354]);
        $name=(string)($smtp['from_name']??'Jefferson Alumni');$encodedName='=?UTF-8?B?'.base64_encode($name).'?=';
        $headers='From: '.$encodedName.' <'.$from.">\r\n".'To: <'.$to.">\r\n".'Subject: =?UTF-8?B?'.base64_encode($subject)."?=\r\n".'MIME-Version: 1.0' ."\r\n".'Content-Type: text/plain; charset=UTF-8' ."\r\n".'Content-Transfer-Encoding: 8bit' ."\r\n\r\n";
        $message=preg_replace('/(?m)^\./','..',$headers.str_replace(["\r\n","\r"],"\n",$body));$message=str_replace("\n","\r\n",$message);
        fwrite($socket,$message."\r\n.\r\n");[$code]=$read();if($code!==250)throw new RuntimeException('SMTP message was rejected.');$command('QUIT',[221]);fclose($socket);return true;
    } catch(Throwable $e){error_log('Jefferson Alumni SMTP delivery failed: '.$e->getMessage());fclose($socket);return false;}
}
function image_bytes(string $data): array {
    if(!preg_match('#^data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$#',$data,$m))throw new InvalidArgumentException('Choose a PNG, JPEG, or WebP image.');
    $bytes=base64_decode($m[2],true);if($bytes===false||strlen($bytes)<16||strlen($bytes)>2097152)throw new InvalidArgumentException('Images must be under 2 MB.');
    $ext=$m[1]==='jpeg'?'jpg':$m[1];$mime=(new finfo(FILEINFO_MIME_TYPE))->buffer($bytes);$expected=['png'=>'image/png','jpg'=>'image/jpeg','webp'=>'image/webp'][$ext];if($mime!==$expected)throw new InvalidArgumentException('The file contents do not match the selected image type.');
    return [$bytes,$ext];
}
function save_image(string $folder,string $id,string $data): string { global $storagePath; [$bytes,$ext]=image_bytes($data);$dir=$storagePath.'/'.$folder;if(!is_dir($dir)&&!mkdir($dir,0750,true)&&!is_dir($dir))throw new RuntimeException('Image storage is unavailable.');foreach(['png','jpg','webp'] as $old)if(is_file($dir.'/'.$id.'.'.$old))unlink($dir.'/'.$id.'.'.$old);if(file_put_contents($dir.'/'.$id.'.'.$ext,$bytes,LOCK_EX)===false)throw new RuntimeException('Image could not be saved.');return '/'.($folder==='uploads'?'uploads':($folder==='event-uploads'?'event-uploads':($folder==='site-assets'?'site-assets':'home-post-assets'))).'/'.$id.'.'.$ext; }
function mark_dirty(): void { $GLOBALS['dirty']=true; }
function find_event_index(string $id): ?int { global $db; foreach ($db['events'] as $i=>$event) if ((string)($event['id']??'')===$id) return $i; return null; }
function find_discussion_index(string $id): ?int { global $db; foreach ($db['discussions'] as $i=>$discussion) if ((string)($discussion['id']??'')===$id) return $i; return null; }
function discussion_group_name(array $state,string $id): string { foreach ($state['discussionGroups'] as $group) if (($group['id']??'')===$id) return (string)($group['name']??'Saved group'); return 'Saved group'; }
function discussion_access(array $member,array $discussion,array $state): bool {
    if (($discussion['authorId']??'')===($member['id']??'') || permission($member,'profiles')) return true;
    $id=(string)($member['id']??'');
    if (($discussion['audience']??'')==='class') return (string)($member['classYear']??'')===(string)($discussion['classYear']??'');
    if (($discussion['audience']??'')==='selected') return in_array($id,$discussion['memberIds']??[],true);
    if (($discussion['audience']??'')==='group') foreach ($state['discussionGroups'] as $g) if (($g['id']??'')===($discussion['groupId']??'')) return in_array($id,$g['memberIds']??[],true);
    return true;
}

try {
    $method=$_SERVER['REQUEST_METHOD']??'GET'; $path=parse_url($_SERVER['REQUEST_URI']??'/',PHP_URL_PATH)?:'/';
    if($method==='OPTIONS'){http_response_code(204);exit;}
    $db=load_state($method!=='GET'&&$method!=='HEAD');
    if($method==='GET'&&$path==='/api/site')respond(200,['site'=>$db['site']]);
    if($method==='GET'&&$path==='/api/public/events'){
        $today=date('Y-m-d');$events=array_values(array_filter($db['events'],fn($e)=>($e['date']??'')>=$today));usort($events,fn($a,$b)=>strcmp($a['date']??'',$b['date']??''));
        $counts=['alumni'=>0,'teachers'=>0,'staff'=>0];$classCounts=[];
        foreach($db['users'] as $m){if(!active_member($m)||($m['emailVerified']??true)===false)continue;$role=$m['role']??'';$key=['Alumni'=>'alumni','Teacher'=>'teachers','Staff'=>'staff'][$role]??null;if($key)$counts[$key]++;if($role==='Alumni'&&!empty($m['classYear']))$classCounts[(string)$m['classYear']]=($classCounts[(string)$m['classYear']]??0)+1;}
        ksort($classCounts,SORT_NUMERIC);$publicPosts=array_values(array_filter($db['homePosts'],fn($p)=>($p['audience']??'members')==='public'));
        respond(200,['events'=>array_map(fn($e)=>public_event($e,$db,null),$events),'counts'=>$counts,'classCounts'=>(object)$classCounts,'site'=>$db['site'],'homePosts'=>$publicPosts]);
    }
    if($method==='GET'&&$path==='/calendar.ics'){ $events=$db['events'];$ics="BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Jefferson Alumni//EN\r\n";foreach($events as $e){$start=str_replace('-','',(string)($e['date']??''));if(!preg_match('/^\d{8}$/',$start))continue;$ics.="BEGIN:VEVENT\r\nUID:".($e['id']??id_value())."@jeffersonalumni\r\nDTSTAMP:".gmdate('Ymd\THis\Z')."\r\nDTSTART;VALUE=DATE:$start\r\nSUMMARY:".str_replace(["\\",",",";","\n"],["\\\\","\\,","\\;","\\n"],(string)($e['title']??'Event'))."\r\nEND:VEVENT\r\n";}$ics.="END:VCALENDAR\r\n";http_response_code(200);header('Content-Type: text/calendar; charset=utf-8');header('Content-Disposition: attachment; filename="jefferson-calendar.ics"');echo $ics;exit; }

    /* The API dispatcher continues below. Each state-changing handler saves in a transaction. */
    $input = ($method==='POST'||$method==='PATCH'||$method==='PUT') ? input() : [];
    $emailConfigured=!empty($config['smtp']['host'])&&!empty($config['smtp']['from']);
    if($method==='POST'&&$path==='/api/logout'){$_SESSION=[];session_destroy();respond(200,['ok'=>true]);}
    if($method==='POST'&&$path==='/api/register'){
        $name=text_value($input['name']??'',90);$email=strtolower(text_value($input['email']??'',254));$password=(string)($input['password']??'');$role=(string)($input['role']??'Alumni');$year=text_value($input['classYear']??'',4);
        if(mb_strlen($name)<2||!filter_var($email,FILTER_VALIDATE_EMAIL)||!password_ok($password)||!in_array($role,['Alumni','Teacher','Staff'],true))respond(400,['error'=>'Enter your name, school connection, valid email, and a strong passphrase of at least 15 characters.']);
        foreach($db['users'] as $m)if(strtolower((string)($m['email']??''))===$email)respond(409,['error'=>'An account with that email already exists.']);
        $bootstrap=count($db['users'])===0;if($bootstrap){$bootstrapEmail=strtolower((string)($config['bootstrap_admin_email']??''));if(!filter_var($bootstrapEmail,FILTER_VALIDATE_EMAIL))respond(503,['error'=>'The site administrator must configure the initial administrator email before registration can begin.']);if($email!==$bootstrapEmail)respond(403,['error'=>'The first account is reserved for the configured site administrator.']);}$token=token_value();$u=['id'=>id_value(),'name'=>$name,'email'=>$email,'role'=>$role,'classYear'=>$year,'city'=>'','bio'=>'','phone'=>'','occupation'=>'','employer'=>'','interests'=>'','website'=>'','linkedin'=>'','facebook'=>'','instagram'=>'','tiktok'=>'','maritalStatus'=>'','hasChildren'=>'','schoolsAttended'=>[],'profileVisibility'=>array_fill_keys(['name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','photo'],true)+['maritalStatus'=>false,'hasChildren'=>false,'schoolsAttended'=>false],'emailVisibility'=>'members','photoUrl'=>null,'emailVerified'=>$bootstrap,'approved'=>$bootstrap,'approvalStatus'=>$bootstrap?'approved':'pending','permissions'=>array_fill_keys(['profiles','events','posts','homepagePosts','approveUsers','moderate','audit','bulkEmail','customize','permissions'],$bootstrap),'created'=>date(DATE_ATOM),'suspended'=>false];new_user_password($u,$password);if(!$bootstrap){$u['verificationHash']=token_hash($token);$u['verificationExpires']=date(DATE_ATOM,time()+86400);}$db['users'][]=$u;mark_dirty();save_state();if(!$bootstrap&&$emailConfigured){$url=rtrim((string)$config['public_url'],'/').'/community?verify='.rawurlencode($token);$sent=mail_send($email,'Verify your Jefferson Alumni account',"Hello $name,\n\nVerify your email within 24 hours:\n$url");}else{$sent=false;}respond(201,['verificationRequired'=>!$bootstrap,'verificationSent'=>$sent,'approvalRequired'=>!$bootstrap,'bootstrapAdmin'=>$bootstrap]);
    }
    if($method==='POST'&&$path==='/api/login'){
        $email=strtolower(text_value($input['email']??'',254));$password=(string)($input['password']??'');$index=null;foreach($db['users'] as $i=>$m)if(strtolower((string)($m['email']??''))===$email){$index=$i;break;}
        if($index===null||!password_valid($db['users'][$index],$password))respond(401,['error'=>'Email or password is incorrect.']);$m=$db['users'][$index];if(!empty($m['suspended']))respond(403,['error'=>'This account is suspended. Contact a Jefferson Alumni administrator for help.']);if(($m['approved']??true)===false)respond(403,['error'=>'Your account is awaiting approval by an administrator.','approvalPending'=>true]);if(($m['emailVerified']??true)===false)respond(403,['error'=>'Please verify your email before signing in.','verificationRequired'=>true]);
        if(($m['passwordScheme']??'')!=='php'){new_user_password($db['users'][$index],$password);mark_dirty();save_state();}
        session_regenerate_id(true);$_SESSION['uid']=$m['id'];respond(200,['user'=>public_user($m,$m['id'])]);
    }
    if($method==='POST'&&$path==='/api/verify'){
        $hash=token_hash((string)($input['token']??''));foreach($db['users'] as &$m){if(($m['verificationHash']??'')===$hash&&strtotime((string)($m['verificationExpires']??''))>=time()){$m['emailVerified']=true;unset($m['verificationHash'],$m['verificationExpires']);mark_dirty();save_state();respond(200,['ok'=>true]);}}unset($m);respond(400,['error'=>'That verification link is invalid or expired.']);
    }
    if($method==='POST'&&$path==='/api/verify/resend'){
        $email=strtolower(text_value($input['email']??'',254));$sent=false;foreach($db['users'] as &$m){if(strtolower((string)($m['email']??''))===$email&&($m['emailVerified']??true)===false){$token=token_value();$m['verificationHash']=token_hash($token);$m['verificationExpires']=date(DATE_ATOM,time()+86400);mark_dirty();save_state();$sent=$emailConfigured&&mail_send($email,'Verify your Jefferson Alumni account',"Open this link within 24 hours:\n".rtrim((string)$config['public_url'],'/').'/community?verify='.rawurlencode($token));break;}}unset($m);respond(200,['ok'=>true,'emailConfigured'=>$emailConfigured,'verificationSent'=>$sent,'message'=>'If that address has an unverified account, a new link has been sent.']);
    }
    if($method==='POST'&&$path==='/api/password/forgot'){
        $email=strtolower(text_value($input['email']??'',254));foreach($db['users'] as &$m){if(strtolower((string)($m['email']??''))===$email){$token=token_value();$m['resetHash']=token_hash($token);$m['resetExpires']=date(DATE_ATOM,time()+3600);mark_dirty();save_state();if($emailConfigured)mail_send($email,'Reset your Jefferson Alumni password',"Use this link within one hour:\n".rtrim((string)$config['public_url'],'/').'/community?reset='.rawurlencode($token));break;}}unset($m);respond(200,['ok'=>true,'emailConfigured'=>$emailConfigured,'message'=>'If an account uses that address, a password reset link has been sent.']);
    }
    if($method==='POST'&&$path==='/api/password/reset'){
        $hash=token_hash((string)($input['token']??''));$password=(string)($input['password']??'');if(!password_ok($password))respond(400,['error'=>'Use a passphrase of at least 15 characters that is not common or repetitive.']);foreach($db['users'] as &$m){if(($m['resetHash']??'')===$hash&&strtotime((string)($m['resetExpires']??''))>=time()){new_user_password($m,$password);$m['emailVerified']=true;unset($m['resetHash'],$m['resetExpires'],$m['verificationHash'],$m['verificationExpires']);mark_dirty();save_state();respond(200,['ok'=>true]);}}unset($m);respond(400,['error'=>'That password link is invalid or expired.']);
    }
    $user=current_user();
    if($path==='/api/site'&&$method==='GET')respond(200,['site'=>$db['site']]);
    if($path==='/api/me'&&$method==='GET'){
        if(!$user)respond(401,['error'=>'Please sign in to continue.']);$members=[];foreach($db['users'] as $m)if(active_member($m))$members[]=public_user($m,$user['id']);$posts=[];foreach($db['posts'] as $p){$author=find_user((string)($p['authorId']??''));$posts[]=['id'=>$p['id'],'author'=>$author['name']??($p['author']??'Former member'),'authorId'=>$p['authorId']??null,'authorPhoto'=>$author['photoUrl']??($p['authorPhoto']??null),'created'=>$p['created']??'','body'=>$p['body']??''];}
        $events=array_map(fn($e)=>public_event($e,$db,$user['id']),$db['events']);respond(200,['user'=>public_user($user,$user['id']),'permissions'=>$user['permissions']??[],'site'=>$db['site'],'homePosts'=>$db['homePosts'],'members'=>$members,'posts'=>$posts,'events'=>$events]);
    }
    if(!$user)respond(401,['error'=>'Please sign in to continue.']);

    if($method==='GET'&&$path==='/api/discussion-groups'){
        $groups=[];foreach($db['discussionGroups'] as $g){if(($g['ownerId']??'')!==$user['id']&&!permission($user,'profiles')&&!in_array($user['id'],$g['memberIds']??[],true))continue;$members=[];foreach($g['memberIds']??[] as $mid){$m=find_user((string)$mid);if($m)$members[]=['id'=>$m['id'],'name'=>$m['name']];}$groups[]=['id'=>$g['id'],'name'=>$g['name'],'ownerId'=>$g['ownerId'],'memberIds'=>$g['memberIds']??[],'members'=>$members,'created'=>$g['created']??''];}respond(200,['groups'=>$groups]);
    }
    if($method==='POST'&&$path==='/api/discussion-groups'){
        $name=text_value($input['name']??'',80);$requested=array_values(array_unique(array_map('strval',$input['memberIds']??[])));if(mb_strlen($name)<2)respond(400,['error'=>'Enter a group name and choose no more than 100 approved members.']);$valid=[];foreach($db['users'] as $m)if(active_member($m)&&in_array((string)$m['id'],$requested,true))$valid[]=$m['id'];if(!in_array($user['id'],$valid,true))$valid[]=$user['id'];if(count($requested)>100||count($valid)>101)respond(400,['error'=>'Enter a group name and choose no more than 100 approved members.']);$group=['id'=>id_value(),'name'=>$name,'ownerId'=>$user['id'],'memberIds'=>$valid,'created'=>date(DATE_ATOM)];$db['discussionGroups'][]=$group;mark_dirty();save_state();respond(201,['group'=>$group]);
    }
    if(preg_match('#^/api/discussion-groups/([a-f0-9]{32})$#',$path,$match)&&$method==='PATCH'){
        $idx=null;foreach($db['discussionGroups'] as $i=>$g)if(($g['id']??'')===$match[1]){$idx=$i;break;}if($idx===null)respond(404,['error'=>'Discussion group not found.']);$g=&$db['discussionGroups'][$idx];if(($g['ownerId']??'')!==$user['id']&&!permission($user,'profiles'))respond(403,['error'=>'Only the group creator or a profile administrator can manage this group.']);$name=text_value($input['name']??'',80);$requested=array_values(array_unique(array_map('strval',$input['memberIds']??[])));if(mb_strlen($name)<2||count($requested)>100)respond(400,['error'=>'Check the group name and select no more than 100 other approved members.']);$ids=[];foreach($db['users'] as $m)if(active_member($m)&&in_array((string)$m['id'],$requested,true))$ids[]=$m['id'];if(!in_array($g['ownerId'],$ids,true))$ids[]=$g['ownerId'];$g['name']=$name;$g['memberIds']=$ids;mark_dirty();save_state();respond(200,['ok'=>true]);
    }
    if($method==='GET'&&$path==='/api/discussions'){
        $items=[];$list=$db['discussions'];usort($list,fn($a,$b)=>strcmp($b['updated']??'',$a['updated']??''));foreach($list as $d){if(!discussion_access($user,$d,$db))continue;$replies=[];foreach($d['replies']??[] as $r){$author=find_user((string)($r['authorId']??''));$replies[]=['id'=>$r['id'],'author'=>$author['name']??'Former member','authorId'=>$r['authorId']??null,'body'=>$r['body'],'created'=>$r['created']];}$label=match($d['audience']??'site'){'class'=>'Class of '.($d['classYear']??''),'group'=>discussion_group_name($db,(string)($d['groupId']??'')),'selected'=>'Selected members',default=>'All members'};$items[]=['id'=>$d['id'],'title'=>$d['title'],'body'=>$d['body'],'author'=>$d['author']??'Former member','authorId'=>$d['authorId']??null,'created'=>$d['created'],'updated'=>$d['updated']??$d['created'],'audience'=>$d['audience'],'audienceLabel'=>$label,'classYear'=>$d['classYear']??null,'groupId'=>$d['groupId']??null,'memberIds'=>(($d['authorId']??'')===$user['id']||permission($user,'profiles'))?($d['memberIds']??[]):[],'canManage'=>(($d['authorId']??'')===$user['id']||permission($user,'profiles')),'replies'=>$replies];}respond(200,['discussions'=>$items]);
    }
    if($method==='POST'&&$path==='/api/discussions'){
        $title=text_value($input['title']??'',120);$body=text_value($input['body']??'',3000);$audience=(string)($input['audience']??'');$year=text_value($input['classYear']??'',4);$groupId=(string)($input['groupId']??'');$ids=[];$valid=true;
        if($audience==='site'){foreach($db['users'] as $m)if(active_member($m))$ids[]=$m['id'];}
        elseif($audience==='class'){if($year==='')$valid=false;else foreach($db['users'] as $m)if(active_member($m)&&($m['classYear']??'')===$year)$ids[]=$m['id'];}
        elseif($audience==='group'){$g=null;foreach($db['discussionGroups'] as $x)if($x['id']===$groupId){$g=$x;break;}if(!$g||(($g['ownerId']??'')!==$user['id']&&!permission($user,'profiles')&&!in_array($user['id'],$g['memberIds']??[],true)))$valid=false;else $ids=$g['memberIds']??[];}
        elseif($audience==='selected'){$requested=array_values(array_unique(array_map('strval',$input['memberIds']??[])));foreach($db['users'] as $m)if(active_member($m)&&in_array((string)$m['id'],$requested,true))$ids[]=$m['id'];if(count($requested)>100||count($ids)<1)$valid=false;}else $valid=false;
        if(!in_array($user['id'],$ids,true))$ids[]=$user['id'];if(mb_strlen($title)<4||$body===''||!$valid)respond(400,['error'=>'Check the topic, message, audience, and audience selections.']);$d=['id'=>id_value(),'title'=>$title,'body'=>$body,'authorId'=>$user['id'],'author'=>$user['name'],'audience'=>$audience,'classYear'=>$audience==='class'?$year:null,'groupId'=>$audience==='group'?$groupId:null,'memberIds'=>$ids,'replies'=>[],'created'=>date(DATE_ATOM),'updated'=>date(DATE_ATOM)];$db['discussions'][]=$d;mark_dirty();save_state();respond(201,['ok'=>true]);
    }
    if(preg_match('#^/api/discussions/([a-f0-9]{32})/replies$#',$path,$match)&&$method==='POST'){
        $i=find_discussion_index($match[1]);if($i===null)respond(404,['error'=>'Discussion not found.']);$d=&$db['discussions'][$i];if(!discussion_access($user,$d,$db))respond(403,['error'=>'This discussion is only available to its selected audience.']);$body=text_value($input['body']??'',2000);if($body==='')respond(400,['error'=>'Replies must be between 1 and 2,000 characters.']);$d['replies'][]=['id'=>id_value(),'authorId'=>$user['id'],'body'=>$body,'created'=>date(DATE_ATOM)];$d['updated']=date(DATE_ATOM);mark_dirty();save_state();respond(201,['ok'=>true]);
    }
    if(preg_match('#^/api/discussions/([a-f0-9]{32})/members$#',$path,$match)&&$method==='PATCH'){
        $i=find_discussion_index($match[1]);if($i===null)respond(404,['error'=>'Discussion not found.']);$d=&$db['discussions'][$i];if(($d['authorId']??'')!==$user['id']&&!permission($user,'profiles'))respond(403,['error'=>'Only the topic creator or an administrator can manage its audience.']);if(($d['audience']??'')!=='selected')respond(400,['error'=>'Only selected-member discussions have an editable participant list.']);$requested=array_values(array_unique(array_map('strval',$input['memberIds']??[])));if(count($requested)>100)respond(400,['error'=>'Select no more than 100 participants.']);$ids=[];foreach($db['users'] as $m)if(active_member($m)&&in_array((string)$m['id'],$requested,true))$ids[]=$m['id'];if(!in_array($d['authorId'],$ids,true))$ids[]=$d['authorId'];$d['memberIds']=$ids;$d['updated']=date(DATE_ATOM);mark_dirty();save_state();respond(200,['ok'=>true]);
    }
    if($method==='POST'&&$path==='/api/profile/photo'){
        $url=save_image('uploads',$user['id'],(string)($input['image']??''));$i=user_index($user['id']);$db['users'][$i]['photoUrl']=$url;mark_dirty();save_state();respond(200,['photoUrl'=>$url]);
    }
    if($method==='DELETE'&&$path==='/api/profile/photo'){
        foreach(['png','jpg','webp'] as $ext){$file=$storagePath.'/uploads/'.$user['id'].'.'.$ext;if(is_file($file))unlink($file);}$i=user_index($user['id']);$db['users'][$i]['photoUrl']=null;mark_dirty();save_state();respond(200,['ok'=>true]);
    }
    if($method==='PATCH'&&$path==='/api/profile'){
        $i=user_index($user['id']);$old=$db['users'][$i];$fields=['name'=>90,'classYear'=>4,'city'=>100,'bio'=>500,'phone'=>40,'occupation'=>100,'employer'=>100,'interests'=>300,'website'=>200,'linkedin'=>250,'facebook'=>250,'instagram'=>250,'tiktok'=>250];$updated=$old;foreach($fields as $key=>$max)$updated[$key]=text_value($input[$key]??$old[$key]??'', $max);$updated['maritalStatus']=text_value($input['maritalStatus']??'',40);$updated['hasChildren']=text_value($input['hasChildren']??'',40);$schools=array_values(array_unique(array_intersect(array_map('strval',$input['schoolsAttended']??[]),$schoolOptions)));$updated['schoolsAttended']=$schools;$updated['profileVisibility']=[];foreach(['name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','maritalStatus','hasChildren','schoolsAttended','photo'] as $key)$updated['profileVisibility'][$key]=!empty($input['profileVisibility'][$key]);$updated['emailVisibility']=$updated['profileVisibility']['email']?'members':'private';
        if(mb_strlen($updated['name'])<2)respond(400,['error'=>'Please enter a name.']);foreach(['website','linkedin','facebook','instagram','tiktok'] as $key)if($updated[$key]!==''&&!preg_match('#^https?://#i',$updated[$key]))respond(400,['error'=>'Website and social links must begin with http:// or https://.']);if(!in_array($updated['maritalStatus'],['','Single','Married','Separated','Divorced','Widowed','Prefer not to say'],true)||!in_array($updated['hasChildren'],['','Yes','No','Prefer not to say'],true))respond(400,['error'=>'Check your family details and school selections.']);$db['users'][$i]=$updated;mark_dirty();save_state();respond(200,['user'=>public_user($updated,$updated['id'])]);
    }
    if($method==='POST'&&$path==='/api/posts'){$body=text_value($input['body']??'',1500);if($body==='')respond(400,['error'=>'Posts must be between 1 and 1,500 characters.']);$db['posts'][]=['id'=>id_value(),'author'=>$user['name'],'authorId'=>$user['id'],'authorPhoto'=>$user['photoUrl']??null,'created'=>date(DATE_ATOM),'body'=>$body];mark_dirty();save_state();respond(201,['ok'=>true]);}
    if($method==='POST'&&$path==='/api/reports'){$postId=(string)($input['postId']??'');$reason=text_value($input['reason']??'',500);$found=false;foreach($db['homePosts'] as $p)if(($p['id']??'')===$postId&&($p['audience']??'')==='public')$found=true;if(!$found||mb_strlen($reason)<5)respond(400,['error'=>'Choose a public announcement and provide a reason from 5 to 500 characters.']);foreach($db['reports'] as $r)if(($r['reporterId']??'')===$user['id']&&($r['targetId']??'')===$postId&&($r['status']??'')==='open')respond(409,['error'=>'You have already reported this announcement.']);$db['reports'][]=['id'=>id_value(),'targetType'=>'homePost','targetId'=>$postId,'reporterId'=>$user['id'],'reason'=>$reason,'status'=>'open','created'=>date(DATE_ATOM)];mark_dirty();save_state();respond(201,['ok'=>true]);}
    if($method==='PATCH'&&$path==='/api/profile'){}
    if($method==='PATCH'&&$path==='/api/site'){}

    if($method==='POST'&&$path==='/api/events'){
        $title=text_value($input['title']??'',100);$date=text_value($input['date']??'',10);$time=text_value($input['time']??'',40);$endTime=text_value($input['endTime']??'',40);$location=text_value($input['location']??'',120);$details=text_value($input['details']??'',1000);$category=(string)($input['category']??'Other');$registration=text_value($input['registrationUrl']??'',300);$capacity=(int)($input['capacity']??0);if(mb_strlen($title)<3||!valid_date($date)||$date<date('Y-m-d')||mb_strlen($location)<2||$capacity<0||$capacity>50000||!in_array($category,['Reunion','School','Social','Fundraiser','Other'],true)||($registration!==''&&!preg_match('#^https?://#i',$registration)))respond(400,['error'=>'Check the event title, date, times, location, category, capacity, registration link, and details.']);$id=id_value();$event=['id'=>$id,'title'=>$title,'date'=>$date,'time'=>$time,'endTime'=>$endTime,'location'=>$location,'details'=>$details,'category'=>$category,'registrationUrl'=>$registration,'imageUrl'=>null,'capacity'=>$capacity,'organizerId'=>$user['id'],'rsvps'=>[],'invitations'=>[]];if(!empty($input['image']))$event['imageUrl']=save_image('event-uploads',$id,(string)$input['image']);$db['events'][]=$event;mark_dirty();save_state();respond(201,['ok'=>true]);
    }
    if(preg_match('#^/api/events/([^/]+)/invite$#',$path,$match)&&$method==='POST'){
        $eventIndex=find_event_index($match[1]);if($eventIndex===null)respond(404,['error'=>'That event could not be found.']);$recipientId=(string)($input['userId']??'');$recipient=find_user($recipientId);if(!$recipient||$recipientId===$user['id']||!active_member($recipient))respond(400,['error'=>'Choose another active member to invite.']);$event=&$db['events'][$eventIndex];$event['invitations']=$event['invitations']??[];$updated=false;foreach($event['invitations'] as &$inv){if(($inv['toId']??'')===$recipientId){$inv['fromId']=$user['id'];$inv['sentAt']=date(DATE_ATOM);$updated=true;break;}}unset($inv);if(!$updated)$event['invitations'][]=['fromId'=>$user['id'],'toId'=>$recipientId,'sentAt'=>date(DATE_ATOM)];mark_dirty();save_state();$sent=false;if(($recipient['emailVerified']??true)!==false)$sent=mail_send((string)$recipient['email'],"You're invited: ".$event['title'],$user['name']." invited you to this Jefferson Alumni event:\n\n".$event['title']."\nDate: ".$event['date'].' at '.($event['time']??'')."\nLocation: ".$event['location']."\n\n".($event['details']??'')."\n\nSign in: ".rtrim((string)$config['public_url'],'/').'/community');respond(200,['ok'=>true,'emailSent'=>$sent]);
    }
    if(preg_match('#^/api/events/([^/]+)/rsvp$#',$path,$match)&&$method==='POST'){
        $ei=find_event_index($match[1]);if($ei===null)respond(404,['error'=>'That event could not be found.']);$status=(string)($input['status']??'');if(!in_array($status,['going','maybe','not-going'],true))respond(400,['error'=>'Choose going, maybe, or not going.']);$event=&$db['events'][$ei];$event['rsvps']=$event['rsvps']??[];$existing=null;foreach($event['rsvps'] as &$r)if(($r['userId']??'')===$user['id']){$existing=&$r;break;}unset($r);$yes=count(array_filter($event['rsvps'],fn($r)=>($r['status']??'')==='going'));$capacity=(int)($event['capacity']??0);if($status==='going'&&$capacity>0&&($existing===null||($existing['status']??'')!=='going')&&$yes>=$capacity)respond(409,['error'=>'This event has reached its RSVP capacity.']);$previous=$existing['status']??'';if($existing!==null){$existing['status']=$status;$existing['updated']=date(DATE_ATOM);}else{$event['rsvps'][]=['userId'=>$user['id'],'status'=>$status,'updated'=>date(DATE_ATOM)];}mark_dirty();save_state();if($previous!==$status&&!empty($event['organizerId'])){$org=find_user((string)$event['organizerId']);if($org&&!empty($org['email'])&&active_member($org))mail_send($org['email'],'Event RSVP update: '.$event['title'],$user['name']." changed their RSVP to '$status'.\n\n".$event['title'].' on '.$event['date']);}respond(200,['ok'=>true]);
    }
    if($method==='GET'&&$path==='/api/messages'){
        $items=[];foreach($db['messages'] as $m){if(($m['fromId']??'')!==$user['id']&&($m['toId']??'')!==$user['id'])continue;$from=find_user((string)$m['fromId']);$to=find_user((string)$m['toId']);if(!$from||!$to)continue;$items[]=['id'=>$m['id'],'fromId'=>$m['fromId'],'toId'=>$m['toId'],'fromName'=>$from['name'],'toName'=>$to['name'],'body'=>$m['body'],'sentAt'=>$m['sentAt'],'readAt'=>$m['readAt']??null];}usort($items,fn($a,$b)=>strcmp($a['sentAt'],$b['sentAt']));respond(200,['messages'=>$items]);
    }
    if($method==='POST'&&$path==='/api/messages/read'){$other=(string)($input['userId']??'');foreach($db['messages'] as &$m)if(($m['toId']??'')===$user['id']&&($m['fromId']??'')===$other&&empty($m['readAt']))$m['readAt']=date(DATE_ATOM);unset($m);mark_dirty();save_state();respond(200,['ok'=>true]);}
    if($method==='POST'&&$path==='/api/messages'){$other=(string)($input['toId']??'');$recipient=find_user($other);$body=text_value($input['body']??'',2000);if(!$recipient||$other===$user['id']||!active_member($recipient)||$body==='')respond(400,['error'=>'Choose another active member and enter a message of 1–2,000 characters.']);$db['messages'][]=['id'=>id_value(),'fromId'=>$user['id'],'toId'=>$other,'body'=>$body,'sentAt'=>date(DATE_ATOM),'readAt'=>null];mark_dirty();save_state();respond(201,['ok'=>true]);}
    if($method==='GET'&&$path==='/api/admin'){
        if(!has_admin_access($user))respond(403,['error'=>'You do not have administration access.']);$result=['permissions'=>$user['permissions']??[]];
        if(permission($user,'permissions'))$result['permissionUsers']=array_map(fn($m)=>['id'=>$m['id'],'name'=>$m['name'],'role'=>$m['role']??'','classYear'=>$m['classYear']??'','permissions'=>$m['permissions']??[]],$db['users']);
        if(permission($user,'approveUsers')){$result['pendingUsers']=[];foreach($db['users'] as $m)if(($m['approved']??true)===false)$result['pendingUsers'][]=['id'=>$m['id'],'name'=>$m['name'],'email'=>$m['email'],'role'=>$m['role']??'','classYear'=>$m['classYear']??'','emailVerified'=>$m['emailVerified']??false,'created'=>$m['created']??''];}
        if(permission($user,'profiles'))$result['members']=array_map(fn($m)=>public_user($m,$user['id'],true),$db['users']);
        if(permission($user,'events'))$result['events']=array_map(fn($e)=>public_event($e,$db,$user['id']),$db['events']);
        if(permission($user,'posts'))$result['posts']=$db['posts'];if(permission($user,'homepagePosts'))$result['homePosts']=$db['homePosts'];if(permission($user,'customize'))$result['site']=$db['site'];
        if(permission($user,'moderate')){$result['reports']=[];foreach($db['reports'] as $r){if(($r['status']??'')!=='open')continue;$post=null;foreach($db['homePosts'] as $p)if(($p['id']??'')===($r['targetId']??''))$post=$p;$reporter=find_user((string)($r['reporterId']??''));$result['reports'][]=['id'=>$r['id'],'targetId'=>$r['targetId'],'reason'=>$r['reason'],'created'=>$r['created'],'reporter'=>$reporter['name']??'Former member','title'=>$post['title']??'Removed announcement','body'=>$post['body']??'','author'=>$post['author']??''];}}
        if(permission($user,'audit'))$result['auditLog']=array_slice($db['auditLog'],0,100);
        if(permission($user,'bulkEmail')){$result['bulkMembers']=[];foreach($db['users'] as $m)if(active_member($m))$result['bulkMembers'][]=['id'=>$m['id'],'name'=>$m['name'],'role'=>$m['role']??'','classYear'=>$m['classYear']??''];$result['bulkGroups']=array_map(fn($g)=>['id'=>$g['id'],'name'=>$g['name'],'memberIds'=>$g['memberIds']??[]],$db['discussionGroups']);}
        respond(200,$result);
    }

    if($method==='POST'&&preg_match('#^/api/admin/approvals/([a-f0-9]{32})/approve$#',$path,$match)){
        if(!permission($user,'approveUsers'))respond(403,['error'=>'You do not have permission to approve new members.']);$i=user_index($match[1]);if($i===null||($db['users'][$i]['approved']??true)!==false)respond(404,['error'=>'Pending member not found.']);$db['users'][$i]['approved']=true;$db['users'][$i]['approvalStatus']='approved';$db['users'][$i]['approvedAt']=date(DATE_ATOM);mark_dirty();add_audit($user['id'],'approved','member',$match[1],'Approved registration for '.$db['users'][$i]['name']);save_state();$m=$db['users'][$i];if(($m['emailVerified']??false)&&$emailConfigured)mail_send($m['email'],'Your Jefferson Alumni account is approved',"Hello ".$m['name'].",\n\nYour account has been approved. You can now sign in.");respond(200,['ok'=>true]);
    }
    if(preg_match('#^/api/admin/reports/([a-f0-9]{32})/(hide|dismiss)$#',$path,$match)&&$method==='POST'){
        if(!permission($user,'moderate'))respond(403,['error'=>'You do not have permission to moderate public content.']);$idx=null;foreach($db['reports'] as $i=>$r)if(($r['id']??'')===$match[1]&&($r['status']??'')==='open')$idx=$i;if($idx===null)respond(404,['error'=>'Open report not found.']);$r=&$db['reports'][$idx];if($match[2]==='hide')foreach($db['homePosts'] as &$p)if(($p['id']??'')===($r['targetId']??''))$p['audience']='members';unset($p);$r['status']=$match[2]==='hide'?'hidden':'dismissed';$r['resolvedAt']=date(DATE_ATOM);$r['resolvedBy']=$user['id'];mark_dirty();add_audit($user['id'],$match[2],'homePostReport',$r['id'],$match[2].' report for homepage announcement');save_state();respond(200,['ok'=>true]);
    }
    if($method==='GET'&&$path==='/api/admin/backup'){
        if(!permission($user,'permissions'))respond(403,['error'=>'Only a site access administrator can download a full data backup.']);http_response_code(200);header('Content-Type: application/json; charset=utf-8');header('Content-Disposition: attachment; filename="jefferson-alumni-backup.json"');echo json_encode($db,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);exit;
    }
    if($method==='GET'&&$path==='/api/admin/export'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to export member profiles.']);$columns=['name','email','role','classYear','city','bio','phone','occupation','employer','interests','website'];$out=fopen('php://temp','w+');fputcsv($out,$columns);foreach($db['users'] as $m){$row=[];foreach($columns as $k){$v=(string)($m[$k]??'');if(preg_match('/^\s*[=+@-]/',$v))$v="'".$v;$row[]=$v;}fputcsv($out,$row);}$csv=stream_get_contents($out);fclose($out);header('Content-Type: text/csv; charset=utf-8');header('Content-Disposition: attachment; filename="jefferson-members.csv"');echo $csv;exit;
    }
    if($method==='POST'&&$path==='/api/admin/import'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to import member profiles.']);$csv=(string)($input['csv']??'');if($csv===''||strlen($csv)>2000000)respond(400,['error'=>'Choose a CSV file with data under 2 MB.']);$stream=fopen('php://temp','r+');fwrite($stream,$csv);rewind($stream);$header=fgetcsv($stream);if(!$header)respond(400,['error'=>'The CSV file needs a header row.']);$header=array_map(fn($x)=>strtolower(trim((string)$x)), $header);$emails=[];foreach($db['users'] as $m)$emails[strtolower((string)$m['email'])]=true;$imported=0;$skipped=0;$sent=0;$rows=0;while(($row=fgetcsv($stream))!==false&&$rows<1000){$rows++;$v=[];foreach($header as $i=>$key)$v[$key]=$row[$i]??'';$email=strtolower(trim((string)($v['email']??'')));$name=text_value($v['name']??'',90);$role=(string)($v['role']??'Alumni');if(!filter_var($email,FILTER_VALIDATE_EMAIL)||$name===''||!in_array($role,['Alumni','Teacher','Staff'],true)||isset($emails[$email])){$skipped++;continue;}$token=token_value();$u=['id'=>id_value(),'name'=>$name,'email'=>$email,'role'=>$role,'classYear'=>text_value($v['classyear']??'',4),'city'=>text_value($v['city']??'',100),'bio'=>text_value($v['bio']??'',500),'phone'=>text_value($v['phone']??'',40),'occupation'=>text_value($v['occupation']??'',100),'employer'=>text_value($v['employer']??'',100),'interests'=>text_value($v['interests']??'',300),'website'=>text_value($v['website']??'',200),'linkedin'=>'','facebook'=>'','instagram'=>'','tiktok'=>'','maritalStatus'=>'','hasChildren'=>'','schoolsAttended'=>[],'profileVisibility'=>array_fill_keys(['name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','photo'],true),'emailVisibility'=>'members','photoUrl'=>null,'emailVerified'=>false,'approved'=>true,'approvalStatus'=>'approved','verificationHash'=>token_hash($token),'verificationExpires'=>date(DATE_ATOM,time()+604800),'resetHash'=>token_hash($token),'resetExpires'=>date(DATE_ATOM,time()+604800),'permissions'=>array_fill_keys(['profiles','events','posts','homepagePosts','approveUsers','moderate','audit','bulkEmail','customize','permissions'],false),'created'=>date(DATE_ATOM),'suspended'=>false];new_user_password($u,token_value());$db['users'][]=$u;$emails[$email]=true;$imported++;if($emailConfigured&&mail_send($email,'Your Jefferson Alumni account',"Hello $name,\n\nUse this link within 7 days to set your password and verify your email:\n".rtrim((string)$config['public_url'],'/').'/community?reset='.rawurlencode($token)))$sent++;}fclose($stream);if($imported){mark_dirty();save_state();}respond(200,['imported'=>$imported,'skipped'=>$skipped,'inviteEmailsSent'=>$sent]);
    }
    if($method==='POST'&&$path==='/api/admin/bulk-email'){
        if(!permission($user,'bulkEmail'))respond(403,['error'=>'You do not have permission to send bulk email.']);$subject=text_value($input['subject']??'',140);$body=text_value($input['body']??'',5000);$audience=(string)($input['audience']??'');$recipients=[];$eligible=array_values(array_filter($db['users'],'active_member'));
        if($audience==='all')$recipients=$eligible;elseif($audience==='class')$recipients=array_values(array_filter($eligible,fn($m)=>($m['classYear']??'')===(string)($input['classYear']??'')));elseif($audience==='selected'){$ids=array_unique(array_map('strval',$input['memberIds']??[]));$recipients=array_values(array_filter($eligible,fn($m)=>in_array((string)$m['id'],$ids,true)));}elseif($audience==='group'){$group=null;foreach($db['discussionGroups'] as $g)if(($g['id']??'')===($input['groupId']??''))$group=$g;if($group)$recipients=array_values(array_filter($eligible,fn($m)=>in_array($m['id'],$group['memberIds']??[],true)));}
        $recipients=array_values(array_filter($recipients,fn($m)=>($m['emailVerified']??true)!==false&&filter_var($m['email']??'',FILTER_VALIDATE_EMAIL)));$recipients=array_values(array_reduce($recipients,function($acc,$m){$acc[$m['id']]=$m;return $acc;},[]));if(mb_strlen($subject)<3||$body===''||!in_array($audience,['all','class','group','selected'],true)||count($recipients)<1||count($recipients)>500)respond(400,['error'=>'Choose a valid audience with between 1 and 500 verified recipients.']);$sent=0;foreach($recipients as $m)if(mail_send($m['email'],$subject,$body))$sent++;add_audit($user['id'],'sentBulkEmail','email',$audience,"Sent bulk email '$subject' to $sent of ".count($recipients).' recipient(s)');save_state();respond(200,['total'=>count($recipients),'sent'=>$sent,'failed'=>count($recipients)-$sent]);
    }
    if($method==='POST'&&$path==='/api/admin/users'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to create member profiles.']);$name=text_value($input['name']??'',90);$email=strtolower(text_value($input['email']??'',254));$role=(string)($input['role']??'');$password=(string)($input['password']??'');if(mb_strlen($name)<2||!filter_var($email,FILTER_VALIDATE_EMAIL)||!password_ok($password)||!in_array($role,['Alumni','Teacher','Staff'],true))respond(400,['error'=>'Enter a name, valid email, school connection, and strong passphrase.']);foreach($db['users'] as $m)if(strtolower($m['email'])===$email)respond(409,['error'=>'An account with that email already exists.']);$u=['id'=>id_value(),'name'=>$name,'email'=>$email,'role'=>$role,'classYear'=>text_value($input['classYear']??'',4),'city'=>'','bio'=>'','phone'=>'','occupation'=>'','employer'=>'','interests'=>'','website'=>'','linkedin'=>'','facebook'=>'','instagram'=>'','tiktok'=>'','maritalStatus'=>'','hasChildren'=>'','schoolsAttended'=>[],'profileVisibility'=>array_fill_keys(['name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','photo'],true),'emailVisibility'=>'members','photoUrl'=>null,'emailVerified'=>true,'approved'=>true,'approvalStatus'=>'approved','permissions'=>array_fill_keys(['profiles','events','posts','homepagePosts','approveUsers','moderate','audit','bulkEmail','customize','permissions'],false),'created'=>date(DATE_ATOM),'suspended'=>false];new_user_password($u,$password);$db['users'][]=$u;mark_dirty();save_state();respond(201,['ok'=>true,'user'=>public_user($u,$user['id'])]);
    }
    if(preg_match('#^/api/admin/users/([a-f0-9]{32})/suspension$#',$path,$match)&&$method==='PATCH'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to manage member profiles.']);$i=user_index($match[1]);if($i===null)respond(404,['error'=>'Member not found.']);if($match[1]===$user['id'])respond(400,['error'=>'You cannot suspend your own account.']);$suspended=!empty($input['suspended']);$db['users'][$i]['suspended']=$suspended;mark_dirty();add_audit($user['id'],$suspended?'suspended':'reinstated','member',$match[1],($suspended?'Suspended':'Reinstated').' account for '.$db['users'][$i]['name']);save_state();respond(200,['ok'=>true,'suspended'=>$suspended]);
    }
    if(preg_match('#^/api/admin/users/([a-f0-9]{32})$#',$path,$match)&&$method==='DELETE'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to manage member profiles.']);$id=$match[1];$i=user_index($id);if($i===null)respond(404,['error'=>'Member not found.']);if($id===$user['id'])respond(400,['error'=>'You cannot delete your own account.']);if(permission($db['users'][$i],'permissions')){$other=false;foreach($db['users'] as $m)if($m['id']!==$id&&permission($m,'permissions'))$other=true;if(!$other)respond(400,['error'=>'Transfer site access administration to another member before deleting this account.']);}
        $name=$db['users'][$i]['name'];$db['users']=array_values(array_filter($db['users'],fn($m)=>$m['id']!==$id));$db['messages']=array_values(array_filter($db['messages'],fn($m)=>($m['fromId']??'')!==$id&&($m['toId']??'')!==$id));foreach($db['discussionGroups'] as &$g){$g['memberIds']=array_values(array_filter($g['memberIds']??[],fn($mid)=>$mid!==$id));if(($g['ownerId']??'')===$id)$g['ownerId']=$user['id'];}unset($g);foreach($db['posts'] as &$p)if(($p['authorId']??'')===$id){$p['authorId']=null;$p['author']='Former member';$p['authorPhoto']=null;}unset($p);foreach($db['discussions'] as &$d){$d['memberIds']=array_values(array_filter($d['memberIds']??[],fn($mid)=>$mid!==$id));if(($d['authorId']??'')===$id){$d['authorId']=null;$d['author']='Former member';}}unset($d);foreach($db['events'] as &$e){$e['rsvps']=array_values(array_filter($e['rsvps']??[],fn($r)=>($r['userId']??'')!==$id));$e['invitations']=array_values(array_filter($e['invitations']??[],fn($r)=>($r['toId']??'')!==$id&&($r['fromId']??'')!==$id));}unset($e);foreach(['uploads','png','jpg','webp'] as $x){}foreach(['png','jpg','webp'] as $ext){$f=$storagePath.'/uploads/'.$id.'.'.$ext;if(is_file($f))unlink($f);}mark_dirty();add_audit($user['id'],'deleted','member',$id,'Deleted member account for '.$name);save_state();respond(200,['ok'=>true]);
    }
    if(preg_match('#^/api/admin/users/([a-f0-9]{32})/password$#',$path,$match)&&$method==='PATCH'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to reset member passwords.']);$i=user_index($match[1]);if($i===null)respond(404,['error'=>'Member not found.']);$password=(string)($input['password']??'');if(!password_ok($password))respond(400,['error'=>'Use a passphrase of at least 15 characters that is not common or repetitive.']);new_user_password($db['users'][$i],$password);$db['users'][$i]['emailVerified']=true;unset($db['users'][$i]['verificationHash'],$db['users'][$i]['verificationExpires'],$db['users'][$i]['resetHash'],$db['users'][$i]['resetExpires']);mark_dirty();add_audit($user['id'],'resetPassword','member',$match[1],'Reset password for '.$db['users'][$i]['name']);save_state();respond(200,['ok'=>true]);
    }
    if(preg_match('#^/api/admin/users/([a-f0-9]{32})/profile$#',$path,$match)&&$method==='PATCH'){
        if(!permission($user,'profiles'))respond(403,['error'=>'You do not have permission to manage profiles.']);$i=user_index($match[1]);if($i===null)respond(404,['error'=>'Member not found.']);$m=$db['users'][$i];foreach(['name'=>90,'classYear'=>4,'city'=>100,'bio'=>500,'phone'=>40,'occupation'=>100,'employer'=>100,'interests'=>300,'website'=>200,'linkedin'=>250,'facebook'=>250,'instagram'=>250,'tiktok'=>250,'maritalStatus'=>40,'hasChildren'=>40] as $key=>$max)$m[$key]=text_value($input[$key]??'', $max);$m['schoolsAttended']=array_values(array_unique(array_intersect(array_map('strval',$input['schoolsAttended']??[]),$schoolOptions)));$m['profileVisibility']=[];foreach(['name','email','role','classYear','city','bio','phone','occupation','employer','interests','website','linkedin','facebook','instagram','tiktok','maritalStatus','hasChildren','schoolsAttended','photo'] as $key)$m['profileVisibility'][$key]=!empty($input['profileVisibility'][$key]);$m['emailVisibility']=$m['profileVisibility']['email']?'members':'private';if(mb_strlen($m['name'])<2)respond(400,['error'=>'Please enter a name.']);foreach(['website','linkedin','facebook','instagram','tiktok'] as $key)if($m[$key]!==''&&!preg_match('#^https?://#i',$m[$key]))respond(400,['error'=>'Website and social links must begin with http:// or https://.']);$db['users'][$i]=$m;mark_dirty();save_state();respond(200,['ok'=>true]);
    }
    if($method==='PATCH'&&$path==='/api/admin/permissions'){
        if(!permission($user,'permissions'))respond(403,['error'=>'You do not have permission to grant access.']);$id=(string)($input['userId']??'');$i=user_index($id);if($i===null)respond(404,['error'=>'Member not found.']);$allowed=['profiles','events','posts','homepagePosts','approveUsers','moderate','audit','bulkEmail','customize','permissions'];$p=[];foreach($allowed as $key)$p[$key]=!empty($input['permissions'][$key]);if($id===$user['id']&&!$p['permissions']){$admins=0;foreach($db['users'] as $m)if(permission($m,'permissions'))$admins++;if($admins<2)respond(400,['error'=>'At least one member must retain permission to manage site access.']);}$db['users'][$i]['permissions']=$p;mark_dirty();add_audit($user['id'],'changedPermissions','member',$id,'Updated access permissions for '.$db['users'][$i]['name']);save_state();respond(200,['ok'=>true]);
    }

    if($method==='PATCH'&&preg_match('#^/api/admin/events/([a-zA-Z0-9-]{1,64})$#',$path,$match)){
        if(!permission($user,'events'))respond(403,['error'=>'You do not have permission to manage events.']);$i=find_event_index($match[1]);if($i===null)respond(404,['error'=>'Event not found.']);$e=$db['events'][$i];
        foreach(['title'=>100,'date'=>10,'time'=>40,'endTime'=>40,'location'=>120,'details'=>1000,'category'=>30,'registrationUrl'=>300] as $key=>$max)$e[$key]=text_value($input[$key]??$e[$key]??'', $max);
        $capacity=filter_var($input['capacity']??$e['capacity']??0,FILTER_VALIDATE_INT);if($capacity===false)$capacity=-1;
        if(mb_strlen($e['title'])<3||!valid_date($e['date'])||$e['date']<date('Y-m-d')||mb_strlen($e['location'])<2||!in_array($e['category'],['Reunion','School','Social','Fundraiser','Other'],true)||$capacity<0||$capacity>50000||($e['registrationUrl']!==''&&!preg_match('#^https?://#i',$e['registrationUrl'])))respond(400,['error'=>'Check the event fields and registration link.']);$e['capacity']=$capacity;$db['events'][$i]=$e;mark_dirty();add_audit($user['id'],'updated','event',$e['id'],'Updated event '.$e['title']);save_state();respond(200,['ok'=>true]);
    }
    if($method==='POST'&&preg_match('#^/api/admin/events/([a-zA-Z0-9-]{1,64})/image$#',$path,$match)){
        if(!permission($user,'events'))respond(403,['error'=>'You do not have permission to manage events.']);$i=find_event_index($match[1]);if($i===null)respond(404,['error'=>'Event not found.']);$url=save_image('event-uploads',$match[1],(string)($input['image']??''));$db['events'][$i]['imageUrl']=$url;mark_dirty();save_state();respond(200,['imageUrl'=>$url]);
    }
    if($method==='DELETE'&&preg_match('#^/api/admin/events/([a-zA-Z0-9-]{1,64})$#',$path,$match)){
        if(!permission($user,'events'))respond(403,['error'=>'You do not have permission to manage events.']);$i=find_event_index($match[1]);if($i===null)respond(404,['error'=>'Event not found.']);$db['events']=array_values(array_filter($db['events'],fn($e)=>($e['id']??'')!==$match[1]));foreach(['png','jpg','webp'] as $ext){$f=$storagePath.'/event-uploads/'.$match[1].'.'.$ext;if(is_file($f))unlink($f);}mark_dirty();save_state();respond(200,['ok'=>true]);
    }
    if($method==='DELETE'&&preg_match('#^/api/admin/posts/([a-zA-Z0-9-]{1,64})$#',$path,$match)){
        if(!permission($user,'posts'))respond(403,['error'=>'You do not have permission to manage posts.']);$n=count($db['posts']);$db['posts']=array_values(array_filter($db['posts'],fn($p)=>($p['id']??'')!==$match[1]));if(count($db['posts'])===$n)respond(404,['error'=>'Post not found.']);mark_dirty();add_audit($user['id'],'deleted','communityPost',$match[1],'Removed community post');save_state();respond(200,['ok'=>true]);
    }
    if($method==='POST'&&$path==='/api/admin/home-posts'){
        if(!permission($user,'homepagePosts'))respond(403,['error'=>'You do not have permission to publish homepage announcements.']);$title=text_value($input['title']??'',100);$body=text_value($input['body']??'',1500);$audience=(string)($input['audience']??'members');if(mb_strlen($title)<3||$body===''||!in_array($audience,['public','members'],true))respond(400,['error'=>'Check the announcement title, message, and visibility.']);$id=id_value();$imageUrl=null;if(!empty($input['image']))$imageUrl=save_image('home-post-uploads',$id,(string)$input['image']);$db['homePosts'][]=['id'=>$id,'title'=>$title,'body'=>$body,'audience'=>$audience,'imageUrl'=>$imageUrl,'author'=>$user['name'],'created'=>date(DATE_ATOM)];mark_dirty();add_audit($user['id'],'published','homePost',$id,'Published homepage announcement '.$title);save_state();respond(201,['ok'=>true]);
    }
    if($method==='DELETE'&&preg_match('#^/api/admin/home-posts/([a-f0-9]{32})$#',$path,$match)){
        if(!permission($user,'homepagePosts'))respond(403,['error'=>'You do not have permission to manage homepage announcements.']);$n=count($db['homePosts']);$db['homePosts']=array_values(array_filter($db['homePosts'],fn($p)=>($p['id']??'')!==$match[1]));if(count($db['homePosts'])===$n)respond(404,['error'=>'Homepage announcement not found.']);foreach(['png','jpg','webp'] as $ext){$f=$storagePath.'/home-post-uploads/'.$match[1].'.'.$ext;if(is_file($f))unlink($f);}mark_dirty();save_state();respond(200,['ok'=>true]);
    }
    if($method==='PATCH'&&$path==='/api/admin/site'){
        if(!permission($user,'customize'))respond(403,['error'=>'You do not have permission to customize the site.']);$site=$db['site'];$site['title']=text_value($input['title']??$site['title'],60);$site['tagline']=text_value($input['tagline']??$site['tagline'],180);$site['primaryColor']=(string)($input['primaryColor']??$site['primaryColor']);$site['accentColor']=(string)($input['accentColor']??$site['accentColor']);$site['fontFamily']=(string)($input['fontFamily']??$site['fontFamily']);if(mb_strlen($site['title'])<3||mb_strlen($site['tagline'])<5||!preg_match('/^#[0-9a-fA-F]{6}$/',$site['primaryColor'])||!preg_match('/^#[0-9a-fA-F]{6}$/',$site['accentColor'])||!in_array($site['fontFamily'],['system','georgia','arial','verdana','trebuchet'],true))respond(400,['error'=>'Check the title, tagline, colors, and font selection.']);$db['site']=$site;mark_dirty();add_audit($user['id'],'updated','siteAppearance','site','Updated website appearance settings');save_state();respond(200,['ok'=>true]);
    }
    if($method==='POST'&&$path==='/api/admin/site/image'){
        if(!permission($user,'customize'))respond(403,['error'=>'You do not have permission to customize the site.']);$kind=(string)($input['kind']??'');if(!in_array($kind,['logo','hero'],true))respond(400,['error'=>'Choose a logo or hero image.']);$url=save_image('site-assets',$kind,(string)($input['image']??''));$db['site'][$kind==='logo'?'logoUrl':'heroImageUrl']=$url;mark_dirty();save_state();respond(200,['url'=>$url,'kind'=>$kind]);
    }
    respond(404,['error'=>'Not found.']);
} catch (Throwable $e) { fail_request($e); }

function public_event(array $event,array $db,?string $viewerId): array {
    $yes=count(array_filter($event['rsvps']??[],fn($r)=>($r['status']??'')==='going'));$mine='';foreach($event['rsvps']??[] as $r)if(($r['userId']??'')===$viewerId)$mine=$r['status']??'';
    $organizer=$event['organizerName']??null;if(!empty($event['organizerId'])){$person=find_user((string)$event['organizerId']);if($person)$organizer=$person['name'];}
    $invitation=null;if($viewerId)foreach($event['invitations']??[] as $invite){if(($invite['toId']??'')===$viewerId){$sender=find_user((string)($invite['fromId']??''));if($sender)$invitation=$sender['name'];break;}}
    return ['id'=>$event['id']??'','title'=>$event['title']??'','date'=>$event['date']??'','time'=>$event['time']??'','endTime'=>$event['endTime']??null,'location'=>$event['location']??'','details'=>$event['details']??'','category'=>$event['category']??null,'registrationUrl'=>$event['registrationUrl']??null,'imageUrl'=>$event['imageUrl']??null,'capacity'=>$event['capacity']??0,'organizer'=>$organizer,'attendeeCount'=>$yes,'myRsvp'=>$mine,'myInvitation'=>$invitation];
}
