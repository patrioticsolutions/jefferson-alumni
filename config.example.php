<?php
/**
 * Copy this file outside public_html to staging-config.php and config.php.
 * Never put real credentials in the Git repository or under public_html.
 */
return [
    // Required only when starting with an empty database. This exact address may create the first administrator.
    'bootstrap_admin_email' => '',
    'timezone' => 'America/Chicago',
    'db' => [
        'host' => 'localhost',
        'name' => 'CPANELUSER_jefferson',
        'user' => 'CPANELUSER_app',
        'password' => 'replace-with-a-long-random-password',
        'charset' => 'utf8mb4',
    ],
    'storage_path' => '/home/CPANELUSER/jefferson-private/storage',
    'public_url' => 'https://www.jeffersonalumni.com',
    'smtp' => [
        'host' => '',
        'port' => 587,
        'username' => '',
        'password' => '',
        'from' => '',
        'from_name' => 'Jefferson Alumni',
        'encryption' => 'tls',
    ],
];
