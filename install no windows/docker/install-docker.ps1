<#
.SYNOPSIS
    SisPatrimonio Pro - Instalador Automatizado de Producao WINDOWS via DOCKER

.DESCRIPTION
    Versao Windows (PowerShell) do install-docker.sh. Prepara um servidor
    Windows para executar o SisPatrimonio Pro em producao usando o Docker
    Compose DO PROPRIO REPOSITORIO (docker-compose.yml + Dockerfile
    versionados no repo):
      prerequisitos -> Docker Desktop/Engine + Compose v2 -> Git -> clone
      -> analise do compose do repo -> .env (ACL restrita) -> build da imagem
      -> container MariaDB (volume db-data) -> init_db -> app -> /health -> resumo

    Arquitetura (definida pelo compose do repositorio - fonte da verdade):
      container sispat-app  (build local)  ->  container sispat-db (mariadb:11)
      volumes nomeados <projeto>_db-data (banco) e <projeto>_app-data (backups/logs)
      Sem servico do Windows para a aplicacao: restart: unless-stopped do Docker.

    Idempotente (mesma filosofia do install-docker.sh): cada etapa detecta o
    estado anterior e REUTILIZA o que ja existe. O .env NUNCA e sobrescrito
    (backup + mescla apenas de chaves ausentes). O volume do banco NUNCA e
    apagado - recriacao somente via -ResetDb, com dupla confirmacao interativa
    (afeta SOMENTE o volume do banco; app-data - backups/logs - e preservado).

    Seguranca (mesmos principios SR-001..SR-005):
      - senha do banco coletada SEM ECO ou gerada via RNG criptografico;
        NUNCA em argv visivel (MYSQL_PWD via docker compose exec -e), NUNCA no log;
      - SECRET_KEY e DB_ROOT_PASSWORD sempre geradas pelo instalador (o default
        'changeme-root' do compose NUNCA entra em producao);
      - segredos ficam SOMENTE no .env (ACL restrita); o compose do repositorio
        NUNCA e alterado pelo instalador.

.USO
    powershell -ExecutionPolicy Bypass -File install-docker.ps1
    powershell -ExecutionPolicy Bypass -File install-docker.ps1 -NonInteractive -GenerateDbPassword
    powershell -ExecutionPolicy Bypass -File install-docker.ps1 -ResetDb   # APAGA o volume do banco (destrutivo)

    Requer Docker Desktop em execucao (ou Docker Engine + Compose v2).
    Codigo 100% ASCII: evita corrupcao de acentos em Windows PowerShell 5.1.

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
    [string]$AppPort,
    [switch]$ResetDb,
    [switch]$Help
)

# EAP=Continue: comandos nativos (git/docker/compose) escrevem em stderr e,
# no Windows PowerShell 5.1 com EAP=Stop, o redirecionamento 2>/1> promove
# essas linhas a erros terminantes espurios. Cada chamada nativa e validada
# por $LASTEXITCODE + die(); cmdlets criticos usam -ErrorAction Stop explicito.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# Constantes e defaults
# ----------------------------------------------------------------------------
$DefaultRepoUrl    = 'https://github.com/wellingtonsr1/SisPatrimonioPro.git'
$DefaultBranch     = 'main'
$DefaultInstallDir = 'C:\SisPatrimonioPro'
$DefaultAppPort    = '8000'    # porta exposta no HOST (a app escuta 8000 DENTRO do container)
$DefaultTz         = 'America/Sao_Paulo'   # fuso do servidor; ajustavel via .env (TZ)
$InstallLog        = Join-Path $env:ProgramData 'sispatrimonio-install-docker.log'
$HealthTimeoutSeconds  = 180
$DbWaitTimeoutSeconds  = 240
$AppInternalPort   = '8000'

$AppVersionInstaller = '2.1.0-docker-win'
$Script:Step   = ''
$Script:StepNo = 0
$TotalSteps    = 10

# Valores resolvidos do compose do repositorio (Parse-ComposeConfig)
$script:AppCname = 'sispat-app'
$script:DbCname  = 'sispat-db'
$script:DbNameResolved   = ''
$script:DbUserResolved   = ''
$script:DbVolume         = ''
$script:DbNameCli        = $DbName    # somente conferencia contra o compose
$script:DbUserCli        = $DbUser
$script:DbNameProvided   = [bool]$DbName
$script:DbUserProvided   = [bool]$DbUser

$script:ReusedEnv      = $false   # true quando .env existente foi reutilizado
$script:ExistingVolume = $false   # volume do banco ja existe antes desta execucao
$script:ExistingEnv    = $false   # .env ja existe antes desta execucao
$script:MysqldumpDetected = ''

$script:RepoUrl     = $DefaultRepoUrl
$script:BranchValue = $DefaultBranch
$script:SecretKey       = ''
$script:DbRootPassword  = ''
$script:TzValue         = ''

# ----------------------------------------------------------------------------
# Log (mesma filosofia do install-docker.sh)
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
    Write-Host '  | (nenhum dado e apagado; o volume do banco so e'
    Write-Host '  |  afetado com -ResetDb e dupla confirmacao).'
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

# Coleta de senha SEM ECO (SR-001). Vazio NAS DUAS entradas = gerar automaticamente.
function Read-Secret([string]$Prompt) {
    $p1 = Read-Host -AsSecureString $Prompt
    $p2 = Read-Host -AsSecureString 'Confirme a senha (vazio nas duas = gerar automaticamente):'
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
# Parser e validacao de CLI
# ----------------------------------------------------------------------------
function Show-Usage {
@"
SisPatrimonio Pro - instalador de producao WINDOWS via DOCKER v$AppVersionInstaller

Uso: powershell -ExecutionPolicy Bypass -File install-docker.ps1 [opcoes]

  -NonInteractive              Nenhum prompt; exige -DbPassword ou -GenerateDbPassword
  -InstallDir <caminho>        Diretorio de instalacao (default: $DefaultInstallDir)
  -Repo <url>                  Repositorio Git (default: repo oficial)
  -Branch <nome>               Branch (default: $DefaultBranch)
  -DbPassword <senha>          Senha do banco (nao interativo; NAO use em producao compartilhada)
  -GenerateDbPassword          Gera senha forte automaticamente (vai direto ao .env)
  -DbName <nome>               SOMENTE para conferencia: o compose do repo fixa o banco
                               (sispatrimonio_pro) - valor divergente aborta a instalacao
  -DbUser <usuario>            SOMENTE para conferencia: o compose do repo fixa o usuario
                               (sispatrimonio) - valor divergente aborta a instalacao
  -AppPort <porta>             Porta da aplicacao no HOST (default: $DefaultAppPort)
  -ResetDb                     APAGA o volume do banco e recria do zero (SO interativo;
                               dupla confirmacao; proibido com -NonInteractive;
                               NAO afeta o volume app-data - backups/logs preservados)
  -Help                        Esta ajuda

Nota: esta variante usa o docker-compose.yml + Dockerfile versionados no
PROPRIO repositorio (app + MariaDB em containers). Requer Docker Desktop
(ou Docker Engine + Compose v2) em execucao no Windows.

Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
"@
}

function Parse-Args {
    if ($Help) { Show-Usage; exit 0 }
    if ($Repo)   { $script:RepoUrl = $Repo }
    if ($Branch) { $script:BranchValue = $Branch }
}

function Test-Identifier([string]$Label, [string]$Value, [string]$Pattern) {
    if ($Value -notmatch $Pattern) { die "$Label invalido: '$Value' (esperado: $Pattern)" }
}

# O compose do repo interpola a senha DIRETAMENTE na DATABASE_URL (sem percent-
# encoding) e em valores YAML. Restricao por ALLOWLIST (nao blocklist): apenas
# caracteres seguros nos dois contextos. A senha gerada (base64url) atende.
function Test-PasswordDocker([string]$Password) {
    if ($Password -notmatch '^[A-Za-z0-9_.+-]{12,128}$') {
        die 'Senha manual contem caracteres nao suportados nesta variante (use apenas letras, numeros e _ . + - ; minimo 12). Deixe vazia para gerar automaticamente.'
    }
}

function Validate-Inputs {
    if (-not $InstallDir) { $script:InstallDir = $DefaultInstallDir }
    if (-not $AppPort)    { $script:AppPort = $DefaultAppPort }

    if ($DbNameProvided) { Test-Identifier 'Nome do banco'    $DbNameCli '^[A-Za-z_][A-Za-z0-9_]*$' }
    if ($DbUserProvided) { Test-Identifier 'Usuario do banco' $DbUserCli '^[A-Za-z_][A-Za-z0-9_]*$' }

    if ($AppPort -notmatch '^[0-9]+$' -or [int]$AppPort -lt 1 -or [int]$AppPort -gt 65535) {
        die "Porta da aplicacao invalida: $AppPort (1-65535)"
    }

    # Recriacao do volume e PROIBIDA em modo nao interativo (mesma decisao D2)
    if ($ResetDb -and $NonInteractive) {
        die 'Combinacao invalida: -ResetDb e proibida com -NonInteractive.'
    }
    # No modo nao interativo, senha deve ser fornecida ou marcada como gerada
    if ($NonInteractive -and -not $GenerateDbPassword -and -not $DbPassword) {
        die 'Modo nao interativo exige -DbPassword ou -GenerateDbPassword.'
    }
    if ($DbPassword -and $GenerateDbPassword) {
        die 'Use apenas uma: -DbPassword OU -GenerateDbPassword.'
    }
    if ($DbPassword) { Test-PasswordDocker $DbPassword }
}

# ----------------------------------------------------------------------------
# Credenciais: coleta (interativa) ou REUSO do .env existente (idempotencia)
# ----------------------------------------------------------------------------
function Read-EnvValue([string]$File, [string]$Key) {
    foreach ($line in (Get-Content $File -ErrorAction SilentlyContinue)) {
        if ($line -match ('^' + [regex]::Escape($Key) + '=(.*)$')) { return $Matches[1].Trim() }
    }
    return ''
}

function Reuse-EnvFile {
    # le o .env existente e usa as MESMAS credenciais (nada e sobrescrito)
    $envFile = Join-Path $InstallDir '.env'
    $script:DbPassword = Read-EnvValue $envFile 'DB_PASSWORD'
    if (-not $DbPassword) {
        die '.env existente sem DB_PASSWORD - impossivel reutilizar. Faca backup, remova/mova o .env e reexecute.'
    }
    $script:SecretKey = Read-EnvValue $envFile 'SECRET_KEY'
    if (-not $SecretKey) {
        warn 'SECRET_KEY ausente no .env - sera GERADA e ADICIONADA (chave ausente; nada existente e alterado).'
        $script:SecretKey = New-HexKey
    }
    $script:DbRootPassword = Read-EnvValue $envFile 'DB_ROOT_PASSWORD'
    if (-not $DbRootPassword) {
        warn "DB_ROOT_PASSWORD ausente no .env - sera GERADO e ADICIONADO (o default 'changeme-root' do compose NUNCA e usado)."
        $script:DbRootPassword = New-Secret
    }
    $p = Read-EnvValue $envFile 'APP_PORT'
    if (-not $p) { $p = $DefaultAppPort }
    $script:AppPort = $p
    $tz = Read-EnvValue $envFile 'TZ'
    if (-not $tz) { $tz = $DefaultTz }
    $script:TzValue = $tz
    $script:ReusedEnv = $true
    ok '.env existente sera REUTILIZADO - credenciais preservadas, nada sera sobrescrito.'
}

function Collect-Secrets {
    $Script:Step = 'Credenciais e configuracao'
    if ($ExistingEnv) { Reuse-EnvFile; return }
    if ($NonInteractive) {
        if ($GenerateDbPassword) {
            $script:DbPassword = New-Secret
            ok 'Senha do banco gerada automaticamente (gravada apenas no .env).'
        }
    } elseif (-not $DbPassword) {
        $script:DbPassword = Read-Secret 'Senha do banco (min. 12 caracteres; ENTER vazio nas duas = gerar automaticamente): '
        if (-not $DbPassword) {
            $script:DbPassword = New-Secret
            ok 'Senha do banco gerada automaticamente (gravada apenas no .env).'
        } else {
            Test-PasswordDocker $DbPassword
        }
    }
    # SECRET_KEY e DB_ROOT_PASSWORD: SEMPRE geradas (nao ha uso humano; ficam
    # apenas no .env - o default 'changeme-root' do compose nunca entra em producao)
    $script:SecretKey = New-HexKey
    $script:DbRootPassword = New-Secret
    $script:TzValue = $DefaultTz
    ok 'SECRET_KEY e senha de root do MariaDB geradas (gravadas apenas no .env).'
}

function Confirm-Plan {
    if ($NonInteractive) { return }
    Write-Host ''
    Write-Host '  RESUMO DA INSTALACAO (DOCKER - compose do repositorio)' -ForegroundColor White
    Write-Host ('    Diretorio    : ' + $InstallDir)
    Write-Host ('    Repositorio  : ' + $RepoUrl + ' (branch ' + $BranchValue + ')')
    Write-Host ('    Compose      : ' + (Join-Path $InstallDir 'docker-compose.yml') + ' (versionado no repo - nao alterado)')
    Write-Host ('    Imagem app   : build local do Dockerfile do repo (servico ''app'')')
    Write-Host ('    Banco        : ' + $DbNameResolved + ' (usuario ' + $DbUserResolved + ') - container ' + $DbCname)
    Write-Host ('    Volume bd    : ' + $DbVolume + ' (app-data de backups/logs preservado)')
    Write-Host ('    Porta host   : 0.0.0.0:' + $AppPort + ' -> container ' + $AppInternalPort)
    Write-Host ('    Fuso (TZ)    : ' + $TzValue)
    if ($ReusedEnv) { Write-Host '    .env         : EXISTENTE sera reutilizado (credenciais preservadas)' }
    if ($ResetDb) { warn ('*** -ResetDb ATIVO: o volume ''' + $DbVolume + ''' sera APAGADO e recriado ***') }
    Write-Host ''
    if (-not (Test-Confirmed '  Confirmar e iniciar a instalacao? (s/N): ')) {
        die 'Instalacao cancelada pelo operador. Nada foi alterado.'
    }
    ok 'Confirmado.'
}

function Confirm-ResetDb {
    # dupla confirmacao digitando o nome do banco (padrao do install.sh)
    if (-not $ResetDb) { return }
    if (-not $ExistingVolume) {
        ok '-ResetDb informado, mas nenhum volume de banco existe - nada a apagar.'
        return
    }
    warn '=============================================================='
    warn ("MODO DESTRUTIVO: -ResetDb APAGARA o volume '$DbVolume'")
    warn ("e TODOS os dados do banco '$DbNameResolved'. IRREVERSIVEL.")
    warn '(o volume app-data - backups/logs da aplicacao - e PRESERVADO)'
    warn '=============================================================='
    $c1 = Read-Host 'Digite o nome do banco para confirmar (1/2)'
    $c2 = Read-Host 'Digite novamente (2/2)'
    if ($c1 -ne $DbNameResolved -or $c2 -ne $DbNameResolved) {
        die 'Confirmacao divergente. Operacao abortada - nada foi alterado.'
    }
    ok 'Dupla confirmacao recebida.'
}

# ----------------------------------------------------------------------------
# Gates de prerequisitos
# ----------------------------------------------------------------------------
function Require-Admin {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($wi)
    if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        die 'Este instalador requer execucao como Administrador (abrir PowerShell elevado).'
    }
    ok 'Executando com privilegios de administrador.'
}

function Test-Connectivity {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        die 'Git nao disponivel para verificar o repositorio (instale o Git e reexecute).'
    }
    & git ls-remote --heads $RepoUrl $BranchValue *> $null
    if ($LASTEXITCODE -ne 0) {
        die "Nao foi possivel acessar $RepoUrl (branch '$BranchValue'). Verifique rede/URL."
    }
    ok "Repositorio acessivel e branch '$BranchValue' existe."
}

# ----------------------------------------------------------------------------
# Deteccao do ambiente (Docker/Compose, .env, volume - best-effort pre-clone;
# o nome REAL do volume e resolvido depois, no parse do compose)
# ----------------------------------------------------------------------------
function Detect-Host {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        ok ("Docker CLI detectado: " + (& docker --version 2>$null))
    } else {
        warn 'Docker nao encontrado (sera orientada a instalacao do Docker Desktop).'
    }
    $composeOk = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        & docker compose version *> $null
        $composeOk = ($LASTEXITCODE -eq 0)
    }
    if ($composeOk) { ok 'Docker Compose v2 detectado.' }
    else            { warn 'Docker Compose v2 nao detectado (sera verificado apos o Docker).' }

    $script:ExistingEnv = (Test-Path (Join-Path $InstallDir '.env'))
    if ($ExistingEnv) {
        ok ".env existente detectado em $InstallDir (credenciais serao REUTILIZADAS)."
    }

    # Porta do HOST em uso? (reportada antes do start, como no install-docker.sh)
    $conn = Get-NetTCPConnection -LocalPort ([int]$AppPort) -State Listen -ErrorAction SilentlyContinue
    if ($conn) { warn "Porta $AppPort ja esta em uso no host (verifique antes de iniciar o container)." }
}

# ----------------------------------------------------------------------------
# Pacotes: Git no host + Docker Desktop/Engine com Compose v2
# ----------------------------------------------------------------------------
function Ensure-Packages {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            info 'Instalando Git via winget (pode levar alguns minutos)...'
            & winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Write-Host "    $_" }
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            die 'Git nao disponivel. Instale o Git manualmente (git-scm.com) e reexecute.'
        }
    }
    ok 'Git disponivel.'

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        die 'Docker nao encontrado. Instale o Docker Desktop (docker.com) ou o Docker Engine, inicie-o e reexecute - o instalador e idempotente.'
    }
    # Daemon disponivel? (docker info) - no Windows Desktop o daemon deve estar em execucao
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        info 'Daemon do Docker indisponivel - tentando iniciar o Docker Desktop...'
        $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        if (Test-Path $dd) {
            Start-Process $dd | Out-Null
            $waited = 0
            while ($waited -lt 120) {
                Start-Sleep -Seconds 5
                $waited += 5
                & docker info *> $null
                if ($LASTEXITCODE -eq 0) { break }
            }
        }
        & docker info *> $null
        if ($LASTEXITCODE -ne 0) {
            die 'Daemon do Docker indisponivel (docker info falhou). Inicie o Docker Desktop e reexecute.'
        }
    }
    ok 'Daemon do Docker em execucao.'

    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        die 'Docker Compose v2 nao disponivel (docker compose version falhou). Atualize o Docker Desktop/Engine e reexecute.'
    }
    ok ("Docker Compose v2 pronto (" + (& docker compose version --short 2>$null) + ").")
}

# ----------------------------------------------------------------------------
# Clone (identico ao install-docker.sh)
# ----------------------------------------------------------------------------
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
# Analise do docker-compose.yml do REPOSITORIO (fonte da verdade):
# resolve nomes reais de containers, banco/usuario e volume - e valida os
# parametros de CLI contra ele. O compose NUNCA e alterado pelo instalador.
# (O parse usa ConvertFrom-Json do PowerShell - sem dependencia de Python
#  ou jq no host.)
# ----------------------------------------------------------------------------
function Invoke-DCC {
    # wrapper do docker compose com projeto/diretorio fixos; a saida flui para
    # o console e o codigo de saida fica em $LASTEXITCODE (nativo)
    & docker compose --project-directory $InstallDir -f (Join-Path $InstallDir 'docker-compose.yml') @args
}

function Parse-ComposeConfig {
    $Script:Step = 'Analise do docker-compose.yml do repositorio'
    if (-not (Test-Path (Join-Path $InstallDir 'docker-compose.yml'))) {
        die "docker-compose.yml nao encontrado em $InstallDir - esta variante usa o compose versionado no repositorio. Atualize o clone (git pull) e reexecute."
    }
    if (-not (Test-Path (Join-Path $InstallDir 'Dockerfile'))) {
        die "Dockerfile nao encontrado em $InstallDir - o compose do repo constroi a imagem da app a partir dele. Atualize o clone (git pull) e reexecute."
    }

    $composeFile = Join-Path $InstallDir 'docker-compose.yml'
    # compose exige variaveis obrigatorias (:?) para o config: passa dummies
    # APENAS para a analise estrutural (nunca as credenciais reais)
    $tmpEnv = New-TemporaryFile
    Set-Content $tmpEnv "DB_PASSWORD=dummy`nSECRET_KEY=dummy`nDB_ROOT_PASSWORD=dummy`nAPP_PORT=$AppPort"
    $raw = & docker compose --project-directory $InstallDir -f $composeFile --env-file $tmpEnv config --format json 2>$null
    Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue
    if (-not $raw) { die 'docker-compose.yml do repositorio e invalido ou o Compose e antigo demais para --format json.' }
    try   { $cfg = ($raw -join '') | ConvertFrom-Json }
    catch { die "Saida do docker compose config nao e JSON valido: $($_.Exception.Message)" }

    # services.db.environment / services.app (PSv5.1: hashes/vetores)
    $db = $cfg.services.db
    $app = $cfg.services.app
    $script:AppCname = if ($app.container_name) { $app.container_name } else { 'sispat-app' }
    $script:DbCname  = if ($db.container_name)  { $db.container_name }  else { 'sispat-db' }

    $dbenv = $db.environment
    if ($dbenv -is [pscustomobject]) {
        $script:DbNameResolved = [string]$dbenv.MARIADB_DATABASE
        $script:DbUserResolved = [string]$dbenv.MARIADB_USER
    } elseif ($dbenv) {
        foreach ($item in @($dbenv)) {
            if ($item -match '^MARIADB_DATABASE=(.*)$') { $script:DbNameResolved = $Matches[1] }
            if ($item -match '^MARIADB_USER=(.*)$')     { $script:DbUserResolved = $Matches[1] }
        }
    }

    $proj = if ($cfg.name) { $cfg.name } else { (Split-Path $InstallDir -Leaf).ToLower() -replace '[^a-z0-9_-]', '-' }
    $script:DbVolume = ''
    foreach ($key in @('db-data', 'db_data')) {
        $v = $cfg.volumes.$key
        if ($v -and $v.name) { $script:DbVolume = [string]$v.name; break }
    }
    if (-not $DbVolume) { $script:DbVolume = "$proj`_db-data" }

    if (-not $DbNameResolved) { $script:DbNameResolved = 'sispatrimonio_pro'; warn "MARIADB_DATABASE nao resolvido do compose - assumindo '$DbNameResolved'." }
    if (-not $DbUserResolved) { $script:DbUserResolved = 'sispatrimonio';     warn "MARIADB_USER nao resolvido do compose - assumindo '$DbUserResolved'." }

    # Validacao cruzada CLI x compose (o repo fixa banco/usuario - fonte da verdade)
    if ($DbNameProvided -and $DbNameCli -and $DbNameCli -ne $DbNameResolved) {
        die "-DbName '$DbNameCli' diverge do banco fixado pelo compose do repositorio ('$DbNameResolved'). O compose e a fonte da verdade - remova a opcao ou ajuste o compose no repo."
    }
    if ($DbUserProvided -and $DbUserCli -and $DbUserCli -ne $DbUserResolved) {
        die "-DbUser '$DbUserCli' diverge do usuario fixado pelo compose do repositorio ('$DbUserResolved'). O compose e a fonte da verdade - remova a opcao ou ajuste o compose no repo."
    }

    # Volume do banco: existe? (define reuso vs primeira criacao)
    & docker volume ls --format '{{.Name}}' 2>$null | ForEach-Object {
        if ($_ -eq $DbVolume) { $script:ExistingVolume = $true }
    }
    if ($ExistingVolume) { ok "Volume do banco detectado: $DbVolume (sera REUTILIZADO)." }
    else { info "Volume do banco '$DbVolume' nao existe (primeira instalacao do banco)." }

    ok "Compose analisado: containers $AppCname/$DbCname - banco $DbNameResolved (usuario $DbUserResolved) - volume $DbVolume."
}

# ----------------------------------------------------------------------------
# .env (ACL restrita, nunca sobrescrito; mescla so chaves ausentes) + validacao
# ----------------------------------------------------------------------------
function Protect-EnvFile([string]$Path) {
    # Equivalente Windows do chmod 600 (SR-002)
    & icacls $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' ("{0}\{1}:F" -f $env:USERDOMAIN, $env:USERNAME) *> $null
}

function Ensure-EnvFile {
    $envFile = Join-Path $InstallDir '.env'
    if (Test-Path $envFile) {
        $bak = "$envFile.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
        warn '.env existente - NUNCA e sobrescrito.'
        Copy-Item $envFile $bak -Force -ErrorAction Stop
        ok "Backup criado: $bak"
        # Mescla APENAS chaves ausentes (credenciais existentes preservadas)
        $added = 0
        if (-not (Read-EnvValue $envFile 'SECRET_KEY'))       { Add-Content $envFile "SECRET_KEY=$SecretKey";           $added++ }
        if (-not (Read-EnvValue $envFile 'DB_ROOT_PASSWORD')) { Add-Content $envFile "DB_ROOT_PASSWORD=$DbRootPassword"; $added++ }
        if (-not (Read-EnvValue $envFile 'APP_PORT'))         { Add-Content $envFile "APP_PORT=$AppPort";               $added++ }
        if (-not (Read-EnvValue $envFile 'TZ'))               { Add-Content $envFile "TZ=$TzValue";                     $added++ }
        if ($added -gt 0) { ok "$added chave(s) ausentes adicionadas ao .env (valores existentes preservados)." }
        else              { ok '.env mantido sem alteracoes (todas as chaves exigidas pelo compose presentes).' }
    } else {
        $content = @"
# Gerado por install-docker.ps1 v$AppVersionInstaller em $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# ATENCAO: contem credenciais - ACL restrita. NUNCA versionar/compartilhar.

# Banco de dados (valores lidos pelo docker-compose.yml do repositorio)
DB_PASSWORD=$DbPassword
DB_ROOT_PASSWORD=$DbRootPassword

# Chave de sessao da aplicacao (gerada - ver cabecalho do compose)
SECRET_KEY=$SecretKey

# Porta exposta no HOST (a app escuta fixo em $AppInternalPort dentro do container)
APP_PORT=$AppPort

# Fuso horario dos containers
TZ=$TzValue
"@
        Set-Content -Path $envFile -Value $content -Encoding UTF8 -ErrorAction Stop
        ok '.env gerado com ACL restrita (SR-002).'
    }
    Protect-EnvFile $envFile

    # Validacao FINAL do compose COM as credenciais reais (falha indica
    # variavel exigida ausente no .env)
    $composeFile = Join-Path $InstallDir 'docker-compose.yml'
    & docker compose --project-directory $InstallDir -f $composeFile config --quiet *> $null
    if ($LASTEXITCODE -ne 0) {
        die "docker-compose.yml invalido ou variavel exigida ausente no .env - verifique com: cd $InstallDir; docker compose config"
    }
    ok 'docker-compose.yml validado com o .env (docker compose config OK).'
}

# ----------------------------------------------------------------------------
# Build da imagem da app (Dockerfile do repo, via compose - camadas cacheadas)
# ----------------------------------------------------------------------------
function Invoke-ComposeBuild {
    info "Construindo a imagem do servico 'app' (pode levar varios minutos na primeira vez)..."
    Invoke-DCC build
    if ($LASTEXITCODE -ne 0) { die 'Falha no build da imagem da aplicacao (docker compose build).' }
    ok 'Imagem construida.'

    # mysqldump DENTRO da imagem (backup/restauracao pela propria app)
    $out = Invoke-DCC run --rm --no-deps --entrypoint /bin/sh app -c 'command -v mysqldump || true' 2>$null
    $script:MysqldumpDetected = (@($out) | Select-Object -Last 1)
    if ($MysqldumpDetected) {
        ok "mysqldump presente na imagem: $MysqldumpDetected (backups da app OK)."
    } else {
        warn 'mysqldump AUSENTE na imagem - backup/restauracao pela app nao funcionara (o restante nao e afetado).'
    }
}

# ----------------------------------------------------------------------------
# Banco de dados (container MariaDB + volume nomeado do compose)
# ----------------------------------------------------------------------------
function Sql-Escape([string]$Value) {
    if ($Value.Contains('\')) { die 'Valor contem backslash (\) - nao suportado pelo escape SQL do instalador.' }
    return $Value.Replace("'", "''")
}

function Invoke-DbRootSql([string]$Sql) {
    # SQL administrativo (MYSQL_PWD via exec -e - NUNCA argv/log).
    # stdout descartado: a funcao retorna APENAS sucesso/falha.
    $composeFile = Join-Path $InstallDir 'docker-compose.yml'
    & docker compose --project-directory $InstallDir -f $composeFile exec -T -e "MYSQL_PWD=$DbRootPassword" db mariadb -uroot -N -B -e $Sql *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-DbUserSql([string]$Sql) {
    # SQL como o usuario da aplicacao (retorno = sucesso/falha apenas)
    $composeFile = Join-Path $InstallDir 'docker-compose.yml'
    & docker compose --project-directory $InstallDir -f $composeFile exec -T -e "MYSQL_PWD=$DbPassword" db mariadb "-u$DbUserResolved" -N -B -e $Sql *> $null
    return ($LASTEXITCODE -eq 0)
}

function Wait-DbHealthy {
    info "Aguardando o container do banco ficar saudavel (ate ${DbWaitTimeoutSeconds}s; primeira inicializacao pode demorar)..."
    $waited = 0
    while ($waited -lt $DbWaitTimeoutSeconds) {
        $st = (& docker inspect -f '{{.State.Health.Status}}' $DbCname 2>$null)
        if ($st -eq 'healthy')  { ok 'Container do banco saudavel.'; return }
        if ($st -eq 'unhealthy') {
            err 'Container do banco em estado unhealthy - ultimas linhas do log:'
            Invoke-DCC logs --tail 40 db
            die 'Container do banco falhou (unhealthy). Corrija e reexecute - o instalador e idempotente.'
        }
        Start-Sleep -Seconds 3
        $waited += 3
    }
    Invoke-DCC logs --tail 40 db
    die "Container do banco nao ficou saudavel em ${DbWaitTimeoutSeconds}s."
}

function Verify-FreshDb {
    # primeira inicializacao: entrypoint do MariaDB cria banco+usuario
    $tries = 0
    while ($tries -lt 20) {
        $found = (& docker compose --project-directory $InstallDir -f (Join-Path $InstallDir 'docker-compose.yml') `
            exec -T -e "MYSQL_PWD=$DbRootPassword" db mariadb -uroot -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(Sql-Escape $DbNameResolved)';" 2>$null)
        if ((@($found) -join '').Trim() -eq $DbNameResolved) {
            ok "Banco '$DbNameResolved' e usuario '$DbUserResolved' criados pelo entrypoint do MariaDB."
            return
        }
        Start-Sleep -Seconds 3
        $tries++
    }
    Invoke-DCC logs --tail 40 db
    die "Banco '$DbNameResolved' nao apareceu apos a inicializacao do container (logs acima)."
}

function Verify-AppDbUser {
    # reuso: alinha a senha do usuario ao .env (caso divergente)
    if (Invoke-DbUserSql 'SELECT 1;') {
        ok 'Credencial do usuario do banco confere com o .env.'
        return
    }
    warn "Senha do usuario '$DbUserResolved' diverge do estado atual do banco - tentando realinhar via root..."
    if (Invoke-DbRootSql 'SELECT 1;') {
        $esc = Sql-Escape $DbPassword
        $alinhou = Invoke-DbRootSql "ALTER USER '$DbUserResolved'@'%' IDENTIFIED BY '$esc'; FLUSH PRIVILEGES;"
        if (-not $alinhou) {
            die 'ALTER USER falhou - verifique o banco manualmente (docker compose exec db mariadb -uroot -p).'
        }
        ok "Senha do usuario '$DbUserResolved' realinhada a do .env."
    } else {
        die 'Credencial da app invalida e root indisponivel (DB_ROOT_PASSWORD ausente/incorreto no .env). Corrija o .env ou use -ResetDb (DESTRUTIVO - dupla confirmacao) e reexecute.'
    }
}

function Ensure-Database {
    if ($ExistingVolume -and -not $ResetDb) {
        ok "Volume '$DbVolume' existente - REUTILIZADO (nada sera apagado)."
    } elseif ($ExistingVolume) {
        # Precisao destrutiva: remove SOMENTE o volume do banco (NAO usa
        # `down -v`, que tambem apagaria app-data - backups/logs da app)
        warn "APAGANDO o volume do banco '$DbVolume' (solicitacao explicita -ResetDb)..."
        Invoke-DCC down --remove-orphans *> $null
        & docker volume rm $DbVolume *> $null
        if ($LASTEXITCODE -ne 0) {
            die "Nao foi possivel remover o volume '$DbVolume' (em uso?). Execute: docker volume rm $DbVolume - e reexecute."
        }
        ok 'Volume do banco removido (app-data PRESERVADO) - banco sera criado do zero.'
    }
    info 'Subindo o container do banco...'
    Invoke-DCC up -d db
    if ($LASTEXITCODE -ne 0) { die 'Falha ao subir o container do banco (docker compose up -d db).' }
    Wait-DbHealthy
    if ($ExistingVolume -and -not $ResetDb) { Verify-AppDbUser }
    else { Verify-FreshDb }
}

# ----------------------------------------------------------------------------
# init_db explicito (mesmo contrato do install-docker.sh: VERIFICADO pelo
# instalador; roda em container EFEMERO antes da app subir - sem corrida)
# ----------------------------------------------------------------------------
function Init-Database {
    info 'Executando init_db() do projeto em container efemero (create_all idempotente)...'
    # --entrypoint python3: robusto tanto para imagens com CMD quanto com ENTRYPOINT
    Invoke-DCC run --rm --no-deps --entrypoint python3 app -c 'from app.database import init_db; init_db()'
    if ($LASTEXITCODE -ne 0) {
        die 'init_db() falhou - verifique o .env e o estado do banco. Instalacao interrompida (nenhum dado alterado).'
    }
    ok 'Schema verificado/criado via init_db() do projeto.'
}

# ----------------------------------------------------------------------------
# Start da app + health check (mesmo contrato do install-docker.sh)
# ----------------------------------------------------------------------------
function Start-AndHealthCheck {
    Invoke-DCC up -d app
    if ($LASTEXITCODE -ne 0) { die 'Falha ao subir o container da aplicacao (docker compose up -d app).' }
    info "Aguardando /health em http://127.0.0.1:$AppPort (ate ${HealthTimeoutSeconds}s)..."
    $waited = 0
    while ($waited -lt $HealthTimeoutSeconds) {
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/health" -TimeoutSec 5
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
    err '=== Ultimas linhas do log do container da app ==='
    Invoke-DCC logs --tail 60 app
    err '=== Inspecao do container ==='
    err (& docker inspect -f 'State: {{.State.Status}} | OOMKilled: {{.State.OOMKilled}} | RestartCount: {{.RestartCount}} | Error: {{.State.Error}}' $AppCname 2>$null)
    # Interrompe o loop de reinicio (restart: unless-stopped reiniciaria para sempre)
    Invoke-DCC stop app *> $null
    warn 'Container da app PARADO para encerrar o loop de reinicio. Reexecute o instalador quando quiser tentar novamente (idempotente).'
    die "Falha na verificacao de saude. Diagnostico acima; log completo em $InstallLog."
}

# ----------------------------------------------------------------------------
# Bateria pos-instalacao (equivalente docker da bateria do install-docker.sh)
# ----------------------------------------------------------------------------
function Post-InstallChecks {
    $failures = 0

    & docker info *> $null
    if ($LASTEXITCODE -eq 0) { ok 'Docker daemon: OK' } else { err 'Docker daemon: FALHOU'; $failures++ }

    if ((& docker inspect -f '{{.State.Running}}' $AppCname 2>$null) -eq 'true') { ok 'Container da app em execucao: OK' }
    else { err 'Container da app: FALHOU'; $failures++ }

    if ((& docker inspect -f '{{.State.Health.Status}}' $DbCname 2>$null) -eq 'healthy') { ok 'Container do banco saudavel: OK' }
    else { err 'Container do banco: FALHOU'; $failures++ }

    if (Invoke-DbUserSql "SELECT 1 FROM ``$(Sql-Escape $DbNameResolved)``.users LIMIT 1;") { ok 'Tabela base (users) existente: OK' }
    else { err 'Tabela base (users): FALHOU'; $failures++ }

    try { Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/health" -TimeoutSec 5 | Out-Null; ok 'HTTP /health (host): OK' }
    catch { err 'HTTP /health (host): FALHOU'; $failures++ }

    # ACL do .env (equivalente Windows do modo 600 - SR-002)
    $envFile = Join-Path $InstallDir '.env'
    if (Test-Path $envFile) {
        $rules = @((Get-Acl $envFile).Access | Where-Object { $_.AccessControlType -eq 'Allow' })
        if ($rules.Count -le 3) { ok '.env com ACL restrita (SR-002): OK' }
        else { err ".env com $($rules.Count) entradas de acesso (esperado <= 3) - revise com: icacls `"$envFile`""; $failures++ }
    }

    if ($failures -gt 0) { die "$failures verificacao(oes) pos-instalacao falharam - veja mensagens acima e o log." }
    ok 'Bateria completa: todas as verificacoes passaram.'
}

# ----------------------------------------------------------------------------
# Auto-check de seguranca (SR-001): segredos NAO podem estar no log
# ----------------------------------------------------------------------------
function Security-SelfCheck {
    $leaked = $false
    foreach ($secret in @($DbPassword, $DbRootPassword, $SecretKey)) {
        if ($secret -and (Test-Path $InstallLog) -and ([IO.File]::ReadAllText($InstallLog)).Contains($secret)) {
            warn "Uma credencial foi encontrada no log do instalador - REVISE $InstallLog (remova a linha) e investigue a origem."
            $leaked = $true
        }
    }
    if (-not $leaked) { ok 'Auto-check: nenhuma credencial no log (SR-001).' }

    $envFile = Join-Path $InstallDir '.env'
    if (Test-Path $envFile) {
        $rules = @((Get-Acl $envFile).Access | Where-Object { $_.AccessControlType -eq 'Allow' })
        if ($rules.Count -le 3) { ok '.env com ACL restrita (SR-002).' }
        else { warn ".env com $($rules.Count) entradas de acesso (esperado <= 3)." }
    }
    # O default 'changeme-root' do compose NUNCA pode estar em vigor
    if ((Read-EnvValue $envFile 'DB_ROOT_PASSWORD')) {
        ok "DB_ROOT_PASSWORD definido no .env (default 'changeme-root' do compose nao esta em vigor)."
    } else {
        warn "DB_ROOT_PASSWORD ausente no .env - o MariaDB do container pode ter aceitado o default 'changeme-root'. Corrija o .env e realinhe a senha (ou -ResetDb)."
    }
    # Informativo: usuario do processo da app dentro do container (imagem do repo)
    $cuser = (& docker inspect -f '{{.Config.User}}' $AppCname 2>$null)
    if (-not $cuser) { $cuser = 'root (default da imagem)' }
    info "Processo da app roda como: $cuser no container (definido pela imagem do repositorio)."
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
    ok 'SisPatrimonio Pro instalado com sucesso (DOCKER)!'
    Write-Host '  ==============================================================' -ForegroundColor White
    Write-Host ''
    Write-Host '  ACESSO' -ForegroundColor White
    Write-Host ("    Aplicacao    : http://{0}:{1}" -f $ip, $AppPort)
    Write-Host ("    Swagger API  : http://{0}:{1}/docs" -f $ip, $AppPort)
    Write-Host ("    Health check : http://{0}:{1}/health" -f $ip, $AppPort)
    Write-Host ''
    Write-Host '  INSTALACAO' -ForegroundColor White
    Write-Host ('    Diretorio    : ' + $InstallDir)
    Write-Host ('    Compose      : ' + (Join-Path $InstallDir 'docker-compose.yml') + ' (versionado no repo - nao alterado)')
    Write-Host ('    Containers   : ' + $AppCname + ' | ' + $DbCname)
    Write-Host ('    Volumes      : ' + $DbVolume + ' (banco) | dados da app: backups/logs')
    Write-Host ('    Configuracao : ' + (Join-Path $InstallDir '.env') + ' (ACL restrita - contem credenciais)')
    Write-Host ('    Log          : ' + $InstallLog)
    Write-Host ''
    Write-Host ('  GERENCIAR OS CONTAINERS (cd ' + $InstallDir + ')') -ForegroundColor White
    Write-Host '    docker compose ps          # estado'
    Write-Host '    docker compose logs -f app # logs da aplicacao'
    Write-Host '    docker compose restart app # reiniciar aplicacao'
    Write-Host '    docker compose stop        # parar tudo (persistencia mantida)'
    Write-Host '    docker compose up -d       # subir novamente'
    Write-Host ''
    Write-Host ('  BACKUP DO BANCO (exemplo - senha em ' + (Join-Path $InstallDir '.env') + ')') -ForegroundColor White
    Write-Host ("    cd `"$InstallDir`"")
    Write-Host "    `$root = (Get-Content .env | Where-Object { `$_ -match '^DB_ROOT_PASSWORD=' }) -replace '^DB_ROOT_PASSWORD=',''"
    Write-Host '    $env:MYSQL_PWD = $root'
    Write-Host ("    docker compose exec -T -e MYSQL_PWD=`$root db mariadb-dump -uroot $DbNameResolved > backup-`$(Get-Date -Format yyyy-MM-dd).sql")
    Write-Host ''
    Write-Host '  PRIMEIRO ADMINISTRADOR (escolha um caminho - nunca exibimos senhas)' -ForegroundColor White
    Write-Host '    A) CLI (recomendado):'
    Write-Host ("       cd `"$InstallDir`"")
    Write-Host '       docker compose exec app python3 -m app.cli create-user --username admin --name "Administrador" --admin'
    Write-Host '       (a senha e solicitada de forma oculta; minimo 8 caracteres)'
    Write-Host '    B) Primeiro acesso: abra a aplicacao e use a pagina /setup'
    Write-Host '       (disponivel enquanto nao existir nenhum usuario)'
    Write-Host '    C) Variaveis de ambiente: AUTH_ADMIN_USERNAME/AUTH_ADMIN_PASSWORD'
    Write-Host '       no .env antes do primeiro start (remova apos o primeiro login)'
    Write-Host ''
    Write-Host '  As senhas do banco NAO aparecem neste resumo nem no log - estao'
    Write-Host '  apenas no .env (DB_PASSWORD, DB_ROOT_PASSWORD e SECRET_KEY), com ACL restrita.'
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
    info "SisPatrimonio Pro - Instalador WINDOWS via DOCKER v$AppVersionInstaller ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
    Write-Host '=============================================================='
    Write-Host ''

    Detect-Host

    # Prerequisitos ADITIVOS e idempotentes antes da confirmacao (mesma
    # adaptacao do R12 feita no install-docker.sh)
    Write-Step 'Docker, Compose v2 e pacotes base'  ; Ensure-Packages
    Write-Step 'Codigo-fonte (clone)'                ; Ensure-Repo
    Write-Step 'docker-compose.yml do repo (analise)'; Parse-ComposeConfig

    Collect-Secrets

    # Interacao ANTES das mutacoes de aplicacao (R12/R13 adaptado)
    Confirm-Plan
    Confirm-ResetDb

    Write-Step 'Arquivo de configuracao .env'       ; Ensure-EnvFile
    Write-Step 'Build da imagem da aplicacao'      ; Invoke-ComposeBuild
    Write-Step 'Banco de dados (container MariaDB)'; Ensure-Database
    Write-Step 'Inicializacao do schema (init_db)' ; Init-Database
    Write-Step 'Start + health check'              ; Start-AndHealthCheck
    Write-Step 'Bateria pos-instalacao'            ; Post-InstallChecks
    Write-Step 'Auditoria de seguranca'            ; Security-SelfCheck

    # Regra de firewall para acesso via rede (idempotente por nome; sem ela
    # o Windows bloqueia a porta por padrao - divergencia necessaria do Linux)
    $fw = Get-NetFirewallRule -DisplayName "SisPatrimonio Pro Docker ($AppPort)" -ErrorAction SilentlyContinue
    if (-not $fw) {
        New-NetFirewallRule -DisplayName "SisPatrimonio Pro Docker ($AppPort)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([int]$AppPort) -ErrorAction Stop | Out-Null
        ok "Regra de firewall de entrada criada para a porta $AppPort (acesso via rede)."
    }

    Print-Summary
    ok 'Concluido.'
}

Main
