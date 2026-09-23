<#
.SYNOPSIS
    SisPatrimonio Pro - Desinstalador de Producao WINDOWS (nativo)

.DESCRIPTION
    Versao Windows (PowerShell) do uninstall.sh (Feature 027). Reverte a
    instalacao criada por install.ps1, nesta ordem:
      1. tarefa agendada (stop/unregister) + regra de firewall
      2. diretorio da aplicacao (codigo, venv, .env, logs, backups)
      3. banco e usuario do MariaDB/MySQL (SOMENTE com confirmacao explicita)
      4. MariaDB inteiro (apenas com -PurgeMariaDb + dupla confirmacao)
      5. log do instalador

    Nota: no Windows nao existe usuario Linux dedicado do servico - a tarefa
    roda como SYSTEM (nada a remover nesta etapa).

    Seguranca (mesmos principios do install.ps1 - SR-001..SR-005):
      - NADA destrutivo sem confirmacao explicita (ou -Yes para o basico);
      - banco NUNCA e apagado por engano: exige digitar o nome do banco;
      - -PurgeMariaDb apaga TODOS os bancos do servidor - dupla confirmacao;
      - detecta o banco/usuario a partir do .env instalado (nao hardcode);
      - credencial de root do banco via variavel de ambiente
        SISPAT_DB_ADMIN_PASSWORD (nunca argv/log) ou coletada sem eco;
      - idempotente: pode ser executado repetidamente; nada de erros feios.

.USO
    powershell -ExecutionPolicy Bypass -File uninstall.ps1                  # interativo
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Yes             # remove app+tarefa;
                                                                            # banco ainda exige confirmacao
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepDb          # NAO toca no banco
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeMariaDb    # remove o MariaDB inteiro (destrutivo)
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -InstallDir Z -ServiceName X

    Codigo 100% ASCII: evita corrupcao de acentos em Windows PowerShell 5.1.

.NOTES
    Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$KeepDb,
    [switch]$PurgeMariaDb,
    [string]$InstallDir,
    [string]$ServiceName,
    [switch]$Help
)

# EAP=Continue: comandos nativos (mysql/sc.exe) escrevem em stderr e, no
# Windows PowerShell 5.1 com EAP=Stop, o redirecionamento 2>/1> promove essas
# linhas a erros terminantes espurios. Chamadas nativas sao validadas por
# $LASTEXITCODE; cmdlets criticos usam -ErrorAction Stop explicito.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Version     = '1.0.0-win'
$InstallLog  = Join-Path $env:ProgramData 'sispatrimonio-install.log'
$FwRuleName  = 'SisPatrimonio Pro'

$script:KeepDb      = $KeepDb
$script:PurgeDb     = $PurgeMariaDb
$script:AssumeYes   = $Yes
$script:DbName      = ''
$script:DbUser      = ''
$script:DbHost      = '127.0.0.1'
$script:DbPort      = '3306'
$script:DbClient    = $null
$script:DbAdminPassword = ''
$script:DbAdminResolved = $false

# ----------------------------------------------------------------------------
# Log (mesma filosofia do install.ps1)
# ----------------------------------------------------------------------------
function Write-Log([string]$Level, [string]$Message) {
    $line = ('[{0}] {1}' -f $Level.PadRight(5), $Message)
    $color = @{ INFO = 'Cyan'; OK = 'Green'; AVISO = 'Yellow'; ERRO = 'Red' }[$Level]
    Write-Host ('[{0}] {1}' -f $Level.PadRight(5), $Message) -ForegroundColor $color
    try { Add-Content -Path $InstallLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}
function info { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$m) Write-Log 'INFO'  ($m -join ' ') }
function ok   { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$m) Write-Log 'OK'   ($m -join ' ') }
function warn { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$m) Write-Log 'AVISO' ($m -join ' ') }
function err  { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$m) Write-Log 'ERRO'  ($m -join ' ') }
function die  { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$m) err ($m -join ' '); exit 1 }

# ----------------------------------------------------------------------------
# Parser e validacao de CLI
# ----------------------------------------------------------------------------
function Show-Usage {
@"
SisPatrimonio Pro - desinstalador de producao WINDOWS (nativo) v$Version

Uso: powershell -ExecutionPolicy Bypass -File uninstall.ps1 [opcoes]

  -Yes                Nao pede confirmacao para app/tarefa/firewall
                      (o BANCO continua exigindo confirmacao explicita
                      digitando o nome do banco)
  -KeepDb             Nao apaga banco nem usuario do banco
  -PurgeMariaDb       Remove o MariaDB/MySQL inteiro (TODOS os bancos -
                      destrutivo; exige dupla confirmacao)
  -InstallDir <caminho>   Default: C:\SisPatrimonioPro
  -ServiceName <nome>     Default: sispatrimoniopro
  -Help               Esta ajuda

Nota de seguranca: a senha de root do MariaDB deve estar na variavel de
ambiente SISPAT_DB_ADMIN_PASSWORD (ou sera coletada sem eco quando necessaria).

Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
"@
}

function Parse-Args {
    if ($Help) { Show-Usage; exit 0 }
    if (-not $InstallDir)  { $script:InstallDir  = 'C:\SisPatrimonioPro' }
    if (-not $ServiceName) { $script:ServiceName = 'sispatrimoniopro' }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { die '-InstallDir nao pode ser vazio.' }
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { die '-ServiceName nao pode ser vazio.' }
}

function Test-Confirmed([string]$Question) {
    if ($script:AssumeYes) { return $true }
    # Entrada vazia/EOF => NAO confirmar (padrao de preservacao do uninstall.sh)
    $ans = Read-Host $Question
    return ($ans -match '^(s|S|sim|SIM|y|Y)$')
}

function Sql-Escape([string]$Value) {
    if ($Value.Contains('\')) { die 'Valor contem backslash final (\) - nao suportado.' }
    return $Value.Replace("'", "''")
}

function Find-DbClientExe {
    foreach ($cmd in @('mysql.exe', 'mariadb.exe')) {
        $c = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $cands = @()
    $cands += Get-ChildItem 'C:\Program Files\MariaDB *\bin\mysql.exe'            -ErrorAction SilentlyContinue
    $cands += Get-ChildItem 'C:\Program Files\MariaDB *\bin\mariadb.exe'          -ErrorAction SilentlyContinue
    $cands += Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe' -ErrorAction SilentlyContinue
    if ($cands.Count -gt 0) { return $cands[0].FullName }
    return $null
}

function Invoke-DbSql {
    # SQL com credencial no ambiente (senha nunca em argv/log)
    param([string]$Sql, [string]$AsUser = 'root', [string]$Password)
    $old = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $Password
        $cliArgs = @('--user', $AsUser, '--host', $script:DbHost, '--port', $script:DbPort, '-N', '-B', '-e', $Sql)
        $out = & $script:DbClient @cliArgs 2>$null
        return ,@($out)
    } finally {
        if ($null -ne $old) { $env:MYSQL_PWD = $old } else { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue }
    }
}

function Test-DbSql {
    param([string]$Sql, [string]$AsUser = 'root', [string]$Password)
    [void](Invoke-DbSql -Sql $Sql -AsUser $AsUser -Password $Password)
    return ($LASTEXITCODE -eq 0)
}

function Resolve-DbAdminAccess {
    if ($script:DbAdminResolved) { return }
    $cands = @()
    if ($env:SISPAT_DB_ADMIN_PASSWORD) { $cands += $env:SISPAT_DB_ADMIN_PASSWORD }
    $cands += ''
    foreach ($cand in $cands) {
        if (Test-DbSql -Sql 'SELECT 1;' -Password $cand) {
            $script:DbAdminPassword = $cand
            $script:DbAdminResolved = $true
            return
        }
    }
    $p = Read-Secret 'Senha de root do MariaDB/MySQL (sem eco; vazia nas duas = tentar senha vazia): '
    if (-not $p) { $p = '' }
    if (-not (Test-DbSql -Sql 'SELECT 1;' -Password $p)) {
        die 'Credencial de root invalida. Verifique a senha e reexecute (idempotente).'
    }
    $script:DbAdminPassword = $p
    $script:DbAdminResolved = $true
}

function Read-Secret([string]$Prompt) {
    $p1 = Read-Host -AsSecureString $Prompt
    $p2 = Read-Host -AsSecureString 'Confirme a senha (vazio nas duas = tentar senha vazia):'
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
    if (-not $v1 -or $v1 -ne $v2) { die 'As senhas nao conferem. Operacao abortada.' }
    return $v1
}

function Detect-DbFromEnv {
    # le DATABASE_URL do .env instalado (sem exibir a senha)
    $envFile = Join-Path $InstallDir '.env'
    if (-not (Test-Path $envFile)) { return $false }
    $url = ''
    foreach ($line in (Get-Content $envFile)) {
        if ($line -match '^DATABASE_URL=(.+)$') { $url = $Matches[1].Trim(); break }
    }
    if (-not $url) { return $false }
    # Parse SEM ecoar credenciais: mariadb+pymysql://user:pass@host:port/db[?...]
    if ($url -match '^[^:]+://([^:]+):[^@]+@([^:/]+):(\d+)/([^/?]+)') {
        $script:DbUser = $Matches[1]
        $script:DbHost = $Matches[2]
        $script:DbPort = $Matches[3]
        $script:DbName = $Matches[4]
        return ($DbName -and $DbUser)
    }
    return $false
}

function Remove-ServiceTask {
    info 'Tarefa agendada'
    $task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false -ErrorAction Stop
        ok "Tarefa $ServiceName removida."
    } else {
        ok "Tarefa $ServiceName nao esta instalada - nada a fazer."
    }
    $fw = Get-NetFirewallRule -DisplayName "$FwRuleName*" -ErrorAction SilentlyContinue
    if ($fw) {
        $fw | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        ok 'Regra de firewall da aplicacao removida.'
    } else {
        ok 'Nenhuma regra de firewall da aplicacao presente - nada a fazer.'
    }
}

function Remove-AppDir {
    info 'Diretorio da aplicacao'
    if (Test-Path $InstallDir) {
        if (Test-Confirmed "Remover $InstallDir INTEIRO (codigo, venv, .env, data/logs e data/backups - irreversivel)? (s/N): ") {
            Remove-Item -Recurse -Force $InstallDir -ErrorAction Stop
            ok 'Diretorio removido.'
        } else {
            warn 'Diretorio PRESERVADO por solicitacao.'
        }
    } else {
        ok "$InstallDir nao existe - nada a fazer."
    }
}

function Remove-Database {
    info 'Banco de dados'
    if ($KeepDb) {
        warn 'Desinstalacao com -KeepDb: banco e usuario do banco PRESERVADOS.'
        return
    }
    $script:DbClient = Find-DbClientExe
    if (-not $DbClient) {
        ok 'Cliente MariaDB/MySQL nao presente - nada a fazer.'
        return
    }
    if ($DbName) {
        warn "O .env instalado apontava para o banco '$DbName' (usuario '$DbUser')."
    } else {
        $n = Read-Host 'Nome do banco da aplicacao a remover (vazio = preservar)'
        if (-not $n) { warn 'Nenhum banco informado - preservado.'; return }
        $script:DbName = $n
    }
    # Confirmacao OBRIGATORIA (mesmo com -Yes): digitar o nome do banco
    $c1 = Read-Host "Digite o nome do banco para CONFIRMAR a remocao de '$DbName' e seus dados (vazio = preservar)"
    if ($c1 -ne $DbName) {
        warn 'Banco PRESERVADO (confirmacao nao recebida).'
        return
    }
    Resolve-DbAdminAccess
    [void](Invoke-DbSql -Sql "DROP DATABASE IF EXISTS ``$(Sql-Escape $DbName)``;" -Password $DbAdminPassword)
    ok "Banco '$DbName' removido."
    if ($DbUser) {
        $c2 = Read-Host "Remover tambem o usuario do banco '$DbUser' (localhost e 127.0.0.1)? (s/N)"
        if ($c2 -match '^(s|S|sim|SIM|y|Y)$') {
            [void](Invoke-DbSql -Sql "DROP USER IF EXISTS '$(Sql-Escape $DbUser)'@'localhost';" -Password $DbAdminPassword)
            [void](Invoke-DbSql -Sql "DROP USER IF EXISTS '$(Sql-Escape $DbUser)'@'127.0.0.1';" -Password $DbAdminPassword)
            [void](Invoke-DbSql -Sql 'FLUSH PRIVILEGES;' -Password $DbAdminPassword)
            ok "Usuario '$DbUser' removido."
        } else {
            warn 'Usuario do banco preservado.'
        }
    }
}

function Purge-MariaDb {
    # DESTRUTIVO: TODOS os bancos do servidor - dupla confirmacao (padrao 027)
    if (-not $PurgeDb) { return }
    info 'Remocao do MariaDB/MySQL (solicitada via -PurgeMariaDb)'
    warn '================================================================'
    warn 'ATENCAO: isto apaga TODOS os bancos de dados deste servidor -'
    warn 'nao apenas o do SisPatrimonio. IRREVERSIVEL.'
    warn '================================================================'
    $c1 = Read-Host "Digite EXATAMENTE 'PURGAR-MARIADB' para confirmar"
    if ($c1 -ne 'PURGAR-MARIADB') { warn 'MariaDB PRESERVADO.'; return }
    $c2 = Read-Host 'Confirmar novamente (s/N)'
    if ($c2 -notmatch '^(s|S|sim|SIM|y|Y)$') { warn 'MariaDB PRESERVADO.'; return }

    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(MariaDB|MySQL)' } | Select-Object -First 1
    if ($svc) {
        if ($svc.Status -eq 'Running') { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue }
        # Remocao silenciosa via MSI (Windows Installer), quando o produto existir
        $pkg = Get-Package -Name '*MariaDB*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) {
            info ("Desinstalando o pacote '" + $pkg.Name + "' (Windows Installer)...")
            # $args e variavel automatica do PowerShell - usar nome proprio
            $msiArgs = @('/x', $pkg.FastPackageReference, '/qn', '/norestart')
            Start-Process 'msiexec.exe' -ArgumentList $msiArgs -Wait -ErrorAction Stop
        } else {
            warn 'Pacote MariaDB nao localizado via Get-Package - remova via Painel de Controle se aplicavel.'
        }
        if (Get-Service -Name $svc.Name -ErrorAction SilentlyContinue) {
            & sc.exe delete $svc.Name *> $null
        }
    }
    # Restos de dados/programa (cuidadoso: somente diretorios do MariaDB/MySQL)
    foreach ($path in @('C:\Program Files\MariaDB *', 'C:\Program Files\MySQL', "$env:ProgramData\MariaDB", "$env:ProgramData\MySQL")) {
        if (Test-Path $path) { Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue }
    }
    ok 'MariaDB removido (pacote + dados, quando localizados).'
}

function Remove-InstallLog {
    info 'Log do instalador'
    if (Test-Path $InstallLog) {
        Remove-Item -Force $InstallLog -ErrorAction Stop
        ok "$InstallLog removido."
    } else {
        ok 'Nenhum log de instalacao presente.'
    }
}

function Main {
    Parse-Args
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($wi)
    if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        die 'Execute como Administrador (PowerShell elevado).'
    }
    info "SisPatrimonio Pro - Desinstalador WINDOWS (nativo) v$Version ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
    if (-not $AssumeYes) {
        $gate = Read-Host 'Desinstalar o SisPatrimonio Pro deste servidor? (s/N)'
        if ($gate -notmatch '^(s|S|sim|SIM|y|Y)$') {
            die 'Desinstalacao cancelada. Nada foi alterado.'
        }
    }

    # Deteccao ANTES de remover o diretorio (.env e a fonte do banco/usuario)
    if (Detect-DbFromEnv) {
        ok "Configuracao detectada no .env: banco '$DbName', usuario '$DbUser' (senha NUNCA exibida)."
    } else {
        warn '.env nao encontrado/legivel - o nome do banco sera perguntado na etapa de banco.'
    }

    Remove-ServiceTask
    Remove-AppDir
    Remove-Database
    Purge-MariaDb
    Remove-InstallLog

    Write-Host ''
    ok 'Desinstalacao concluida.'
    if ($KeepDb) { warn 'Lembrete: banco/usuario do banco foram PRESERVADOS (-KeepDb).' }
    warn 'Pacotes padrao (Python, Git) foram mantidos - remova manualmente se desejar.'
}

Main
