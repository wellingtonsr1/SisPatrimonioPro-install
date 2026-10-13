<#
.SYNOPSIS
    SisPatrimonio Pro - Redefinicao da senha de root do MySQL 8.0 (WINDOWS)

.DESCRIPTION
    Aplica o metodo OFICIAL do MySQL para reset de senha de root (documentacao
    "How to Reset the Root Password", secao Windows): para o servico, sobe o
    servidor temporariamente com --init-file contendo o ALTER USER, valida a
    nova senha e reinicia o servico normal.

    - TODOS os bancos e dados sao PRESERVADOS (nenhum dado e apagado).
    - Ha uma breve PARADA do banco durante o processo (10-60s tipico).
    - A nova senha e digitada SEM ECO e vai apenas para o arquivo init
      temporario, que e APAGADO ao final (sucesso ou falha).
    - Nenhuma senha passa por argv (SR-001).

.USO
    powershell -ExecutionPolicy Bypass -File reset-root.ps1
    powershell -ExecutionPolicy Bypass -File reset-root.ps1 -Yes
    powershell -ExecutionPolicy Bypass -File reset-root.ps1 -ServiceName MYSQL80

.NOTES
    Requer PowerShell como Administrador.
    Exit codes: 0 sucesso | 1 falha
#>
[CmdletBinding()]
param(
    [string]$ServiceName,
    [string]$ClientDir,
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function info([string]$m) { Write-Host ('[INFO] ' + $m) -ForegroundColor Cyan }
function ok  ([string]$m) { Write-Host ('[OK  ] ' + $m) -ForegroundColor Green }
function warn([string]$m) { Write-Host ('[AVISO] ' + $m) -ForegroundColor Yellow }
function die ([string]$m) { Write-Host ('[ERRO] ' + $m) -ForegroundColor Red; exit 1 }

function Show-Usage {
@"
SisPatrimonio Pro - reset da senha de root do MySQL (Windows)

Uso: powershell -ExecutionPolicy Bypass -File reset-root.ps1 [opcoes]

  -ServiceName <nome>   Nome do servico (default: detecao automatica, ex.: MYSQL80)
  -ClientDir <caminho>  Diretorio bin do servidor (default: deteccao automatica)
  -Yes                  Nao pede confirmacao (a senha continua sendo digitada sem eco)
  -Help                 Esta ajuda

Metodo oficial do MySQL (--init-file). Bancos e dados preservados; o banco
fica offline brevemente durante o procedimento. Requer Administrador.
"@
}

if ($Help) { Show-Usage; exit 0 }

# --- Administrador? ---------------------------------------------------------
$wi = [Security.Principal.WindowsIdentity]::GetCurrent()
$wp = New-Object Security.Principal.WindowsPrincipal($wi)
if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    die 'Este script requer execucao como Administrador (abrir PowerShell elevado).'
}

# --- Localiza mysqld.exe / mysql.exe ----------------------------------------
$bin = $null
if ($ClientDir) {
    $bin = $ClientDir
} else {
    $g = Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin' -Directory -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($g) { $bin = $g.FullName }
}
if (-not $bin -or -not (Test-Path (Join-Path $bin 'mysqld.exe'))) {
    die ('mysqld.exe nao encontrado. Informe -ClientDir com o diretorio bin do servidor (ex.: "C:\Program Files\MySQL\MySQL Server 8.0\bin").')
}
$mysqld = Join-Path $bin 'mysqld.exe'
$mysql  = Join-Path $bin 'mysql.exe'
info ('Servidor: ' + $mysqld)

# --- Localiza o servico -----------------------------------------------------
if ($ServiceName) {
    $svcObj = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svcObj) { die "Servico '$ServiceName' nao existe." }
} else {
    $svcObj = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(MySQL|MariaDB)' } | Select-Object -First 1
    if (-not $svcObj) { die 'Nenhum servico MySQL/MariaDB encontrado - informe -ServiceName.' }
}
$svc = $svcObj.Name
info ('Servico: ' + $svc)

# --- defaults-file usado pelo servico (via linha de comando do servico) -----
$defaultsFile = $null
$pathname = (Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).PathName
if ($pathname) {
    if ($pathname -match '--defaults-file="([^"]+)"') { $defaultsFile = $Matches[1] }
    elseif ($pathname -match '--defaults-file=(\S+)') { $defaultsFile = $Matches[1] }
}
if ($defaultsFile) { info ('Defaults file do servico: ' + $defaultsFile) }
else { warn 'Servico sem --defaults-file visivel; o servidor especial subira com defaults padrao.' }

# --- Nova senha (sem eco; mesma politica do instalador: >= 12, sem backslash)
function Read-Secret([string]$Prompt) {
    $p1 = Read-Host -AsSecureString $Prompt
    $p2 = Read-Host -AsSecureString 'Confirme a senha'
    if ($p1.Length -eq 0 -and $p2.Length -eq 0) { return '' }
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
    try {
        $v1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
        $v2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    }
    if (-not $v1 -or $v1 -ne $v2) { die 'As senhas nao conferem. Operacao abortada (nada foi alterado).' }
    return $v1
}

Write-Host ''
Write-Host '  A nova senha deve ter no minimo 12 caracteres e nao pode conter backslash (\).' -ForegroundColor White
$newPass = Read-Secret 'Nova senha de root (min. 12 caracteres)'
if (-not $newPass)                      { die 'Senha vazia nao e permitida aqui (o objetivo e justamente definir uma senha).' }
if ($newPass.Length -lt 12)             { die 'Senha muito curta (minimo 12 caracteres - mesma politica do instalador).' }
if ($newPass.Contains('\'))             { die 'A senha nao pode conter backslash (\) - escolha outra.' }

# --- Confirmacao ------------------------------------------------------------
if (-not $Yes) {
    Write-Host ''
    warn 'O servico sera PARADO, o servidor subira em modo especial por alguns'
    warn 'segundos para redefinir a senha de root e voltara ao normal.'
    warn 'Bancos e dados PRESERVADOS. Aplicacoes que usam o banco ficarao'
    warn 'offline brevemente (10-60s tipico).'
    $ans = Read-Host 'Continuar? (s/N)'
    if ($ans -notmatch '^(s|S|sim|SIM|y|Y)$') { die 'Cancelado pelo operador - nada foi alterado.' }
}

# --- Arquivo init temporario (contem a senha; ACL restrita; apagado no fim) --
$initFile = Join-Path ([IO.Path]::GetTempPath()) ('sispat-reset-root-{0}.sql' -f [Guid]::NewGuid().ToString('N'))
$outLog   = Join-Path ([IO.Path]::GetTempPath()) ('sispat-mysqld-{0}.out.log' -f [Guid]::NewGuid().ToString('N'))
$errLog   = Join-Path ([IO.Path]::GetTempPath()) ('sispat-mysqld-{0}.err.log' -f [Guid]::NewGuid().ToString('N'))

$esc = $newPass.Replace("'", "''")
$sql = "ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '$esc';`r`nFLUSH PRIVILEGES;`r`n"
[IO.File]::WriteAllText($initFile, $sql, (New-Object System.Text.UTF8Encoding($false)))
& icacls $initFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' ("{0}\{1}:F" -f $env:USERDOMAIN, $env:USERNAME) *> $null

function Test-RootLogin([string]$Pass) {
    $env:MYSQL_PWD = $Pass
    try {
        & $mysql --user=root --host=127.0.0.1 --port=3306 -N -B -e 'SELECT 1;' *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    }
}

try {
    # --- 1) Para o servico normal -------------------------------------------
    info ('Parando o servico ' + $svc + '...')
    Stop-Service -Name $svc -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Service -Name $svc).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if ((Get-Service -Name $svc).Status -ne 'Stopped') { die 'O servico nao parou a tempo - verifique o Visualizador de Eventos e tente novamente.' }
    ok 'Servico parado.'

    # --- 2) Sobe o servidor especial com --init-file -------------------------
    info 'Subindo servidor temporario para aplicar o ALTER USER (metodo oficial --init-file)...'
    $argList = @()
    if ($defaultsFile) { $argList += ('"--defaults-file=' + $defaultsFile + '"') }
    $argList += ('"--init-file=' + $initFile + '"')
    $argList += '--console'
    $proc = Start-Process -FilePath $mysqld -ArgumentList $argList -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

    # --- 3) Aguarda o servidor especial aceitar a NOVA senha -----------------
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { break }
        if (Test-RootLogin $newPass) { $ready = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $ready) {
        if ($proc.HasExited) { warn 'O servidor temporario saiu antes de ficar pronto.' }
        else                 { warn 'Tempo esgotado aguardando o servidor temporario.' }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        warn 'Ultimas linhas do log do servidor temporario:'
        if (Test-Path $errLog) { Get-Content $errLog -Tail 15 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Red } }
        info ('Reiniciando o servico normal ' + $svc + '...')
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        die 'Reset NAO concluido. O servico normal foi reativado - nada foi alterado; verifique o log acima.'
    }
    ok 'Nova senha de root aplicada e validada no servidor temporario.'

    # --- 4) Desliga o servidor especial de forma limpa ------------------------
    $env:MYSQL_PWD = $newPass
    try { & $mysql --user=root --host=127.0.0.1 --port=3306 -N -B -e 'SHUTDOWN;' *> $null } finally { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    ok 'Servidor temporario encerrado.'

    # --- 5) Reinicia o servico normal e valida --------------------------------
    info ('Reiniciando o servico ' + $svc + '...')
    Start-Service -Name $svc -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Service -Name $svc).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if ((Get-Service -Name $svc).Status -ne 'Running') { die 'O servico nao voltou a rodar - verifique o Visualizador de Eventos e reinicie manualmente (Start-Service).' }
    if (-not (Test-RootLogin $newPass)) { die 'Servico ativo, mas a nova senha NAO foi aceita - verifique o Visualizador de Eventos.' }
    ok ('Servico ' + $svc + ' ativo e nova senha validada (TCP 127.0.0.1:3306).')

    Write-Host ''
    ok 'CONCLUIDO: senha de root redefinida (bancos e dados preservados).'
    ok 'Agora reexecute o instalador e informe ESTA nova senha quando pedido.'
    exit 0
} finally {
    # O arquivo init contem a senha: apagar SEMPRE (sucesso ou falha).
    Remove-Item -LiteralPath $initFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outLog   -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errLog   -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
}
