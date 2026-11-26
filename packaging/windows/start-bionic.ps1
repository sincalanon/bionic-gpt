# Starts a local, single-user Bionic on Windows:
#   1. a private PostgreSQL (with pgvector) on 127.0.0.1
#   2. database migrations (dbmate)
#   3. local models via the bundled llama.cpp (llama-server):
#        - an embeddings model shipped with the installer
#        - a chat model from a GGUF file the user picks (asked on first start,
#          or any time with -PickModel / the "选择 GGUF 模型" shortcut)
#      both are registered in Bionic automatically
#   4. web-server (+ rag-engine and cron when present)
# then opens the app in the default browser.
#
# Data lives in %ProgramData%\Bionic (ASCII path, survives reinstall).
# Settings can be overridden in %ProgramData%\Bionic\bionic.env (KEY=VALUE lines).

param([switch]$NoBrowser, [switch]$PickModel)

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

# Windows (Hyper-V / WinNAT) reserves random port ranges; binding inside one
# fails with "Permission denied". Pick a port we can actually bind and remember it.
function Test-PortFree([int]$port) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

function Select-Port([string]$name, [int]$preferred) {
    $file = Join-Path $Root "$name.port"
    $candidates = @()
    if (Test-Path $file) { $candidates += [int](Get-Content $file -TotalCount 1) }
    $candidates += $preferred
    $rand = New-Object System.Random
    for ($i = 0; $i -lt 40; $i++) { $candidates += $rand.Next(20000, 40000) }
    foreach ($p in $candidates) {
        if (Test-PortFree $p) {
            Set-Content -Path $file -Value $p -Encoding ASCII
            return $p
        }
    }
    throw "No free TCP port found for $name"
}

# ------------------------------------------------------------ llama.cpp
$LlamaDir = Join-Path $App 'llama'
$LlamaExe = Join-Path $LlamaDir 'llama-server.exe'

function Test-PidAlive([string]$name) {
    $file = Join-Path $Root "llama-$name.pid"
    if (-not (Test-Path $file)) { return $false }
    $p = Get-Process -Id ([int](Get-Content $file -TotalCount 1)) -ErrorAction SilentlyContinue
    return ($p -and $p.Path -eq $LlamaExe)
}

function Stop-Llama([string]$name) {
    $file = Join-Path $Root "llama-$name.pid"
    if (Test-PidAlive $name) { Stop-Process -Id ([int](Get-Content $file -TotalCount 1)) -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
    Remove-Item $file -ErrorAction SilentlyContinue
}

function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + $a.Replace('"', '\"') + '"' } return $a }

# Starts llama-server for one model; returns its port. Reuses a running one.
function Start-Llama([string]$name, [string]$model, [int]$preferred, [string[]]$extra) {
    if (Test-PidAlive $name) { return (Get-SavedPort "llama-$name" $preferred) }
    $port = Select-Port "llama-$name" $preferred
    $argList = @('-m', $model, '--host', '127.0.0.1', '--port', "$port") + $extra
    $argLine = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
    Write-Log "Starting llama-server ($name) on port ${port}: $argLine"
    $p = Start-Process -FilePath $LlamaExe -ArgumentList $argLine -WorkingDirectory $LlamaDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Logs "llama-$name.out.log") `
        -RedirectStandardError  (Join-Path $Logs "llama-$name.err.log")
    Set-Content -Path (Join-Path $Root "llama-$name.pid") -Value $p.Id -Encoding ASCII
    return $port
}

# Waits until llama-server answers /health with 200 (model loaded).
function Wait-Llama([string]$name, [int]$port, [int]$seconds) {
    for ($i = 0; $i -lt $seconds; $i++) {
        if (-not (Test-PidAlive $name)) { return 'exited' }
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$port/health"
            if ($r.StatusCode -eq 200) { return 'ready' }
        } catch { }
        Start-Sleep -Seconds 1
    }
    return 'loading'
}

function Sql-Text([string]$v) { return "'" + $v.Replace("'", "''") + "'" }

# Creates or updates the model row Bionic uses for a local llama-server.
function Register-Model([string]$name, [string]$type, [string]$display, [int]$port, [int]$ctx) {
    $url = Sql-Text "http://127.0.0.1:$port/v1"
    $n = Sql-Text $name; $d = Sql-Text $display
    $sql = @"
UPDATE model_registry.models SET base_url = $url, context_size = $ctx, display_name = $d, provider_type = 'OpenAICompatible', updated_at = NOW()
 WHERE name = $n AND model_type = '$type';
INSERT INTO model_registry.models (name, model_type, provider_type, base_url, api_key, tpm_limit, rpm_limit, context_size, display_name, description)
SELECT $n, '$type', 'OpenAICompatible', $url, 'local', 10000000, 10000000, $ctx, $d, 'Local GGUF model served by the bundled llama.cpp'
 WHERE NOT EXISTS (SELECT 1 FROM model_registry.models WHERE name = $n AND model_type = '$type');
"@
    $sqlFile = Join-Path $Root 'register-model.sql'
    Set-Content -Path $sqlFile -Value $sql -Encoding UTF8
    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d bionic-gpt -v ON_ERROR_STOP=1 -q -f $sqlFile *>> (Join-Path $Logs 'register-model.log')
    if ($LASTEXITCODE -ne 0) { throw "Could not register model $name, see $Logs\register-model.log" }
}

function Show-GgufPicker {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; WindowState = 'Minimized' }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Bionic - 选择本地 GGUF 对话模型（取消则跳过）'
    $dlg.Filter = 'GGUF 模型 (*.gguf)|*.gguf|所有文件 (*.*)|*.*'
    $ok = $dlg.ShowDialog($owner)
    $owner.Dispose()
    if ($ok -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}

function Show-Info([string]$text) {
    if ($env:CI) { return }
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show($text, 'Bionic') | Out-Null
}

function Start-LocalModels {
    if (-not (Test-Path $LlamaExe)) { Write-Log 'llama-server not bundled, skipping local models'; return }

    # Embeddings: Bionic needs one before chat is enabled.
    $embedModel = Get-ChildItem (Join-Path $App 'models') -Filter *.gguf -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($embedModel) {
        $ePort = Start-Llama 'embed' $embedModel.FullName 8081 @('--embeddings', '-c', '512', '-b', '512', '-ub', '512', '-ngl', '0')
        Register-Model 'bionic-local-embeddings' 'Embeddings' "Local Embeddings ($($embedModel.BaseName))" $ePort 512
    }

    # Chat model from a GGUF the user picked.
    $ggufFile = Join-Path $Root 'gguf.txt'
    $skipFile = Join-Path $Root 'gguf.skip'
    $gguf = $null
    if ($env:BIONIC_GGUF) { $gguf = $env:BIONIC_GGUF }
    elseif (Test-Path $ggufFile) { $gguf = (Get-Content $ggufFile -TotalCount 1 -Encoding UTF8).Trim() }

    $ask = $PickModel -or ((-not $gguf -or -not (Test-Path -LiteralPath $gguf)) -and -not (Test-Path $skipFile))
    if ($ask -and -not $env:CI) {
        $picked = Show-GgufPicker
        if ($picked) {
            $gguf = $picked
            Set-Content -Path $ggufFile -Value $gguf -Encoding UTF8
            Remove-Item $skipFile -ErrorAction SilentlyContinue
            Stop-Llama 'chat'
        } elseif (-not $PickModel) {
            Set-Content -Path $skipFile -Value 'skipped' -Encoding ASCII
        }
    }
    if (-not $gguf -or -not (Test-Path -LiteralPath $gguf)) { Write-Log 'No GGUF chat model selected'; return }

    $ctx = 8192
    if ($custom.ContainsKey('LLAMA_CTX')) { $ctx = [int]$custom['LLAMA_CTX'] }
    $extra = @('-c', "$ctx", '--jinja')
    if ($custom.ContainsKey('LLAMA_ARGS')) { $extra += ($custom['LLAMA_ARGS'] -split '\s+' | Where-Object { $_ }) }
    $cPort = Start-Llama 'chat' $gguf 8080 $extra
    Register-Model 'bionic-local-gguf' 'LLM' ([System.IO.Path]::GetFileNameWithoutExtension($gguf)) $cPort $ctx

    # Catch an immediate failure (bad file, out of memory) without waiting for a large model to load.
    $state = Wait-Llama 'chat' $cPort 8
    if ($state -eq 'exited') {
        Write-Log "llama-server (chat) exited, see $Logs\llama-chat.err.log"
        Show-Info "本地模型启动失败：`n$gguf`n`n可能是文件损坏、内存/显存不足或格式不受支持。`n日志：$Logs\llama-chat.err.log`n`n可从开始菜单「选择 GGUF 模型」换一个。"
    }
}

function Get-SavedPort([string]$name, [int]$default) {
    $file = Join-Path $Root "$name.port"
    if (Test-Path $file) { return [int](Get-Content $file -TotalCount 1) }
    return $default
}

try {
    # ---------------------------------------------------------------- settings
    $envFile = Join-Path $Root 'bionic.env'
    if (-not (Test-Path $envFile)) {
        @(
            '# Extra environment variables for Bionic (KEY=VALUE, one per line).',
            '# Examples:',
            '# PORT=7703',
            '# BIND_ADDRESS=127.0.0.1',
            '# LOG_LEVEL=DEBUG',
            '# KREUZBERG_API_ENDPOINT=http://localhost:3300',
            '# Local GGUF chat model (llama.cpp):',
            '# LLAMA_CTX=8192',
            '# LLAMA_ARGS=-ngl 99 -t 8'
        ) | Set-Content -Path $envFile -Encoding ASCII
    }
    $custom = @{}
    foreach ($l in Get-Content $envFile) {
        if ($l -match '^\s*#' -or $l -notmatch '=') { continue }
        $k, $v = $l.Split('=', 2)
        $custom[$k.Trim()] = $v.Trim()
    }
    $fixedAppPort = $custom.ContainsKey('PORT')
    if ($fixedAppPort) { $AppPort = [int]$custom['PORT'] }

    # -------------------------------------------------------------- postgres
    $env:PATH = "$PgBin;$env:PATH"
    if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) {
        Write-Log 'Initialising database cluster (first run)...'
        & (Join-Path $PgBin 'initdb.exe') -D $PgData -U postgres -A trust -E UTF8 --locale=C *>> (Join-Path $Logs 'initdb.log')
        if ($LASTEXITCODE -ne 0) { throw "initdb failed, see $Logs\initdb.log" }
    }

    & (Join-Path $PgBin 'pg_ctl.exe') status -D $PgData *> $null
    if ($LASTEXITCODE -eq 0) {
        $PgPort = Get-SavedPort 'postgres' $PgPort
    } else {
        $PgPort = Select-Port 'postgres' $PgPort
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

    # ---------------------------------------------------------- local models
    Start-LocalModels

    # ---------------------------------------------------------- app services
    $webExe = Join-Path $App 'web-server.exe'
    $webRunning = Get-Process -Name 'web-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $webExe }
    if (-not $fixedAppPort) {
        if ($webRunning) { $AppPort = Get-SavedPort 'web' $AppPort } else { $AppPort = Select-Port 'web' $AppPort }
    }

    $env:APP_DATABASE_URL    = "postgresql://application_user:testpassword@127.0.0.1:$PgPort/bionic-gpt?sslmode=disable"
    $env:APP_BASE_URL        = "http://localhost:$AppPort"
    # No login is required, so only this computer may connect.
    # To share on the LAN, set BIND_ADDRESS=0.0.0.0 in bionic.env (not recommended).
    $env:BIND_ADDRESS        = '127.0.0.1'
    # Single local user, no login screen (same as the upstream docker-compose quick start).
    $env:DANGER_JWT_OVERRIDE = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyLCJlbWFpbCI6ImpvaG5AYWNtZS5vcmcifQ.daYgeWqnpmtorlFKjb0sdRFDcPPWfow68KRZh3uUDhc'
    foreach ($k in $custom.Keys) { Set-Item -Path "env:$k" -Value $custom[$k] }
    $env:PORT = "$AppPort"

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
    Set-Content -Path (Join-Path $Root 'url.txt') -Value $url -Encoding ASCII
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
