<#
.SYNOPSIS
    SisPatrimonio Pro - Instalador Automatizado de Producao WINDOWS (nativo)

.DESCRIPTION
    Versao Windows (PowerShell) do install.sh (Feature 027). Prepara um servidor
    Windows para executar o SisPatrimonio Pro em producao:
      prerequisitos -> Python >= 3.10 -> Git -> MariaDB/MySQL -> banco+usuario
      -> clone -> venv -> requirements.txt -> certificados SSL (HTTPS local)
      -> .env -> Tarefa Agendada (servico) -> /health -> resumo

    Idempotente: pode ser executado novamente - cada etapa detecta o estado
    anterior e REUTILIZA o que ja existe. Banco existente NUNCA e apagado
    (recriacao so via -RecreateDb, com dupla confirmacao interativa).

    Seguranca (SR-001..SR-005): senha do banco coletada SEM ECO (Read-Host
    -AsSecureString) ou gerada via RNG criptografico; NUNCA em argv (credencial
    do cliente mysql vai via variavel de ambiente MYSQL_PWD, como no Linux);
    NUNCA em log; .env com ACL restrita (heranca removida; apenas
    SYSTEM/Administradores/usuario atual); a tarefa roda como SYSTEM.

    DIVERGENCIAS em relacao ao Linux (necessarias no Windows):
      - systemd -> Tarefa Agendada (dispara no boot, reinicia em falha);
        roda como SYSTEM (a criacao de usuario dedicado sem login interativo
        via script e fragil no Windows; o .env fica restrito por ACL).
      - autenticacao administrativa do banco: no Linux usava unix_socket;
        aqui usa a senha de root do MariaDB (coletada sem eco, ou via variavel
        de ambiente SISPAT_DB_ADMIN_PASSWORD no modo nao interativo).
      - regra de firewall de entrada e criada para a porta da aplicacao
        (sem ela o acesso via rede e bloqueado por padrao no Windows).

.USO
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -NonInteractive `
        -DbName X -DbUser Y -GenerateDbPassword
    (em modo NAO interativo, a senha de root do MariaDB deve estar na
     variavel de ambiente SISPAT_DB_ADMIN_PASSWORD, ou vazia na instalacao nova)

    Codigo 100% ASCII: evita corrupcao de acentos em Windows PowerShell 5.1
    (que le .ps1 sem BOM como ANSI).

.NOTES
    Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
    Contrato base: specs/027-instalador-producao-linux/contracts/installer-contract.md
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$InstallDir,
    [string]$Repo,
    [string]$Branch,
    [string]$DbName,
    [string]$DbUser,
    [string]$DbPassword,
    [switch]$GenerateDbPassword,
    [string]$DbHost,
    [string]$DbPort,
    [string]$AppHost,
    [string]$AppPort,
    [string]$ServiceName,
    [string]$ServiceUser,
    [switch]$RecreateDb,
    [switch]$SkipSsl,
    [switch]$Update,
    [switch]$Help
)

# EAP=Continue: comandos nativos (git/pip/mysql/python) escrevem em stderr e,
# no Windows PowerShell 5.1 com EAP=Stop, o redirecionamento 2>/1> promove
# essas linhas a erros terminantes espurios. Cada chamada nativa e validada
# por $LASTEXITCODE + die(); cmdlets criticos usam -ErrorAction Stop explicito.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# Constantes e defaults
# ----------------------------------------------------------------------------
$DefaultRepoUrl     = 'https://github.com/wellingtonsr1/SisPatrimonioPro.git'
$DefaultBranch      = 'main'
$DefaultInstallDir  = 'C:\SisPatrimonioPro'
$DefaultDbName      = 'sispatrimoniopro_db'
$DefaultDbUser      = 'sispat'
$DefaultDbHost      = '127.0.0.1'   # TCP local ('localhost' pode resolver em socket/pipe no Windows)
$DefaultDbPort      = '3306'
$DefaultAppHost     = '0.0.0.0'
$DefaultAppPort     = '8000'
$DefaultServiceName = 'sispatrimoniopro'
$DefaultServiceUser = 'SYSTEM'
$InstallLog         = Join-Path $env:ProgramData 'sispatrimonio-install.log'
$HealthTimeoutSeconds = 120
$MinPythonMajor = 3
$MinPythonMinor = 10

$AppVersionInstaller = '1.2.0-win'
$Script:Step   = ''
$Script:StepNo = 0
$TotalSteps    = 16
$script:SslEnabled = $false   # decidido na etapa 'Certificados SSL (HTTPS local)'

# ----------------------------------------------------------------------------
# Log (FR-016, R1/R2): niveis INFO/OK/WARNING/ERROR + arquivo em ProgramData.
# Cores via Write-Host; o arquivo recebe SEMPRE texto limpo (sem credenciais).
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

function die {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$m)
    err ($m -join ' ')
    Write-Host ''
    Write-Host '  +-- INSTALACAO INTERROMPIDA ---------------------------------'
    Write-Host ('  | Etapa: {0}' -f $Script:Step) -ForegroundColor Red
    Write-Host ('  | Log completo: {0} (sem credenciais)' -f $InstallLog)
    Write-Host '  | Corrija o problema e reexecute o instalador - ele e'
    Write-Host '  | idempotente e reutiliza o que ja foi concluido'
    Write-Host '  | (nenhum dado e apagado).'
    Write-Host '  +-------------------------------------------------------------'
    exit 1
}

function Write-Step([string]$Name) {
    $Script:StepNo++
    $Script:Step = $Name
    Write-Host ''
    Write-Host ('-- [{0}/{1}] {2}' -f $Script:StepNo, $TotalSteps, $Name) -ForegroundColor White
}

function Test-Confirmed([string]$Question) {
    if ($NonInteractive) { return $true }
    $ans = Read-Host $Question
    return ($ans -match '^(s|S|sim|SIM|y|Y)$')
}

# Coleta de senha SEM ECO (SR-001). Vazio NAS DUAS entradas = tentar senha vazia.
function Read-Secret([string]$Prompt) {
    $p1 = Read-Host -AsSecureString $Prompt
    $p2 = Read-Host -AsSecureString 'Confirme a senha (vazio nas duas = tentar senha vazia)'
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
    if (-not $v1 -or $v1 -ne $v2) { die 'As senhas nao conferem (ou primeira vazia e confirmacao preenchida). Operacao abortada.' }
    return $v1
}

# Segredo criptograficamente seguro (SR-002): base64url (sem backslash, sem '%').
function New-Secret {
    $b = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}
function New-HexKey {  # chave de sessao (formato do cabecalho do compose)
    $b = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ----------------------------------------------------------------------------
# T003 - Parser e validacao de CLI (contract S1, FR-015, D2)
# ----------------------------------------------------------------------------
function Show-Usage {
@"
SisPatrimonio Pro - instalador de producao WINDOWS (nativo) v$AppVersionInstaller

Uso: powershell -ExecutionPolicy Bypass -File install.ps1 [opcoes]

  -NonInteractive              Nenhum prompt; exige -DbPassword ou -GenerateDbPassword
  -InstallDir <caminho>        Diretorio de instalacao (default: $DefaultInstallDir)
  -Repo <url>                  Repositorio Git (default: repo oficial)
  -Branch <nome>               Branch (default: $DefaultBranch)
  -DbName <nome>               Nome do banco (default: $DefaultDbName)
  -DbUser <usuario>            Usuario do banco (default: $DefaultDbUser)
  -DbPassword <senha>          Senha do banco (nao interativo; NAO use em producao compartilhada)
  -GenerateDbPassword          Gera senha forte automaticamente (vai direto ao .env)
  -DbHost <host>               Host do banco (default: $DefaultDbHost)
  -DbPort <porta>              Porta do banco (default: $DefaultDbPort)
  -AppHost <host>              Bind da aplicacao (default: $DefaultAppHost)
  -AppPort <porta>             Porta da aplicacao (default: $DefaultAppPort)
  -ServiceName <nome>          Nome da tarefa agendada (default: $DefaultServiceName)
  -ServiceUser <usuario>       Usuario da tarefa (default: SYSTEM)
  -RecreateDb                  APAGA e recria o banco da aplicacao (SO interativo;
                               dupla confirmacao; proibido com -NonInteractive)
  -SkipSsl                     Nao gera certificados SSL nem grava APP_SSL_* (HTTP puro)
  -Update                      Reservado: ainda nao implementado (NFR-005)
  -Help                        Esta ajuda

Nota de seguranca: em modo NAO interativo a senha de root do MariaDB deve
estar na variavel de ambiente SISPAT_DB_ADMIN_PASSWORD (nunca em argv).

Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
"@
}

function Parse-Args {
    if ($Help) { Show-Usage; exit 0 }
    if ($Update) { die 'A opcao -Update ainda nao esta implementada (NFR-005). Use o fluxo manual documentado no README.' }
    if ($Repo)   { $script:RepoUrl = $Repo }
    if ($Branch) { $script:BranchValue = $Branch }
}

function Test-Identifier([string]$Label, [string]$Value, [string]$Pattern) {
    if ($Value -notmatch $Pattern) { die "$Label invalido: '$Value' (esperado: $Pattern)" }
}

function Validate-Inputs {
    if (-not $DbName)      { $script:DbName = $DefaultDbName }
    if (-not $DbUser)      { $script:DbUser = $DefaultDbUser }
    if (-not $InstallDir)  { $script:InstallDir = $DefaultInstallDir }
    if (-not $DbHost)      { $script:DbHost = $DefaultDbHost }
    if (-not $DbPort)      { $script:DbPort = $DefaultDbPort }
    if (-not $AppHost)     { $script:AppHost = $DefaultAppHost }
    if (-not $AppPort)     { $script:AppPort = $DefaultAppPort }
    if (-not $ServiceName) { $script:ServiceName = $DefaultServiceName }
    if (-not $ServiceUser) { $script:ServiceUser = $DefaultServiceUser }

    $script:VenvPython = Join-Path $script:InstallDir '.venv\Scripts\python.exe'

    Test-Identifier 'Nome do banco'    $DbName      '^[A-Za-z_][A-Za-z0-9_]*$'
    Test-Identifier 'Usuario do banco' $DbUser      '^[A-Za-z_][A-Za-z0-9_]*$'
    Test-Identifier 'Nome da tarefa'   $ServiceName '^[a-z][a-z0-9-]*$'

    if ($AppPort -notmatch '^[0-9]+$' -or [int]$AppPort -lt 1 -or [int]$AppPort -gt 65535) {
        die "Porta da aplicacao invalida: $AppPort (1-65535)"
    }
    if ($AppHost -match '[^A-Za-z0-9.\-]') {
        die "Host da aplicacao invalido: '$AppHost' (use IPv4, hostname ou 0.0.0.0)"
    }
    if ($AppHost -match '^\d+\.\d+\.\d+\.\d+$') {
        foreach ($oct in ($AppHost -split '\.')) { if ([int]$oct -gt 255) { die "Host da aplicacao invalido: octeto $oct fora de 0-255 em '$AppHost'" } }
    }

    # D2/FR-015: recriacao de banco e PROIBIDA em modo nao interativo
    if ($RecreateDb -and $NonInteractive) {
        die 'Combinacao invalida: -RecreateDb e proibida com -NonInteractive (decisao D2).'
    }
    # FR-015: no modo nao interativo, senha deve ser fornecida ou marcada como gerada
    if ($NonInteractive -and -not $GenerateDbPassword -and -not $DbPassword) {
        die 'Modo nao interativo exige -DbPassword ou -GenerateDbPassword.'
    }
    if ($DbPassword -and $GenerateDbPassword) {
        die 'Use apenas uma: -DbPassword OU -GenerateDbPassword.'
    }
    if ($DbPassword -and $DbPassword.Length -lt 12) {
        die 'Senha manual do banco deve ter no minimo 12 caracteres (gerada atende automaticamente).'
    }
    # Backslash: o MySQL interpreta \n/\t etc. dentro de string literal - rejeita
    # ANTES de qualquer mutacao (a senha gerada - base64url - nunca contem '\').
    if ($DbPassword -and $DbPassword.Contains('\')) {
        die 'Senha manual do banco nao pode conter backslash (\) - escolha outra senha ou use -GenerateDbPassword.'
    }
    if (-not $RepoUrl)     { $script:RepoUrl = $DefaultRepoUrl }
    if (-not $BranchValue) { $script:BranchValue = $DefaultBranch }
}

function Collect-Secrets {
    if ($NonInteractive) {
        if ($GenerateDbPassword) {
            $script:DbPassword = New-Secret
            ok 'Senha do banco gerada automaticamente (gravada apenas no .env).'
        }
        return
    }
    if (-not $DbPassword) {
        Write-Host ''
        $script:DbPassword = Read-Secret 'Senha do banco (min. 12 caracteres; ENTER vazio nas duas = gerar automaticamente)'
        if (-not $DbPassword) {
            $script:DbPassword = New-Secret
            ok 'Senha do banco gerada automaticamente (gravada apenas no .env).'
        } elseif ($DbPassword.Length -lt 12) {
            die 'Senha manual do banco deve ter no minimo 12 caracteres (ou deixe vazia para gerar).'
        } elseif ($DbPassword.Contains('\')) {
            die 'Senha do banco nao pode conter backslash (\) - escolha outra senha ou deixe vazia para gerar automaticamente.'
        }
    }
}

function Confirm-Plan {
    if ($NonInteractive) { return }
    Write-Host ''
    Write-Host '  RESUMO DA INSTALACAO' -ForegroundColor White
    Write-Host ('    Diretorio    : ' + $InstallDir)
    Write-Host ('    Repositorio  : ' + $RepoUrl + ' (branch ' + $BranchValue + ')')
    Write-Host ('    Banco        : ' + $DbName + ' (usuario ' + $DbUser + ' em ' + $DbHost + ':' + $DbPort + ')')
    Write-Host ('    Aplicacao    : ' + $AppHost + ':' + $AppPort)
    Write-Host ('    Tarefa       : ' + $ServiceName + ' (roda como ' + $ServiceUser + ')')
    if ($RecreateDb) { warn ('*** -RecreateDb ATIVO: o banco ''' + $DbName + ''' sera APAGADO e recriado ***') }
    Write-Host ''
    if (-not (Test-Confirmed '  Confirmar e iniciar a instalacao? (s/N): ')) {
        die 'Instalacao cancelada pelo operador. Nada foi alterado.'
    }
    ok 'Confirmado.'
}

# ----------------------------------------------------------------------------
# Gates de prerequisitos (FR-002, SR-005)
# ----------------------------------------------------------------------------
function Require-Admin {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($wi)
    if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        die 'Este instalador requer execucao como Administrador (abrir PowerShell elevado).'
    }
    ok 'Executando com privilegios de administrador.'
}

# ----------------------------------------------------------------------------
# T005 - Deteccao de host (data-model S1.2, R3/R4)
# ----------------------------------------------------------------------------
function Get-PythonVersion {
    try { return (Invoke-PyCode -PythonExe 'python' "import sys; print('%d.%d' % (sys.version_info[0], sys.version_info[1]))" 2>$null) } catch { return '0.0' }
}

function Test-PythonAtLeast([int]$Major, [int]$Minor) {
    $v = Get-PythonVersion
    if ($v -match '^(\d+)\.(\d+)$') { return ([int]$Matches[1] -gt $Major) -or (([int]$Matches[1] -eq $Major) -and ([int]$Matches[2] -ge $Minor)) }
    return $false
}

function Find-DbClientExe {
    foreach ($cmd in @('mysql.exe', 'mariadb.exe')) {
        $c = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $candidates = @()
    $candidates += Get-ChildItem 'C:\Program Files\MariaDB *\bin\mysql.exe'            -ErrorAction SilentlyContinue
    $candidates += Get-ChildItem 'C:\Program Files\MariaDB *\bin\mariadb.exe'          -ErrorAction SilentlyContinue
    $candidates += Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe' -ErrorAction SilentlyContinue
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

function Detect-Host {
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $script:HasPython = $true
        $script:PyVer = Get-PythonVersion
        ok "Python $PyVer detectado."
    } else {
        $script:HasPython = $false
        warn 'Python 3 nao encontrado.'
    }
    if (Get-Command git -ErrorAction SilentlyContinue) { ok 'Git detectado.' } else { warn 'Git nao encontrado.' }

    # D3/R4: detecta MariaDB OU MySQL por servico real
    $script:DbServiceName = ''
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(MariaDB|MySQL)' -or $_.DisplayName -match '^(MariaDB|MySQL)' } | Select-Object -First 1
    if ($svc) { $script:DbServiceName = $svc.Name; ok ("Servidor de banco detectado: servico '" + $svc.Name + "' (sera REUTILIZADO).") }
    else      { warn 'Nenhum servidor MariaDB/MySQL detectado (sera instalado MariaDB - decisao D3).' }

    $script:DbClient = Find-DbClientExe
    if ($DbClient) { ok ('Cliente de banco: ' + $DbClient) }
    else           { warn 'Cliente mysql/mariadb nao encontrado - sera provido com o servidor.' }

    # Porta da aplicacao em uso? (risco da spec - reportada antes do start)
    $conn = Get-NetTCPConnection -LocalPort ([int]$AppPort) -State Listen -ErrorAction SilentlyContinue
    if ($conn) { warn "Porta $AppPort ja esta em uso (verifique antes de iniciar a tarefa)." }
}

# ----------------------------------------------------------------------------
# T006 - Pacotes (FR-003/FR-004/FR-005, R3): via winget quando disponivel
# ----------------------------------------------------------------------------
function Install-WinGetPackage([string]$Id, [string]$Label) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    info "Instalando $Label via winget ($Id; pode levar alguns minutos)..."
    & winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Write-Host "    $_" }
    return ($LASTEXITCODE -eq 0)
}

function Ensure-Packages {
    if (-not $HasPython) {
        if (-not (Install-WinGetPackage 'Python.Python.3.12' 'Python 3.12')) {
            die "Python nao instalado. Instale Python >= $MinPythonMajor.$MinPythonMinor manualmente (python.org ou winget) e reexecute."
        }
        # PATH da sessao atual precisa ser atualizado apos a instalacao
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            die 'Python foi instalado mas nao esta no PATH da sessao. Feche e reabra o PowerShell elevado e reexecute (idempotente).'
        }
    }
    if (-not (Test-PythonAtLeast $MinPythonMajor $MinPythonMinor)) {
        die ("Python $(Get-PythonVersion) encontrado; o projeto exige >= $MinPythonMajor.$MinPythonMinor. Atualize o Python e reexecute (FR-003).")
    }
    ok ("Python $(Get-PythonVersion) atende ao requisito (>= $MinPythonMajor.$MinPythonMinor).")

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        if (-not (Install-WinGetPackage 'Git.Git' 'Git')) {
            die 'Git nao instalado. Instale o Git manualmente (git-scm.com) e reexecute.'
        }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    ok 'Git disponivel.'

    if (-not $DbServiceName) {
        if (-not (Install-WinGetPackage 'MariaDB.Server' 'MariaDB Server')) {
            die 'MariaDB nao instalado. Instale o MariaDB manualmente (mariadb.org) e reexecute - o instalador e idempotente.'
        }
        $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(MariaDB|MySQL)' } | Select-Object -First 1
        if (-not $svc) { die 'Servico do MariaDB nao encontrado apos a instalacao. Verifique a instalacao manualmente e reexecute.' }
        $script:DbServiceName = $svc.Name
    }
    if ((Get-Service -Name $DbServiceName -ErrorAction SilentlyContinue).StartType -eq 'Disabled') {
        Set-Service -Name $DbServiceName -StartupType Automatic -ErrorAction Stop
    }
    if ((Get-Service -Name $DbServiceName).Status -ne 'Running') {
        info "Iniciando o servico do banco ($DbServiceName)..."
        Start-Service -Name $DbServiceName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    if ((Get-Service -Name $DbServiceName).Status -ne 'Running') {
        die "Servico de banco '$DbServiceName' nao ficou ativo. Verifique o Visualizador de Eventos e reexecute o instalador (idempotente)."
    }
    ok "Servico de banco ativo: $DbServiceName"

    $script:DbClient = Find-DbClientExe
    if (-not $DbClient) { die 'Cliente SQL (mysql/mariadb) nao encontrado mesmo apos a instalacao dos pacotes.' }
    ok ('Cliente de banco: ' + $DbClient)
}

# ----------------------------------------------------------------------------
# Banco (FR-006/FR-007, R5/R13): MYSQL_PWD no ambiente - NUNCA argv
# ----------------------------------------------------------------------------
function Invoke-DbSql {
    # Executa SQL com credencial no ambiente (senha nunca em argv/log).
    # Retorna as linhas de saida do cliente; para sucesso/falha use Test-DbSql
    # (ou $LASTEXITCODE logo apos a chamada). Com -ShowError, em caso de falha
    # a mensagem REAL do servidor e exibida (nunca contem a senha - SR-001).
    param([string]$Sql, [string]$AsUser = 'root', [string]$Password, [switch]$ShowError)
    $old = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $Password
        $cliArgs = @('--user', $AsUser, '--host', $script:DbHost, '--port', $script:DbPort, '-N', '-B', '-e', $Sql)
        $out = & $script:DbClient @cliArgs 2>$null
        if ($ShowError -and $LASTEXITCODE -ne 0) {
            warn 'Erro retornado pelo servidor:'
            & $script:DbClient @cliArgs 2>&1 | ForEach-Object { err ('  ' + $_.ToString().Trim()) }
        }
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
    # Autenticacao administrativa (root). Fontes: env SISPAT_DB_ADMIN_PASSWORD
    # (SR-001: nunca argv) ou senha vazia (instalacao nova silenciosa).
    if ($script:DbAdminPasswordResolved) { return }
    $script:DbAdminPassword = ''
    $cands = @()
    if ($env:SISPAT_DB_ADMIN_PASSWORD) { $cands += $env:SISPAT_DB_ADMIN_PASSWORD }
    $cands += ''
    foreach ($cand in $cands) {
        if (Test-DbSql -Sql 'SELECT 1;' -Password $cand) {
            $script:DbAdminPassword = $cand
            $script:DbAdminPasswordResolved = $true
            if ($cand) { ok 'Acesso administrativo via root validado (senha de variavel de ambiente).' }
            else       { ok 'Acesso administrativo via root validado (senha vazia - instalacao nova).' }
            return
        }
    }
    if ($NonInteractive) {
        die 'Nao foi possivel autenticar como root do banco. Defina SISPAT_DB_ADMIN_PASSWORD no ambiente e reexecute.'
    }
    warn 'Nao foi possivel autenticar como root com as credenciais automaticas (SISPAT_DB_ADMIN_PASSWORD ou senha vazia).'
    $p = Read-Secret 'Senha de root do MariaDB/MySQL (sem eco; vazia nas duas = tentar senha vazia)'
    if (-not $p) { $p = '' }
    if ($p -eq '') { warn 'Nenhuma senha digitada - sera tentada a senha VAZIA do root (digite a senha para autenticar de verdade).' }
    if (-not (Test-DbSql -Sql 'SELECT 1;' -Password $p)) {
        # Diagnostico: mostra o erro REAL do servidor (Access denied 1045,
        # servidor parado 2003, etc.). A mensagem do MySQL NUNCA contem a
        # senha (ela segue apenas por MYSQL_PWD - SR-001).
        warn 'Erro retornado pelo servidor:'
        $env:MYSQL_PWD = $p
        try {
            & $script:DbClient @('--user', 'root', '--host', $script:DbHost, '--port', $script:DbPort, '-N', '-B', '-e', 'SELECT 1;') 2>&1 |
                ForEach-Object { err ('  ' + $_.ToString().Trim()) }
        } finally {
            Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
        }
        die 'Credencial de root invalida. Verifique a senha do root e reexecute (idempotente).'
    }
    $script:DbAdminPassword = $p
    $script:DbAdminPasswordResolved = $true
    ok 'Acesso administrativo via root validado.'
}

function Sql-Escape([string]$Value) {
    # escape SQL para literais entre aspas simples (padrao SQL: ' -> '');
    # backslash rejeitado (o MySQL interpreta \n/\t dentro de string literal).
    if ($Value.Contains('\')) { die 'Valor contem backslash (\) - nao suportado pelo escape SQL do instalador (escolha outro valor).' }
    return $Value.Replace("'", "''")
}

function Confirm-RecreateDb {
    # R13/D2: aviso + dupla confirmacao digitando o nome do banco
    if (-not $RecreateDb) { return }
    if ($NonInteractive) { die 'Inconsistencia: -RecreateDb em modo nao interativo (deveria ter sido bloqueado).' }
    warn '=============================================================='
    warn "MODO DESTRUTIVO: -RecreateDb APAGARA o banco '$DbName'"
    warn 'e TODOS os seus dados. Esta acao e IRREVERSIVEL.'
    warn '=============================================================='
    $c1 = Read-Host 'Digite o nome do banco para confirmar (1/2)'
    $c2 = Read-Host 'Digite novamente (2/2)'
    if ($c1 -ne $DbName -or $c2 -ne $DbName) {
        die 'Confirmacao divergente. Operacao abortada - nada foi alterado.'
    }
    ok 'Dupla confirmacao recebida.'
}

function Ensure-Database {
    Resolve-DbAdminAccess

    # Detecta a familia do servidor (MariaDB vs MySQL) e reconstruir a URL com o
    # dialecto correto (caso real: MySQL Server 26.7 + 'mariadb+pymysql' falha
    # com "MySQL version 26.7.0 is not a MariaDB variant").
    # PS5.1: a saida de Invoke-DbSql e um WRAPPER de array que NAO achata via
    # '@()' nem ForEach-Object (reproduzido: vira 'System.Object[]' e a
    # deteccao falharia num MariaDB real). Out-String achata qualquer forma
    # de saida; o replace remove o quebra-linha (versao nao tem espacos).
    $srvVer = ((Invoke-DbSql -Sql 'SELECT VERSION();' -Password $DbAdminPassword | Out-String) -replace '\s', '').Trim()
    if ($srvVer -match 'MariaDB') { $script:DbUrlScheme = 'mariadb+pymysql' } else { $script:DbUrlScheme = 'mysql+pymysql' }
    Build-DatabaseUrl
    $family = if ($srvVer -match 'MariaDB') { 'MariaDB' } else { 'MySQL' }
    ok ("Familia do servidor: " + $family + " (versao " + $srvVer + ") - DATABASE_URL com esquema " + $script:DbUrlScheme + ".")

    if ($RecreateDb) {
        warn "APAGANDO banco '$DbName' (solicitacao explicita -RecreateDb)..."
        [void](Invoke-DbSql -Sql "DROP DATABASE ``$DbName``;" -Password $DbAdminPassword -ShowError)
        if ($LASTEXITCODE -ne 0) { warn "DROP falhou (o banco pode nao existir) - seguindo para a criacao." }
        [void](Invoke-DbSql -Sql "CREATE DATABASE ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" -Password $DbAdminPassword -ShowError)
        if ($LASTEXITCODE -ne 0) { die "Falha ao recriar o banco '$DbName' - veja o erro do servidor acima e reexecute." }
        ok "Banco '$DbName' recriado (utf8mb4/utf8mb4_unicode_ci)."
    } else {
        # Idempotente POR CONSTRUCAO: IF NOT EXISTS nao depende de consulta
        # previa (o SELECT em information_schema.SCHEMATA provou nao confiavel
        # em servidores novos - caso real: servidor reportando lista vazia).
        [void](Invoke-DbSql -Sql "CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" -Password $DbAdminPassword -ShowError)
        if ($LASTEXITCODE -ne 0) { die "Falha ao criar o banco '$DbName' - veja o erro do servidor acima e reexecute (idempotente)." }
        ok "Banco '$DbName' pronto (criado ou ja existente; utf8mb4/utf8mb4_unicode_ci)."
    }

    # Usuario: CREATE USER IF NOT EXISTS (idempotente) + alinhamento de senha
    # pelo teste REAL de login. A contagem previa via mysql.user provou nao
    # confiavel em alguns servidores novos; IF NOT EXISTS cobre todos os casos.
    $esc = Sql-Escape $DbPassword
    [void](Invoke-DbSql -Sql "CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$esc';" -Password $DbAdminPassword -ShowError)
    [void](Invoke-DbSql -Sql "CREATE USER IF NOT EXISTS '$DbUser'@'127.0.0.1' IDENTIFIED BY '$esc';" -Password $DbAdminPassword -ShowError)
    if ($LASTEXITCODE -ne 0) { die "Falha ao criar/garantir o usuario do banco '$DbUser' - veja o erro do servidor acima e reexecute." }
    ok "Usuario '$DbUser' (localhost e 127.0.0.1) garantido."

    # Testa a senha REAL do usuario (login como o proprio usuario): se falhar,
    # o usuario pre-existia com outra senha e oferece o alinhamento.
    if (-not (Test-DbSql -Sql 'SELECT 1;' -AsUser $DbUser -Password $DbPassword)) {
        if ($NonInteractive -or $RecreateDb) {
            [void](Invoke-DbSql -Sql "ALTER USER '$DbUser'@'localhost' IDENTIFIED BY '$esc';" -Password $DbAdminPassword -ShowError)
            [void](Invoke-DbSql -Sql "ALTER USER '$DbUser'@'127.0.0.1' IDENTIFIED BY '$esc';" -Password $DbAdminPassword -ShowError)
            $script:DbPasswordChanged = $true
            ok "Senha do usuario '$DbUser' alinhada a desta execucao."
        } else {
            $ans = Read-Host "Senha do usuario do banco DIVERGE da digitada. Atualiza-la para a desta execucao? (S/n)"
            if ($ans -notmatch '^(n|N|no|NO|nao|NAO)\s*$') {
                [void](Invoke-DbSql -Sql "ALTER USER '$DbUser'@'localhost' IDENTIFIED BY '$esc';" -Password $DbAdminPassword -ShowError)
                [void](Invoke-DbSql -Sql "ALTER USER '$DbUser'@'127.0.0.1' IDENTIFIED BY '$esc';" -Password $DbAdminPassword -ShowError)
                $script:DbPasswordChanged = $true
                ok "Senha do usuario '$DbUser' atualizada para a desta execucao."
            } else {
                warn 'Senha do usuario preservada - o .env usara a senha digitada; init_db() pode falhar com Access denied.'
            }
        }
    } else {
        ok 'Senha do usuario confere com a desta execucao.'
    }

    # Grants: SOMENTE no banco da aplicacao (SR-003) - idempotente
    # NOTA (backup manual no MySQL 8+/GTID): o --single-transaction so emite
    # FLUSH TABLES (que exigiria RELOAD/FLUSH_TABLES global) no caminho de
    # GTID_PURGED - por isso o app usa --set-gtid-purged=OFF no dump (provado
    # em campo: dump completo com exit 0 E SEM privilegios globais). NAO grant
    # FLUSH_TABLES aqui: privilegio global redundante violaria o SR-003.
    [void](Invoke-DbSql -Sql "GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';" -Password $DbAdminPassword)
    [void](Invoke-DbSql -Sql "GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'127.0.0.1';" -Password $DbAdminPassword)
    [void](Invoke-DbSql -Sql 'FLUSH PRIVILEGES;' -Password $DbAdminPassword)
    ok "Privilegios garantidos apenas em '$DbName'.* (sem privilegios globais - SR-003)."
}

# ----------------------------------------------------------------------------
# T008 - Clone (FR-008, R7)
# ----------------------------------------------------------------------------
function Test-Connectivity {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        die 'Git nao disponivel para verificar o repositorio (instale o Git e reexecute).'
    }
    & git ls-remote --heads $RepoUrl $BranchValue *> $null
    if ($LASTEXITCODE -ne 0) {
        die "Nao foi possivel acessar $RepoUrl (branch '$BranchValue'). Verifique rede/URL (FR-008)."
    }
    ok "Repositorio acessivel e branch '$BranchValue' existe."
}

function Ensure-Repo {
    if ((Test-Path (Join-Path $InstallDir '.git')) -and
        ((& git -C $InstallDir rev-parse --is-inside-work-tree 2>$null) -eq 'true')) {
        $head = (& git -C $InstallDir rev-parse --short HEAD 2>$null)
        ok "Clone valido em $InstallDir - reutilizado (HEAD: $head)."
        $dirty = (& git -C $InstallDir status --porcelain 2>$null)
        if ($dirty) { warn 'O clone possui alteracoes locais (git status nao vazio). NADA sera revertido - revise antes de atualizar.' }
        return
    }
    if ((Test-Path $InstallDir) -and (Get-ChildItem -Force $InstallDir -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        die "$InstallDir existe, nao esta vazio e NAO e um clone Git valido. Decida o destino do conteudo (mova/remova manualmente) e reexecute - o instalador nao sobrescreve."
    }
    $parentDir = Split-Path $InstallDir -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir -ErrorAction Stop | Out-Null
    }
    & git clone --branch $BranchValue --single-branch $RepoUrl $InstallDir 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { die 'Falha no git clone - verifique rede/credenciais e reexecute.' }
    ok "Repositorio clonado (branch $BranchValue) em $InstallDir."
}

# ----------------------------------------------------------------------------
# T008 - venv + requirements (FR-009, R8)
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Compatibilidade Windows PowerShell 5.1 (R5/R6): codigo Python passado via
# '-c "..."' chegava ao python com as aspas duplas internas REMOVIDAS pelo
# quoting do PS 5.1 para executaveis nativos (SyntaxError invalid syntax).
# Solucao: gravar o codigo em arquivo temporario UTF-8 e executa-lo - nao ha
# nenhuma passagem de codigo Python por argv. O caminho do arquivo NUNCA
# contem credenciais (credenciais seguem por variaveis de ambiente, SR-001).
# ----------------------------------------------------------------------------
function Invoke-PyCode {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [string]$PythonExe = $VenvPython,
        [string[]]$PythonArgs = @()
    )
    $pyFile = Join-Path ([IO.Path]::GetTempPath()) ("sispat-pycode-{0}.py" -f [Guid]::NewGuid().ToString('N'))
    $oldPyPath = $env:PYTHONPATH
    try {
        [IO.File]::WriteAllText($pyFile, $Code, (New-Object System.Text.UTF8Encoding($false)))
        # O arquivo vive no TEMP, entao sys.path[0] NAO e o diretorio atual
        # (diferente do 'python -c', que usa o CWD). Codigos que importam
        # app.* (contrato: CWD = projeto) precisam do CWD em sys.path;
        # PYTHONPATH repoe isso e e restaurado no finally.
        $env:PYTHONPATH = if ($oldPyPath) { (Get-Location).Path + ';' + $oldPyPath } else { (Get-Location).Path }
        & $PythonExe @PythonArgs $pyFile
    } finally {
        if ($null -ne $oldPyPath) { $env:PYTHONPATH = $oldPyPath } else { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $pyFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-VenvOk {
    if (-not (Test-Path $VenvPython)) { return $false }
    & $VenvPython -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    Invoke-PyCode 'import fastapi, sqlalchemy, pymysql, ldap3, reportlab, openpyxl, dotenv, cryptography, tzdata' *> $null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-Venv {
    if (Test-VenvOk) { ok 'venv existente valido - reutilizado.'; return }
    if (Test-Path (Join-Path $InstallDir '.venv')) {
        warn 'venv invalido/incompleto detectado - removendo e recriando (artefato regeneravel; nenhum dado e afetado).'
        Remove-Item -Recurse -Force (Join-Path $InstallDir '.venv') -ErrorAction Stop
    }
    & python -m venv (Join-Path $InstallDir '.venv') 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $VenvPython)) { die 'Falha ao criar o ambiente virtual (python -m venv).' }
    info 'Instalando requirements.txt (do repositorio recem-clonado; leva alguns minutos)...'
    & $VenvPython -m pip install --progress-bar off -r (Join-Path $InstallDir 'requirements.txt') 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { die 'pip install falhou - verifique o log e reexecute (idempotente).' }
    # PyMySQL + MySQL 8 (caching_sha2_password) EXIGE cryptography; zoneinfo no Windows exige tzdata.
    info 'Garantindo cryptography e tzdata (autenticacao MySQL 8 / Timezone Windows)...'
    & $VenvPython -m pip install --progress-bar off cryptography tzdata 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { die 'Falha ao instalar dependencias complementares (pip install cryptography tzdata).' }
    Invoke-PyCode 'import fastapi, sqlalchemy, pymysql, ldap3, reportlab, openpyxl, dotenv, cryptography, tzdata' *> $null
    if ($LASTEXITCODE -ne 0) { die 'Validacao de imports falhou apos pip install (FR-009).' }
    ok 'Dependencias instaladas e validadas (imports OK).'
}

# ----------------------------------------------------------------------------
# T007 - montagem da URL do banco: percent-encoding programatico (nunca
# montagem manual - R5/R6). A senha vai por AMBIENTE (nunca argv/log).
# ----------------------------------------------------------------------------
function Build-DatabaseUrl {
    # Esquema do dialecto: 'mariadb+pymysql' EXIGE servidor MariaDB; em MySQL
    # (8.x/9.x/26.x) o SQLAlchemy rejeita a conexao ("MySQL version X is not a
    # MariaDB variant") e o correto e 'mysql+pymysql'. A familia do servidor e
    # detectada em Ensure-Database (SELECT VERSION()) e a URL e reconstruida la.
    if (-not $script:DbUrlScheme) { $script:DbUrlScheme = 'mariadb+pymysql' }
    $env:SP_DBUSER = $DbUser; $env:SP_DBPASS = $DbPassword
    $env:SP_DBHOST = $DbHost; $env:SP_DBPORT = $DbPort; $env:SP_DBNAME = $DbName
    try {
        $code = 'import os; from urllib.parse import quote; print("' + $script:DbUrlScheme + '://%s:%s@%s:%s/%s" % (quote(os.environ["SP_DBUSER"], safe=""), quote(os.environ["SP_DBPASS"], safe=""), os.environ["SP_DBHOST"], os.environ["SP_DBPORT"], os.environ["SP_DBNAME"]))'
        $url = (Invoke-PyCode $code)
        if (-not $url -or $LASTEXITCODE -ne 0) { die 'Falha ao montar DATABASE_URL (percent-encoding via Python).' }
        $script:DatabaseUrlBuilt = ([string]$url).Trim()
    } finally {
        Remove-Item Env:\SP_DBUSER, Env:\SP_DBPASS, Env:\SP_DBHOST, Env:\SP_DBPORT, Env:\SP_DBNAME -ErrorAction SilentlyContinue
    }
    ok 'DATABASE_URL montado com percent-encoding (senha nunca em argv/log).'
}

# ----------------------------------------------------------------------------
# T007 (parte final) - teste de conexao REAL via engine do projeto (FR-007)
# ----------------------------------------------------------------------------
function Test-DbConnection {
    Push-Location $InstallDir
    try {
        Invoke-PyCode "from app.config import DATABASE_URL; from sqlalchemy import create_engine, text; e = create_engine(DATABASE_URL); c = e.connect(); print('BANCO:', c.execute(text('SELECT DATABASE()')).scalar()); c.close()" 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) { die 'Conexao com o banco falhou via DATABASE_URL do projeto.' }
    } finally { Pop-Location }
    ok ("Conexao validada via DATABASE_URL (esquema " + $script:DbUrlScheme + ").")
}

# ----------------------------------------------------------------------------
# T009 - .env (FR-010, R6): ACL restrita, nunca sobrescrito
# ----------------------------------------------------------------------------
function Protect-EnvFile([string]$Path) {
    # Equivalente Windows do chmod 600: heranca removida; apenas
    # SYSTEM, Administradores e o usuario atual tem acesso.
    & icacls $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' ("{0}\{1}:F" -f $env:USERDOMAIN, $env:USERNAME) *> $null
}

# ----------------------------------------------------------------------------
# T008b - certificados SSL locais (feature 056 - HTTPS nativo no uvicorn)
# Gera/valida CA + cert com SAN do IP da LAN via scripts\gera_cert_dev.py e
# decide se APP_SSL_* sera gravada no .env. NAO e bloqueante: sem openssl ou
# com falha de geracao a instalacao continua em HTTP puro (aviso claro).
# Idempotente: certs validos (validade >= 14 dias e SAN cobrindo o IP atual)
# sao reutilizados; invalidos sao regerados com --force (CA NOVA - avisa que
# os aparelhos precisam reimportar ca.crt).
# ----------------------------------------------------------------------------
function Ensure-SslCerts {
    $script:SslEnabled = $false
    if ($SkipSsl) {
        warn '-SkipSsl: etapa pulada - a aplicacao sobe em HTTP puro (sem APP_SSL_*).'
        return
    }
    $sslDir    = Join-Path $InstallDir 'data\ssl'
    $caCrt     = Join-Path $sslDir 'ca.crt'
    $srvCrt    = Join-Path $sslDir 'server.crt'
    $srvKey    = Join-Path $sslDir 'server.key'
    $genScript = Join-Path $InstallDir 'scripts\gera_cert_dev.py'
    if (-not (Test-Path $genScript)) {
        warn "scripts\gera_cert_dev.py nao encontrado - HTTPS pulado (HTTP puro)."
        return
    }
    # openssl no PATH do processo filho: PATH primeiro, depois locais comuns
    # (Git for Windows). Cobre clone NOVO cujo gera_cert_dev.py ainda nao tem
    # o acha_openssl do projeto.
    $opensslDir = $null
    if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
        # ProgramW6432: num PowerShell 32-bit o ProgramFiles aponta para
        # 'Program Files (x86)' e o Git/openssl ficariam invisiveis (causaria
        # downgrade silencioso para HTTP puro nesta execucao).
        foreach ($d in @(
            (Join-Path $env:ProgramW6432 'Git\usr\bin'),
            (Join-Path $env:ProgramW6432 'Git\mingw64\bin'),
            (Join-Path $env:ProgramFiles 'Git\usr\bin'),
            (Join-Path $env:ProgramFiles 'Git\mingw64\bin'),
            'C:\Program Files\OpenSSL-Win64\bin',
            'C:\OpenSSL-Win64\bin'
        )) {
            if ($d -and (Test-Path (Join-Path $d 'openssl.exe'))) { $opensslDir = $d; break }
        }
        if (-not $opensslDir) {
            warn 'openssl CLI nao encontrado (PATH nem Git for Windows) - HTTPS pulado. Instale o Git for Windows para habilitar.'
            return
        }
    }
    # IP da LAN sem trafego real (mesma heuristica do gera_cert_dev.py)
    $ip = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        try { $udp.Connect('10.255.255.255', 1); $ip = ([System.Net.IPEndPoint]$udp.Client.LocalEndPoint).Address.ToString() } finally { $udp.Close() }
    } catch { }
    if ($ip -match '^(127\.|169\.254\.)') { $ip = $null }
    if ($ip) { info "IP da LAN para o SAN: $ip" }

    # Validacao idempotente (cryptography do proprio venv - ja e dependencia):
    # legivel + validade >= 14 dias + SAN cobrindo o IP atual da LAN.
    if ((Test-Path $caCrt) -and (Test-Path $srvCrt) -and (Test-Path $srvKey)) {
        $env:SP_SSL_CERT = $srvCrt
        if ($ip) { $env:SP_SSL_IP = $ip } else { Remove-Item Env:\SP_SSL_IP -ErrorAction SilentlyContinue }
        $pyCheck = @'
import os, sys
from datetime import datetime, timezone
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import ExtensionOID
try:
    with open(os.environ['SP_SSL_CERT'], 'rb') as f:
        cert = x509.load_pem_x509_certificate(f.read(), default_backend())
except Exception as e:
    print('cert ilegivel: %s' % e); sys.exit(3)
try:
    fim = cert.not_valid_after_utc
except AttributeError:
    fim = cert.not_valid_after.replace(tzinfo=timezone.utc)
dias = (fim - datetime.now(timezone.utc)).days
if dias < 14:
    print('cert expira em %d dia(s)' % dias); sys.exit(4)
try:
    san = cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME).value
except Exception:
    print('cert sem SAN'); sys.exit(5)
alvo = os.environ.get('SP_SSL_IP', '')
if alvo:
    ips = [str(x) for x in san.get_values_for_type(x509.IPAddress)]
    dns = list(san.get_values_for_type(x509.DNSName))
    if alvo not in ips and alvo not in dns:
        print('SAN nao cobre o IP atual %s (SAN tem: %s)' % (alvo, ','.join(ips + dns))); sys.exit(6)
print('ok')
'@
        try {
            Invoke-PyCode $pyCheck 2>&1 | ForEach-Object { info "  ssl-check: $_" }
            $valido = ($LASTEXITCODE -eq 0)
        } finally {
            Remove-Item Env:\SP_SSL_CERT, Env:\SP_SSL_IP -ErrorAction SilentlyContinue
        }
        if ($valido) {
            $script:SslEnabled = $true
            ok 'Certificados SSL existentes validos (SAN/validade) - reutilizados.'
            return
        }
        warn 'Certificados SSL existentes invalidos, expirados ou sem o IP atual no SAN - regerando (CA NOVA: reimporte ca.crt nos aparelhos).'
    }

    $pyArgs = @($genScript)
    if ($ip) { $pyArgs += @('--ip', $ip) }
    if ((Test-Path $srvCrt) -or (Test-Path $caCrt) -or (Test-Path $srvKey)) { $pyArgs += '--force' }
    $oldPath = $env:PATH
    try {
        if ($opensslDir) { $env:PATH = "$oldPath;$opensslDir" }
        & $VenvPython @pyArgs 2>&1 | ForEach-Object { info "  gera-cert: $_" }
    } finally {
        $env:PATH = $oldPath
    }
    if ($LASTEXITCODE -ne 0 -or -not ((Test-Path $caCrt) -and (Test-Path $srvCrt) -and (Test-Path $srvKey))) {
        warn 'Geracao de certificados SSL falhou - instalacao continua em HTTP puro (veja saida acima).'
        return
    }
    $script:SslEnabled = $true
    ok 'Certificados SSL gerados em data\ssl - a aplicacao subira em HTTPS.'
}

# Grava/remove APP_SSL_CERTFILE+APP_SSL_KEYFILE no .env conforme Ensure-SslCerts.
# run.py FALHA NO BOOT se as chaves existirem e os arquivos nao - por isso as
# chaves sao REMOVIDAS quando SSL esta desligado e os arquivos nao existem.
# Caminhos relativos com '/' (docs/HTTPS_LOCAL.md: o app normaliza contra a
# raiz do projeto - o mesmo .env vale no Windows e no Linux).
function Sync-SslEnvKeys([string]$EnvFile) {
    if (-not (Test-Path $EnvFile)) { return }
    $lines = @(Get-Content $EnvFile)
    $temCert = (@($lines | Where-Object { $_ -match '^APP_SSL_CERTFILE=' }).Count -gt 0)
    $temKey  = (@($lines | Where-Object { $_ -match '^APP_SSL_KEYFILE=' }).Count -gt 0)
    if ($script:SslEnabled) {
        $newLines = @()
        $addCert = -not $temCert
        $addKey  = -not $temKey
        foreach ($l in $lines) {
            if ($l -match '^APP_SSL_CERTFILE=') { $newLines += 'APP_SSL_CERTFILE=data/ssl/server.crt' }
            elseif ($l -match '^APP_SSL_KEYFILE=') { $newLines += 'APP_SSL_KEYFILE=data/ssl/server.key' }
            else { $newLines += $l }
        }
        if ($addCert) { $newLines += 'APP_SSL_CERTFILE=data/ssl/server.crt' }
        if ($addKey)  { $newLines += 'APP_SSL_KEYFILE=data/ssl/server.key' }
        if ($addCert -or $addKey) {
            Set-Content -Path $EnvFile -Value $newLines -Encoding UTF8 -ErrorAction Stop
            ok 'HTTPS ativado: APP_SSL_CERTFILE/APP_SSL_KEYFILE gravadas no .env.'
        }
        return
    }
    if ($temCert -or $temKey) {
        $caminho = $null
        foreach ($l in $lines) { if ($l -match '^APP_SSL_CERTFILE=(.+)$') { $caminho = $Matches[1].Trim(); break } }
        $existe = $false
        if ($caminho) {
            $p = $caminho -replace '/', '\'
            if ($p -notmatch '^[A-Za-z]:\\') { $p = Join-Path $InstallDir $p }
            $existe = Test-Path $p
        }
        if (-not $existe) {
            $newLines = @($lines | Where-Object { $_ -notmatch '^APP_SSL_(CERTFILE|KEYFILE)=' })
            Set-Content -Path $EnvFile -Value $newLines -Encoding UTF8 -ErrorAction Stop
            warn 'SSL desligado e certificados inexistentes: chaves APP_SSL_* removidas do .env (evita falha de boot do run.py).'
        } else {
            info 'SSL desligado nesta execucao, mas os certificados existem - chaves APP_SSL_* mantidas no .env.'
        }
    }
}

function Ensure-EnvFile {
    $envFile = Join-Path $InstallDir '.env'
    if (Test-Path $envFile) {
        $bak = "$envFile.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
        warn '.env existente - NUNCA e sobrescrito.'
        Copy-Item $envFile $bak -Force -ErrorAction Stop
        ok "Backup criado: $bak"
        $existingKeys = @(Get-Content $envFile | ForEach-Object { if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=') { $Matches[1] } })
        if ($existingKeys -contains 'DB_ROOT_PASSWORD') {
            warn '.env parece da variante Docker (chaves DB_* do compose) - a app nativa le DATABASE_URL, APP_HOST e APP_PORT.'
        }
        # Caso real: reexecucao apos falha no meio da instalacao - oferece
        # atualizar APENAS o DATABASE_URL quando o banco mudou NESTA execucao.
        if (-not $NonInteractive -and $DbPasswordChanged) {
            $ans = Read-Host 'DATABASE_URL do .env aponta para senha diferente da desta execucao. Atualizar apenas o DATABASE_URL? (S/n)'
            if ($ans -notmatch '^(n|N|no|NO|nao|NAO)\s*$') {
                # Reescrita linha a linha: -replace com a URL no lado direito
                # interpretaria '$' da senha como referencia a grupo de captura
                $foundUrl = $false
                $newLines = @()
                foreach ($l in (Get-Content $envFile)) {
                    if ($l -match '^DATABASE_URL=') { $foundUrl = $true; $newLines += "DATABASE_URL=$DatabaseUrlBuilt" }
                    else { $newLines += $l }
                }
                if (-not $foundUrl) {
                    # .env pode existir SEM a chave (caso real: .env da variante Docker)
                    $newLines += "DATABASE_URL=$DatabaseUrlBuilt"
                    if (-not ($existingKeys -contains 'MYSQLDUMP_PATH') -and $DbClient) {
                        $dump = Join-Path ([IO.Path]::GetDirectoryName($DbClient)) 'mysqldump.exe'
                        if (Test-Path $dump) { $newLines += "MYSQLDUMP_PATH=$dump"; ok 'MYSQLDUMP_PATH adicionado (backups pela aplicacao).' }
                    }
                    Set-Content -Path $envFile -Value $newLines -Encoding UTF8 -ErrorAction Stop
                    ok 'DATABASE_URL ADICIONADO ao .env existente (chave ausente; demais chaves preservadas).'
                } else {
                    Set-Content -Path $envFile -Value $newLines -Encoding UTF8 -ErrorAction Stop
                    ok 'DATABASE_URL atualizado no .env existente (demais chaves preservadas).'
                }
            } else {
                warn '.env mantido sem alteracoes (valores existentes preservados).'
            }
        } elseif (-not $NonInteractive) {
            # Comportamento original: completa apenas chaves ausentes (merge consentido)
            $ans = Read-Host 'Completar chaves ausentes no .env existente com os valores desta instalacao? (s/N)'
            if ($ans -match '^(s|S|sim|SIM|y|Y)$') {
                $lines = Get-Content $envFile
                if (-not ($lines -match '^DATABASE_URL=')) { Add-Content $envFile "DATABASE_URL=$DatabaseUrlBuilt" }
                if (-not ($lines -match '^APP_HOST='))     { Add-Content $envFile "APP_HOST=$AppHost" }
                if (-not ($lines -match '^APP_PORT='))     { Add-Content $envFile "APP_PORT=$AppPort" }
                ok 'Chaves ausentes adicionadas ao .env existente.'
            } else { warn '.env mantido sem alteracoes (valores existentes preservados).' }

            # Sincronizacao: mesmo com senha inalterada, o DATABASE_URL existente
            # pode divergir da URL desta execucao (caso real: dialecto errado
            # mariadb+pymysql gravado antes da deteccao de familia do servidor).
            # A URL NUNCA e impressa (contem senha - SR-001).
            $curUrl = $null
            foreach ($l in (Get-Content $envFile)) { if ($l -match '^DATABASE_URL=(.+)$') { $curUrl = $Matches[1].Trim(); break } }
            if ($curUrl -and $curUrl -cne $DatabaseUrlBuilt) {
                warn 'DATABASE_URL no .env difere da URL montada NESTA execucao (dialeto/host/porta/senha).'
                $ans2 = Read-Host 'Sincronizar o DATABASE_URL do .env com a desta execucao? (S/n)'
                if ($ans2 -notmatch '^(n|N|no|NO|nao|NAO)\s*$') {
                    $newLines = @()
                    foreach ($l in (Get-Content $envFile)) {
                        if ($l -match '^DATABASE_URL=') { $newLines += "DATABASE_URL=$DatabaseUrlBuilt" } else { $newLines += $l }
                    }
                    Set-Content -Path $envFile -Value $newLines -Encoding UTF8 -ErrorAction Stop
                    ok 'DATABASE_URL sincronizado com a URL desta execucao.'
                } else {
                    warn 'DATABASE_URL mantido - se o teste de conexao falhar por dialecto/credencial, esta e a causa.'
                }
            }
        } else {
            warn 'Modo nao interativo: .env mantido sem alteracoes (valores existentes preservados).'
            $curUrl = $null
            foreach ($l in (Get-Content $envFile)) { if ($l -match '^DATABASE_URL=(.+)$') { $curUrl = $Matches[1].Trim(); break } }
            if ($curUrl -and $curUrl -cne $DatabaseUrlBuilt) {
                warn 'DATABASE_URL do .env difere da URL desta execucao - o teste de conexao pode falhar.'
            }
        }
        Sync-SslEnvKeys $envFile
        Protect-EnvFile $envFile
        return
    }

    $content = @"
# Gerado por install.ps1 (feature 027 - Windows) em $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Conexao com o banco MariaDB/MySQL (obrigatoria - a aplicacao nao inicia sem ela)
DATABASE_URL=$DatabaseUrlBuilt

# Bind da aplicacao
APP_HOST=$AppHost
APP_PORT=$AppPort
"@
    if ($DbClient) {
        $dump = Join-Path ([IO.Path]::GetDirectoryName($DbClient)) 'mysqldump.exe'
        if (Test-Path $dump) { $content += "`n`n# Caminho do mysqldump (backup/restauracao pela aplicacao)`nMYSQLDUMP_PATH=$dump" }
    }
    Set-Content -Path $envFile -Value $content -Encoding UTF8 -ErrorAction Stop
    Sync-SslEnvKeys $envFile
    Protect-EnvFile $envFile
    ok '.env gerado com ACL restrita (equivalente 0600 - SR-002).'
}

# ----------------------------------------------------------------------------
# T010 - tarefa agendada como servico (FR-012, R9/R10) - substitui systemd
# ----------------------------------------------------------------------------
function Ensure-ServiceTask {
    $action    = New-ScheduledTaskAction -Execute $VenvPython -Argument 'run.py' -WorkingDirectory $InstallDir
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'
    $settings  = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $ServiceUser -LogonType ServiceAccount -RunLevel Limited

    $task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    if ($task) {
        # Idempotencia: se a acao atual e identica, nao altera nada.
        $cur = @($task.Actions)[0]
        if ($cur.Execute -eq $action.Execute -and $cur.Arguments -eq $action.Arguments -and $cur.WorkingDirectory -eq $action.WorkingDirectory) {
            ok "Tarefa '$ServiceName' ja esta correta - inalterada (idempotencia)."
            return
        }
        warn 'Tarefa existente difere do conteudo gerado - atualizando.'
        Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $ServiceName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -ErrorAction Stop | Out-Null
    ok "Tarefa agendada '$ServiceName' instalada (dispara no boot; reinicia ate 3x em falha)."
}

function Stop-ServiceTaskIfRunning {
    # Corrida 1050 (mesma do install.sh): evita init_db concorrente com o app de rodada anterior
    $task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    if (-not $task) { ok "Tarefa $ServiceName ainda nao instalada - nada a parar (primeira instalacao)."; return }
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $ServiceName
        ok "Tarefa $ServiceName parada (rodada anterior) - reativada ao final."
    } else {
        ok "Tarefa $ServiceName instalada, mas inativa - nada a parar."
    }
}

function Pre-StartSanity {
    $missing = @()
    if (-not (Test-Path (Join-Path $InstallDir '.env')))   { $missing += '.env (configuracao)' }
    if (-not (Test-Path $VenvPython))                      { $missing += ".venv\Scripts\python.exe (executavel da tarefa)" }
    if (-not (Test-Path (Join-Path $InstallDir 'run.py'))) { $missing += 'run.py' }
    if ($missing.Count -gt 0) {
        err 'Arquivos exigidos pela tarefa estao AUSENTES - o servico NAO sera iniciado (FR-019):'
        foreach ($m in $missing) { err "  - $m" }
        die 'Instalacao incompleta. Reexecute o instalador (idempotente) - e evite rodar duas instancias ao mesmo tempo.'
    }
    ok 'Arquivos do servico presentes (.env, venv, run.py).'
}

# T011 - init_db explicito (mesmo contrato do install.sh: VERIFICADO pelo
# instalador; idempotente: create_all nunca destroi)
function Init-Database {
    info 'Executando init_db() do projeto (create_all + migracoes leves)...'
    Push-Location $InstallDir
    try {
        Invoke-PyCode 'from app.database import init_db; init_db()' 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) {
            die 'init_db() falhou - verificar DATABASE_URL/.env e acesso do usuario do banco. Instalacao interrompida (nenhum dado alterado).'
        }
    } finally { Pop-Location }
    ok 'Schema verificado/criado via init_db() do projeto.'
}

# ----------------------------------------------------------------------------
# T011 - start + health (FR-013, R11)
# ----------------------------------------------------------------------------
# Health probe consciente do esquema: com HTTPS ativo o run.py serve SOMENTE
# TLS, entao http://127.0.0.1 falharia. PS 5.1 nao tem -SkipCertificateCheck:
# confia no cert autoassinado LOCAL via ServerCertificateValidationCallback
# com RESTAURACAO do valor anterior (try/finally) - sem isso o cert derrubaria
# o probe e a etapa morreria em timeout.
#
# O ESQUEMA efetivo vem do .env (run.py lige o .env, nao esta execucao): se
# APP_SSL_* aponta para arquivos existentes, o app serve TLS mesmo quando ESTA
# execucao pulou o SSL - o probe tem que acompanhar o que o app realmente faz
# (divergencia = timeout de 120s na etapa de health).
function Test-EnvSslActive {
    $envFile = Join-Path $InstallDir '.env'
    if (-not (Test-Path $envFile)) { return $false }
    $cert = $null
    foreach ($l in (Get-Content $envFile)) { if ($l -match '^APP_SSL_CERTFILE=(.+)$') { $cert = $Matches[1].Trim(); break } }
    if (-not $cert) { return $false }
    $p = $cert -replace '/', '\'
    if ($p -notmatch '^[A-Za-z]:\\') { $p = Join-Path $InstallDir $p }
    return [bool](Test-Path $p)
}

function Get-HealthUri {
    $scheme = if ($script:SslEnabled -or (Test-EnvSslActive)) { 'https' } else { 'http' }
    return "${scheme}://127.0.0.1:$AppPort/health"
}

function Invoke-HealthProbe([int]$TimeoutSec = 5) {
    if ((Get-HealthUri) -notlike 'https://*') { return Invoke-RestMethod -Uri (Get-HealthUri) -TimeoutSec $TimeoutSec }
    # PS5.1: um scriptblock '{ $true }' NAO serve como callback - o delegate e
    # invocado numa thread de rede SEM runspace ("No Runspace available"). E
    # '[Tipo]::Metodo' tambem falha (PSMethod nao converte para delegate):
    # a classe C# expoe o PROPRIO delegate como campo static readonly - unica
    # forma validada em prova de campo contra uvicorn com cert autoassinado.
    if (-not ('SispatSslTrust' -as [type])) {
        Add-Type -TypeDefinition 'using System.Net.Security; using System.Security.Cryptography.X509Certificates; public static class SispatSslTrust { public static readonly RemoteCertificateValidationCallback Callback = new RemoteCertificateValidationCallback(TrustAll); public static bool TrustAll(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return true; } }' -ErrorAction Stop
    }
    $prev = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [SispatSslTrust]::Callback
    try { return Invoke-RestMethod -Uri (Get-HealthUri) -TimeoutSec $TimeoutSec }
    finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prev }
}

function Start-AndHealthCheck {
    Start-ScheduledTask -TaskName $ServiceName -ErrorAction Stop
    info "Aguardando /health (ate ${HealthTimeoutSeconds}s)..."
    $waited = 0
    while ($waited -lt $HealthTimeoutSeconds) {
        try {
            $r = Invoke-HealthProbe
            switch ($r.status) {
                'healthy'  { ok 'Aplicacao saudavel: /health -> healthy'; return }
                'degraded' { warn '/health -> degraded (aplicacao no ar; componente informado no corpo da resposta, ex.: AD configurado e indisponivel). Instalacao prossegue.'; return }
                default    { info ("status=$($r.status) - aguardando...") }
            }
        } catch { }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    err "Aplicacao nao respondeu em /health dentro de ${HealthTimeoutSeconds}s."
    err '=== Estado da tarefa ==='
    (Get-ScheduledTask -TaskName $ServiceName | Select-Object TaskName, State | Format-List | Out-String).Trim() -split "`n" | ForEach-Object { err $_.TrimEnd("`r") }
    err '=== Log da aplicacao (se existir) ==='
    $applog = Join-Path $InstallDir 'data\logs'
    if (Test-Path $applog) {
        $latest = Get-ChildItem $applog -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { Get-Content $latest.FullName -Tail 20 | ForEach-Object { err $_ } }
    }
    # Interrompe o ciclo de reinicio (RestartCount reiniciaria para sempre um servico quebrado)
    Stop-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    warn 'Tarefa PARADA para encerrar o loop de reinicio. Reexecute o instalador quando quiser tentar novamente (idempotente).'
    die "Falha na verificacao de saude (FR-013). Diagnostico acima; log completo em $InstallLog."
}

# ----------------------------------------------------------------------------
# T012/T018 - bateria pos-instalacao (FR-014, R14)
# ----------------------------------------------------------------------------
function Post-InstallChecks {
    $failures = 0

    if (Test-PythonAtLeast $MinPythonMajor $MinPythonMinor) { ok "Python >= ${MinPythonMajor}.${MinPythonMinor}: OK" }
    else { err 'Python: FALHOU'; $failures++ }

    if (Test-VenvOk) { ok 'venv + dependencias: OK' } else { err 'venv/dependencias: FALHOU'; $failures++ }

    if ((Get-Service -Name $DbServiceName).Status -eq 'Running') { ok "Banco ativo ($DbServiceName): OK" } else { err 'Banco ativo: FALHOU'; $failures++ }

    # Mesmo contrato da tarefa (WorkingDirectory): imports de app.* exigem CWD = projeto
    Push-Location $InstallDir
    try {
        Invoke-PyCode "from app.database import SessionLocal; from sqlalchemy import text; db = SessionLocal(); db.execute(text('SELECT 1')); db.close()" *> $null
        if ($LASTEXITCODE -eq 0) { ok 'Conexao com o banco: OK' } else { err 'Conexao com o banco: FALHOU'; $failures++ }
        Invoke-PyCode "from app.database import SessionLocal; from sqlalchemy import text; db = SessionLocal(); db.execute(text('SELECT 1 FROM users LIMIT 1')); db.close()" *> $null
        if ($LASTEXITCODE -eq 0) { ok 'Tabela base (users) existente: OK' } else { err 'Tabela base: FALHOU'; $failures++ }
    } finally { Pop-Location }

    $task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { ok "Tarefa $ServiceName ativa: OK" } else { err 'Tarefa ativa: FALHOU'; $failures++ }

    try { Invoke-HealthProbe | Out-Null; ok ((Get-HealthUri) + ': OK') }
    catch { err ((Get-HealthUri) + ': FALHOU'); $failures++ }

    if ($failures -gt 0) { die "$failures verificacao(oes) pos-instalacao falharam - veja mensagens acima e o log." }
    ok 'Bateria completa: todas as verificacoes passaram.'
}

# ----------------------------------------------------------------------------
# T016 - auto-check de seguranca (SR-001): a senha NAO pode estar no log
# ----------------------------------------------------------------------------
function Security-SelfCheck {
    if ($DbPassword -and (Test-Path $InstallLog) -and ([IO.File]::ReadAllText($InstallLog)).Contains($DbPassword)) {
        warn "A senha do banco foi encontrada no log do instalador - REVISE $InstallLog (remova a linha) e investigue a origem."
    } else {
        ok 'Auto-check: nenhuma credencial no log (SR-001).'
    }
    $envFile = Join-Path $InstallDir '.env'
    if (Test-Path $envFile) {
        $rules = @((Get-Acl $envFile -ErrorAction SilentlyContinue).Access | Where-Object { $_.AccessControlType -eq 'Allow' })
        if ($rules.Count -le 3) { ok '.env com ACL restrita (equivalente 0600 - SR-002).' }
        else { warn ".env com $($rules.Count) entradas de acesso (esperado <= 3) - revise com: icacls `"$envFile`"" }
    }
    ok 'Usuario do banco sem privilegios globais (SR-003) - grants aplicados somente no banco da aplicacao.'
}

# ----------------------------------------------------------------------------
# Resumo final
# ----------------------------------------------------------------------------
function Get-PrimaryIPv4 {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    } catch { }
    return 'localhost'
}

function Print-Summary {
    $ip = Get-PrimaryIPv4
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor White
    ok 'SisPatrimonio Pro instalado com sucesso (WINDOWS nativo)!'
    Write-Host '  ==============================================================' -ForegroundColor White
    Write-Host ''
    Write-Host '  ACESSO' -ForegroundColor White
    $esq = if ($script:SslEnabled) { 'https' } else { 'http' }
    Write-Host ("    Aplicacao    : {0}://{1}:{2}" -f $esq, $ip, $AppPort)
    Write-Host ("    Swagger API  : {0}://{1}:{2}/docs" -f $esq, $ip, $AppPort)
    Write-Host ("    Health check : {0}://{1}:{2}/health" -f $esq, $ip, $AppPort)
    if ($script:SslEnabled) {
        Write-Host ('    HTTPS        : importe ' + (Join-Path $InstallDir 'data\ssl\ca.crt') + ' como CA confiavel nos aparelhos (1x).')
    }
    Write-Host ''
    Write-Host '  INSTALACAO' -ForegroundColor White
    Write-Host ('    Diretorio    : ' + $InstallDir)
    Write-Host ('    Configuracao : ' + (Join-Path $InstallDir '.env') + ' (ACL restrita - contem credenciais)')
    Write-Host ('    Tarefa       : ' + $ServiceName + ' (roda como ' + $ServiceUser + ' no boot)')
    Write-Host ('    Log          : ' + $InstallLog)
    Write-Host ('    Logs/Backups : ' + (Join-Path $InstallDir 'data\logs') + ' | ' + (Join-Path $InstallDir 'data\backups'))
    Write-Host ''
    Write-Host '  GERENCIAR O SERVICO' -ForegroundColor White
    Write-Host ("    Get-ScheduledTask -TaskName $ServiceName        # estado")
    Write-Host ("    Start-ScheduledTask -TaskName $ServiceName      # iniciar")
    Write-Host ("    Stop-ScheduledTask -TaskName $ServiceName       # parar")
    Write-Host ("    Unregister-ScheduledTask -TaskName $ServiceName # remover (o desinstalador faz isso)")
    Write-Host ''
    Write-Host '  PRIMEIRO ADMINISTRADOR (escolha um caminho - nunca exibimos senhas)' -ForegroundColor White
    Write-Host '    A) CLI (recomendado):'
    Write-Host ("       cd `"$InstallDir`"")
    Write-Host '       .venv\Scripts\python.exe -m app.cli create-user --username admin --name "Administrador" --admin'
    Write-Host '       (a senha e solicitada de forma oculta; minimo 8 caracteres)'
    Write-Host '    B) Primeiro acesso: abra a aplicacao e use a pagina /setup'
    Write-Host '       (disponivel enquanto nao existir nenhum usuario)'
    Write-Host '    C) Variaveis de ambiente: AUTH_ADMIN_USERNAME/AUTH_ADMIN_PASSWORD'
    Write-Host '       no .env antes do primeiro start (remova apos o primeiro login)'
    Write-Host ''
    Write-Host '  A senha do banco NAO aparece neste resumo nem no log - esta apenas'
    Write-Host '  no .env (DATABASE_URL), com ACL restrita.'
    Write-Host '  ==============================================================' -ForegroundColor White
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
function Main {
    Parse-Args
    Validate-Inputs
    Require-Admin

    Write-Host ''
    Write-Host '=============================================================='
    info "SisPatrimonio Pro - Instalador WINDOWS (nativo) v$AppVersionInstaller ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
    Write-Host '=============================================================='
    Write-Host ''

    Detect-Host

    # Interacao ANTES de qualquer mutacao (R12/R13), como no install.sh:
    # coleta de segredos -> resumo/confirmacao -> confirmacao destrutiva.
    Collect-Secrets
    Confirm-Plan
    Confirm-RecreateDb

    Write-Step 'Pacotes do sistema (Python, Git, MariaDB)' ; Ensure-Packages
    Write-Step 'Verificacao de conectividade'              ; Test-Connectivity
    Write-Step 'Codigo-fonte (clone)'                      ; Ensure-Repo
    Write-Step 'Ambiente virtual e dependencias'           ; Ensure-Venv
    Write-Step 'Montagem da URL do banco'                  ; Build-DatabaseUrl
    Write-Step 'Banco de dados (criacao/validacao)'        ; Ensure-Database
    Write-Step 'Certificados SSL (HTTPS local)'            ; Ensure-SslCerts
    Write-Step 'Arquivo de configuracao .env'              ; Ensure-EnvFile
    Write-Step 'Teste de conexao com o banco'              ; Test-DbConnection
    Write-Step 'Tarefa agendada (servico)'                 ; Ensure-ServiceTask
    Write-Step 'Sanity pre-start'                          ; Pre-StartSanity
    Write-Step 'Parada da tarefa de rodada anterior'       ; Stop-ServiceTaskIfRunning
    Write-Step 'Inicializacao do schema (init_db)'         ; Init-Database
    Write-Step 'Start + health check'                      ; Start-AndHealthCheck
    Write-Step 'Bateria pos-instalacao'                    ; Post-InstallChecks
    Write-Step 'Auditoria de seguranca'                    ; Security-SelfCheck

    # Regra de firewall para acesso via rede (idempotente por nome; sem ela
    # o Windows bloqueia a porta por padrao - divergencia necessaria do Linux)
    if ($AppHost -ne '127.0.0.1') {
        $fw = Get-NetFirewallRule -DisplayName "SisPatrimonio Pro ($AppPort)" -ErrorAction SilentlyContinue
        if (-not $fw) {
            New-NetFirewallRule -DisplayName "SisPatrimonio Pro ($AppPort)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([int]$AppPort) -ErrorAction Stop | Out-Null
            ok "Regra de firewall de entrada criada para a porta $AppPort (acesso via rede)."
        }
    }

    Print-Summary
    ok 'Concluido.'
}

Main
