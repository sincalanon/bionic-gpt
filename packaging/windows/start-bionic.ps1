# Starts a local, single-user Bionic on Windows:
#   1. a private PostgreSQL (with pgvector) on 127.0.0.1:54329
#   2. database migrations (dbmate)
#   3. web-server (+ rag-engine and cron when present)
# then opens http://localhost:7703 in the default browser.
#
# Data lives in %ProgramData%\Bionic (ASCII path, survives reinstall).
# Settings can be overridden in %ProgramData%\Bionic\bionic.env (KEY=VALUE lines).

param([switch]$NoBrowser)

# Native tools (initdb, pg_ctl, dbmate) write progress to stderr; with 'Stop'
# Windows PowerShell 5.1 would turn that into terminating errors. Exit codes
# are checked explicitly instead.
$ErrorActionPreference = 'Continue'

$App     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root    = Join-Path $env:ProgramData 'Bionic'
$PgData  = Join-Path $Root 'pgdata'
$Logs    = Join-Path $Root 'logs'
$PgBin   = Join-Path $App 'pgsql\bin'
$PgPort  = 54329
$AppPort = 7703

New-Item -ItemType Directory -Force -Path $Root, $Logs | Out-Null

function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path (Join-Path $Logs 'launcher.log') -Value $line
}

try {
    # ---------------------------------------------------------------- settings
    $envFile = Join-Path $Root 'bionic.env'
    if (-not (Test-Path $envFile)) {
        @(
            '# Extra environment variables for Bionic (KEY=VALUE, one per line).',
            '# Examples:',
            '# PORT=7703',
            '# LOG_LEVEL=DEBUG',
            '# KREUZBERG_API_ENDPOINT=http://localhost:3300'
        ) | Set-Content -Path $envFile -Encoding ASCII
    }
    $custom = @{}
    foreach ($l in Get-Content $envFile) {
        if ($l -match '^\s*#' -or $l -notmatch '=') { continue }
        $k, $v = $l.Split('=', 2)
        $custom[$k.Trim()] = $v.Trim()
    }
    if ($custom.ContainsKey('PORT')) { $AppPort = [int]$custom['PORT'] }

    # -------------------------------------------------------------- postgres
    $env:PATH = "$PgBin;$env:PATH"
    if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) {
        Write-Log 'Initialising database cluster (first run)...'
        & (Join-Path $PgBin 'initdb.exe') -D $PgData -U postgres -A trust -E UTF8 --locale=C *>> (Join-Path $Logs 'initdb.log')
        if ($LASTEXITCODE -ne 0) { throw "initdb failed, see $Logs\initdb.log" }
    }

    & (Join-Path $PgBin 'pg_ctl.exe') status -D $PgData *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Starting PostgreSQL on port $PgPort..."
        & (Join-Path $PgBin 'pg_ctl.exe') start -D $PgData -w -t 60 -l (Join-Path $Logs 'postgres.log') -o "-p $PgPort -c listen_addresses=127.0.0.1"
        if ($LASTEXITCODE -ne 0) { throw "PostgreSQL failed to start, see $Logs\postgres.log" }
    }

    $psql = Join-Path $PgBin 'psql.exe'
    $exists = & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='bionic-gpt'"
    if ("$exists".Trim() -ne '1') {
        Write-Log 'Creating database bionic-gpt...'
        & (Join-Path $PgBin 'createdb.exe') -h 127.0.0.1 -p $PgPort -U postgres bionic-gpt
        if ($LASTEXITCODE -ne 0) { throw 'createdb failed' }
    }

    # ------------------------------------------------------------ migrations
    Write-Log 'Applying migrations...'
    $env:DATABASE_URL = "postgresql://postgres@127.0.0.1:$PgPort/bionic-gpt?sslmode=disable"
    & (Join-Path $App 'dbmate.exe') --no-dump-schema --migrations-dir (Join-Path $App 'migrations') up *>> (Join-Path $Logs 'migrations.log')
    if ($LASTEXITCODE -ne 0) { throw "Migrations failed, see $Logs\migrations.log" }

    # ---------------------------------------------------------- app services
    $env:APP_DATABASE_URL    = "postgresql://application_user:testpassword@127.0.0.1:$PgPort/bionic-gpt?sslmode=disable"
    $env:PORT                = "$AppPort"
    $env:APP_BASE_URL        = "http://localhost:$AppPort"
    # Single local user, no login screen (same as the upstream docker-compose quick start).
    $env:DANGER_JWT_OVERRIDE = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyLCJlbWFpbCI6ImpvaG5AYWNtZS5vcmcifQ.daYgeWqnpmtorlFKjb0sdRFDcPPWfow68KRZh3uUDhc'
    foreach ($k in $custom.Keys) { Set-Item -Path "env:$k" -Value $custom[$k] }

    foreach ($svc in 'web-server', 'rag-engine', 'cron') {
        $exe = Join-Path $App "$svc.exe"
        if (-not (Test-Path $exe)) { continue }
        $running = Get-Process -Name $svc -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
        if ($running) { Write-Log "$svc already running"; continue }
        Write-Log "Starting $svc..."
        Start-Process -FilePath $exe -WorkingDirectory $App -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $Logs "$svc.out.log") `
            -RedirectStandardError  (Join-Path $Logs "$svc.err.log") | Out-Null
    }

    # wait for the web server
    $url = "http://localhost:$AppPort/"
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', $AppPort); $c.Close(); $ok = $true; break
        } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ok) { throw "web-server did not start, see $Logs\web-server.err.log" }

    Write-Log "Bionic is running at $url"
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
}
catch {
    Write-Log "ERROR: $_"
    if (-not $env:CI) {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show("Bionic failed to start:`n`n$_`n`nLogs: $Logs", 'Bionic') | Out-Null
    }
    exit 1
}
