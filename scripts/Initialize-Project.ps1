$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$file=Join-Path $root '.env'
if(Test-Path -LiteralPath $file){Write-Host '.env already exists; its encryption key is preserved.';exit 0}
function New-RandomSecret {
 $bytes=New-Object byte[] 32
 $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
 try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
 ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
}
$data=@('N8N_VERSION=2.45.7',('N8N_ENCRYPTION_KEY='+(New-RandomSecret)),('N8N_RUNNERS_AUTH_TOKEN='+(New-RandomSecret)),'GENERIC_TIMEZONE=Asia/Singapore')
[IO.File]::WriteAllLines($file,$data,(New-Object Text.UTF8Encoding($false)))
Write-Host 'Created .env with random secrets. Back it up with the n8n_data volume.'
