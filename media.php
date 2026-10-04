<?php
declare(strict_types=1);
header('X-Content-Type-Options: nosniff');
header('Cache-Control: private, max-age=300');

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
if (!preg_match('#^/(uploads|event-uploads|home-post-assets|site-assets)/([A-Za-z0-9_-]+)\.(png|jpg|webp)$#', $path, $m)) { http_response_code(404); exit; }
$requestHost = strtolower(preg_replace('/:\\d+$/', '', (string)($_SERVER['HTTP_HOST'] ?? '')));
$hostConfig = $requestHost === 'staging.jeffersonalumni.com' ? dirname(__DIR__, 2) . '/jefferson-private/staging-config.php' : null;
$rootConfig = basename(__DIR__) === 'public_html' ? dirname(__DIR__) . '/jefferson-private/config.php' : null;
$webRoot = realpath((string)($_SERVER['DOCUMENT_ROOT'] ?? ''));
$candidates = array_filter([getenv('JH_CONFIG_PATH') ?: null, $hostConfig, dirname(__DIR__, 2) . '/jefferson-private/config.php', $rootConfig]);
$configPath = null;
foreach ($candidates as $candidate) { $candidateReal=realpath($candidate); if($candidateReal===false||!is_file($candidateReal)||!is_readable($candidateReal))continue; if($webRoot!==false&&($candidateReal===$webRoot||str_starts_with($candidateReal,rtrim($webRoot,DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR)))continue; $configPath=$candidateReal;break; }
if (!$configPath) { http_response_code(404); exit; }
$config = require $configPath;
$base = rtrim((string)($config['storage_path'] ?? ''), DIRECTORY_SEPARATOR);
if ($base === '' || str_starts_with($base, __DIR__)) { http_response_code(404); exit; }
$baseReal = realpath($base); $documentRoot = $webRoot;
if ($baseReal === false || ($documentRoot !== false && ($baseReal === $documentRoot || str_starts_with($baseReal, rtrim($documentRoot, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR)))) { http_response_code(404); exit; }
$kind = $m[1]; $id = $m[2]; $ext = $m[3];

try {
    $c = $config['db'] ?? [];
    $pdo = new PDO('mysql:host='.($c['host']??'localhost').';dbname='.($c['name']??'').';charset=utf8mb4', (string)($c['user']??''), (string)($c['password']??''), [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
    $row = $pdo->query('SELECT payload FROM jh_app_state WHERE id=1')->fetch();
    $state = $row ? json_decode((string)$row['payload'], true) : [];
    $allowed = false;
    if ($kind === 'uploads') {
        session_name('jh_session'); session_set_cookie_params(['lifetime'=>43200,'path'=>'/','secure'=>(!empty($_SERVER['HTTPS'])&&$_SERVER['HTTPS']!=='off'),'httponly'=>true,'samesite'=>'Strict']); ini_set('session.use_strict_mode','1'); session_start();
        $member = null; foreach (($state['users']??[]) as $candidate) if (($candidate['id']??'') === $id) { $member=$candidate; break; }
        $viewer = null; foreach (($state['users']??[]) as $candidate) if (($candidate['id']??'') === ($_SESSION['uid']??'')) { $viewer=$candidate; break; }
        $memberActive = $member && ($member['approved']??true)!==false && ($member['emailVerified']??true)!==false && empty($member['suspended']);
        $viewerActive = $viewer && ($viewer['approved']??true)!==false && ($viewer['emailVerified']??true)!==false && empty($viewer['suspended']);
        $allowed = $memberActive && $viewerActive && (($member['id']??'')===($viewer['id']??'') || !empty($viewer['permissions']['profiles']) || !empty($member['profileVisibility']['photo']));
    } elseif ($kind === 'event-uploads') {
        foreach (($state['events']??[]) as $event) if (($event['id']??'') === $id) { $allowed=true; break; }
    } elseif ($kind === 'home-post-assets') {
        session_name('jh_session'); session_set_cookie_params(['lifetime'=>43200,'path'=>'/','secure'=>(!empty($_SERVER['HTTPS'])&&$_SERVER['HTTPS']!=='off'),'httponly'=>true,'samesite'=>'Strict']); ini_set('session.use_strict_mode','1'); session_start();
        $viewerActive = false; foreach (($state['users']??[]) as $candidate) if (($candidate['id']??'') === ($_SESSION['uid']??'')) $viewerActive = ($candidate['approved']??true)!==false && ($candidate['emailVerified']??true)!==false && empty($candidate['suspended']);
        foreach (($state['homePosts']??[]) as $post) if (($post['id']??'') === $id && (($post['audience']??'') === 'public' || $viewerActive)) { $allowed=true; break; }
    } else {
        $key = $id === 'logo' ? 'logoUrl' : ($id === 'hero' ? 'heroImageUrl' : '');
        if ($key !== '') $allowed = (($state['site'][$key]??'') === $path);
    }
    if (!$allowed) { http_response_code(404); exit; }
    $file = $base.'/'.$kind.'/'.$id.'.'.$ext;
    if (!is_file($file) || !is_readable($file)) { http_response_code(404); exit; }
    $mime = ['png'=>'image/png','jpg'=>'image/jpeg','webp'=>'image/webp'][$ext];
    header('Content-Type: '.$mime); header('Content-Length: '.(string)filesize($file)); readfile($file);
} catch (Throwable $e) { error_log('Jefferson Alumni media error: '.$e->getMessage()); http_response_code(404); }
