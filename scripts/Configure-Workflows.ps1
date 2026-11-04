param([Parameter(Mandatory=$true)][string]$SupabaseUrl)
$ErrorActionPreference='Stop'
if($SupabaseUrl -notmatch '^https://[a-z0-9-]+\.supabase\.co/?$'){throw 'Paste only the project URL from Supabase Settings > API. Do not enter an API key here.'}
$base=$SupabaseUrl.TrimEnd('/')
$root=Split-Path -Parent $PSScriptRoot
$source=Join-Path $root 'workflows'
$target=Join-Path $root '.local\workflows'
New-Item -ItemType Directory -Path $target -Force | Out-Null
$placeholder='https://your-project-ref.supabase.co'
foreach($file in Get-ChildItem -LiteralPath $source -Filter '*.json'){
 $workflow=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
 foreach($node in $workflow.nodes){
  if($node.type -eq 'n8n-nodes-base.httpRequest' -and $node.parameters.url.StartsWith($placeholder)){$node.parameters.url=$node.parameters.url.Replace($placeholder,$base)}
 }
 $json=ConvertTo-Json -InputObject $workflow -Depth 100
 [IO.File]::WriteAllText((Join-Path $target $file.Name),$json+[Environment]::NewLine,(New-Object System.Text.UTF8Encoding($false)))
}
Write-Host 'Private workflow files are ready. No API keys were written.'
