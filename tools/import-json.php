<?php
declare(strict_types=1);

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$source = $argv[1] ?? '';
if ($source === '' || !is_file($source) || !in_array('--confirm-import', $argv, true)) {
    fwrite(STDERR, "Usage: php tools/import-json.php /private/path/alumni.json --confirm-import [--media-dir=/private/path/data]\nThe destination database must not already contain an application state row.\n");
    exit(2);
}
$candidates = array_filter([getenv('JH_CONFIG_PATH') ?: null, dirname(__DIR__, 3) . '/jefferson-private/config.php', dirname(__DIR__, 3) . '/private/config.php']);
$configPath = null;
foreach ($candidates as $candidate) if (is_file($candidate) && is_readable($candidate)) { $configPath = $candidate; break; }
if (!$configPath) { fwrite(STDERR, "Set JH_CONFIG_PATH to your private config.php path.\n"); exit(2); }
$config = require $configPath;
$privateStorage = rtrim((string)($config['storage_path']??''), DIRECTORY_SEPARATOR);
if ($privateStorage === '' || !is_dir($privateStorage) || realpath($privateStorage) === false) { fwrite(STDERR, "Create the configured private storage directory before importing.\n"); exit(2); }
$raw = (string)file_get_contents($source);
if (str_starts_with($raw, "\xEF\xBB\xBF")) $raw = substr($raw, 3);
$state = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
if (!is_array($state) || !isset($state['users']) || !is_array($state['users'])) { fwrite(STDERR, "Source file is not a Jefferson Alumni database.\n"); exit(2); }
$c = $config['db'] ?? [];
$pdo = new PDO('mysql:host='.($c['host']??'localhost').';dbname='.($c['name']??'').';charset=utf8mb4', (string)($c['user']??''), (string)($c['password']??''), [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$pdo->beginTransaction();
try {
    if ($pdo->query('SELECT id FROM jh_app_state WHERE id=1 FOR UPDATE')->fetchColumn() !== false) throw new RuntimeException('The destination already has application data. Import stopped without changing it.');
    $stmt = $pdo->prepare('INSERT INTO jh_app_state (id,payload) VALUES (1,?)');
    $stmt->execute([json_encode($state, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR)]);
    $pdo->commit();
} catch (Throwable $e) { if ($pdo->inTransaction()) $pdo->rollBack(); fwrite(STDERR, $e->getMessage()."\n"); exit(1); }

$sourceData = dirname($source);
foreach ($argv as $argument) if (str_starts_with($argument, '--media-dir=')) $sourceData = substr($argument, 12);
foreach (['uploads'=>'uploads','event-uploads'=>'event-uploads','home-post-uploads'=>'home-post-uploads','site-assets'=>'site-assets'] as $from=>$to) {
    $src=$sourceData.'/'.$from; $dst=$privateStorage.'/'.$to;
    if (!is_dir($src)) continue;
    if (!is_dir($dst) && !mkdir($dst,0750,true) && !is_dir($dst)) { fwrite(STDERR,"Data imported, but could not create $dst; copy that image folder manually.\n"); continue; }
    foreach (glob($src.'/*') ?: [] as $file) if (is_file($file) && preg_match('/\.(png|jpg|webp)$/i',$file) && !copy($file,$dst.'/'.basename($file))) fwrite(STDERR,"Could not copy image ".basename($file)." from $src\n");
}
fwrite(STDOUT, 'Imported '.count($state['users']).' member record(s) and copied available images. Verify the site before inviting members. '.PHP_EOL);
