# Stops the Bionic services and the private PostgreSQL started by start-bionic.ps1.
$ErrorActionPreference = 'Continue'

$App    = Split-Path -Parent $MyInvocation.MyCommand.Path
$PgData = Join-Path $env:ProgramData 'Bionic\pgdata'
$PgBin  = Join-Path $App 'pgsql\bin'

foreach ($svc in 'web-server', 'rag-engine', 'cron') {
    $exe = Join-Path $App "$svc.exe"
    Get-Process -Name $svc -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $exe } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# bundled llama.cpp servers (local GGUF models)
$llamaExe = Join-Path $App 'llama\llama-server.exe'
Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $llamaExe } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData 'Bionic\llama-*.pid') -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $PgData 'PG_VERSION')) {
    & (Join-Path $PgBin 'pg_ctl.exe') stop -D $PgData -m fast -w *> $null
}
