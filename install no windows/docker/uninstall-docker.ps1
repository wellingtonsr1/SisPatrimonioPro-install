<#
.SYNOPSIS
    SisPatrimonio Pro - Desinstalador de Producao WINDOWS via DOCKER

.DESCRIPTION
    Versao Windows (PowerShell) do uninstall-docker.sh. Reverte a instalacao
    criada por install-docker.ps1, nesta ordem:
      1. containers (stop/down do Compose - app + db) + regra de firewall
      2. volume do banco db-data (SOMENTE com confirmacao digitando o nome)
      3. volume app-data - backups/logs da app (SOMENTE com confirmacao propria)
      4. diretorio da aplicacao (codigo, .env, docker-compose.yml do clone)
      5. imagem da app (build local) e imagem mariadb:11 (apenas se orfas)
      6. log do instalador

    Seguranca (mesmos principios do uninstall-docker.sh - SR-001..SR-005):
      - NADA destrutivo sem confirmacao explicita (ou -Yes para o basico);
      - volume do banco NUNCA e apagado por engano: exige digitar o nome do banco;
      - -PurgeDocker remove imagens (app + mariadb) - dupla confirmacao;
      - detecta banco/volume a partir do .env + compose instalados (nao hardcode);
      - idempotente: pode ser executado repetidamente; nada de erros feios.

    Diferencas em relacao ao nativo (mesma filosofia, alvo docker):
      - nao ha tarefa agendada nem usuario Linux: containers + volumes + imagens;
      - o Docker Desktop/Engine instalado NUNCA e removido por este script -
        mesmo -PurgeDocker remove apenas as IMAGENS do projeto.

.USO
    powershell -ExecutionPolicy Bypass -File uninstall-docker.ps1                    # interativo
    powershell -ExecutionPolicy Bypass -File uninstall-docker.ps1 -Yes               # containers+diretorio+imagens orfas;
                                                                                     # VOLUME do banco ainda exige confirmacao
    powershell -ExecutionPolicy Bypass -File uninstall-docker.ps1 -KeepDb            # NAO toca no volume do banco
    powershell -ExecutionPolicy Bypass -File uninstall-docker.ps1 -PurgeDocker       # tambem remove as imagens do projeto
    powershell -ExecutionPolicy Bypass -File uninstall-docker.ps1 -InstallDir Z

    Codigo 100% ASCII: evita corrupcao de acentos em Windows PowerShell 5.1.

.NOTES
    Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$KeepDb,
    [switch]$PurgeDocker,
    [string]$InstallDir,
    [switch]$Help
)

# EAP=Continue: comandos nativos (docker/compose) escrevem em stderr e, no
# Windows PowerShell 5.1 com EAP=Stop, o redirecionamento 2>/1> promove essas
# linhas a erros terminantes espurios. Chamadas nativas sao validadas por
# $LASTEXITCODE; cmdlets criticos usam -ErrorAction Stop explicito.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Version    = '2.1.0-docker-win'
$InstallLog = Join-Path $env:ProgramData 'sispatrimonio-install-docker.log'
$FwRuleName = 'SisPatrimonio Pro Docker'
$DbImageDefault = 'mariadb:11'

$script:AssumeYes = $Yes
$script:DbName    = ''
$script:DbVolume  = ''
$script:AppVolume = ''
$script:AppImage  = ''
$script:AppCname  = 'sispat-app'
$script:DbCname   = 'sispat-db'

# ----------------------------------------------------------------------------
# Log (mesma filosofia do install-docker.ps1)
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
SisPatrimonio Pro - desinstalador de producao WINDOWS via DOCKER v$Version

Uso: powershell -ExecutionPolicy Bypass -File uninstall-docker.ps1 [opcoes]

  -Yes                Nao pede confirmacao para containers/diretorio/imagens
                      orfas (o VOLUME DO BANCO continua exigindo confirmacao
                      explicita digitando o nome do banco)
  -KeepDb             Nao apaga o volume do banco (dados preservados)
  -PurgeDocker        Tambem remove as imagens do projeto (app local + mariadb
                      SE nao for usada por outros containers - destrutivo;
                      exige dupla confirmacao). O Docker Engine NUNCA e removido.
  -InstallDir <caminho>   Default: C:\SisPatrimonioPro
  -Help               Esta ajuda

Ordem da remocao:
  1. containers (compose down)  2. volume do banco (confirmacao digitando o nome)
  3. volume app-data (backups/logs - confirmacao propria)  4. diretorio da app
  5. imagens do projeto (com -PurgeDocker)  6. log do instalador

Exit codes: 0 sucesso | 2 uso invalido | 1 falha de execucao
"@
}

function Parse-Args {
    if ($Help) { Show-Usage; exit 0 }
    if (-not $InstallDir) { $script:InstallDir = 'C:\SisPatrimonioPro' }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { die '-InstallDir nao pode ser vazio.' }
}

function Test-Confirmed([string]$Question) {
    if ($script:AssumeYes) { return $true }
    # Entrada vazia/EOF => NAO confirmar (padrao de preservacao)
    $ans = Read-Host $Question
    return ($ans -match '^(s|S|sim|SIM|y|Y)$')
}

function Test-DockerOk {
    # daemon disponivel? (desinstalacao segue mesmo sem Docker - idempotencia)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-DCC {
    # compose com projeto/diretorio fixos; a saida flui para o console e o
    # codigo de saida fica em $LASTEXITCODE (nativo)
    & docker compose --project-directory $InstallDir -f (Join-Path $InstallDir 'docker-compose.yml') @args
}

function Get-ComposeProjectName {
    # nome de projeto do Compose derivado do diretorio (mesma regra do Compose)
    $proj = ((Split-Path $InstallDir -Leaf).ToLower() -replace '[^a-z0-9_-]', '-')
    if (-not $proj) { $proj = 'sispatrimoniopro' }
    return $proj
}

function Get-VolumeList {
    & docker volume ls --format '{{.Name}}' 2>$null
}

function Test-VolumeExists([string]$Name) {
    @((Get-VolumeList)) -contains $Name
}

function Detect-FromEnvAndCompose {
    # .env (banco) + compose (volume/containers), sem exibir segredos
    $detected = $false

    # --- nome do banco a partir do compose (fonte da verdade) ou fallback ---
    if ((Test-Path (Join-Path $InstallDir 'docker-compose.yml')) -and (Test-DockerOk)) {
        $composeFile = Join-Path $InstallDir 'docker-compose.yml'
        $tmpEnv = New-TemporaryFile
        Set-Content $tmpEnv "DB_PASSWORD=dummy`nSECRET_KEY=dummy`nDB_ROOT_PASSWORD=dummy`nAPP_PORT=8000"
        $raw = & docker compose --project-directory $InstallDir -f $composeFile --env-file $tmpEnv config --format json 2>$null
        Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue
        if ($raw) {
            try {
                $cfg = ($raw -join '') | ConvertFrom-Json
                $db = $cfg.services.db
                $app = $cfg.services.app
                if ($app.container_name) { $script:AppCname = [string]$app.container_name }
                if ($db.container_name)  { $script:DbCname  = [string]$db.container_name }
                if ($app.image)          { $script:AppImage = [string]$app.image }

                $dbenv = $db.environment
                if ($dbenv -is [pscustomobject]) {
                    $script:DbName = [string]$dbenv.MARIADB_DATABASE
                } elseif ($dbenv) {
                    foreach ($item in @($dbenv)) {
                        if ($item -match '^MARIADB_DATABASE=(.*)$') { $script:DbName = $Matches[1] }
                    }
                }

                $proj = if ($cfg.name) { [string]$cfg.name } else { Get-ComposeProjectName }
                foreach ($key in @('db-data', 'db_data')) {
                    $v = $cfg.volumes.$key
                    if ($v -and $v.name) { $script:DbVolume = [string]$v.name; break }
                }
                foreach ($key in @('app-data', 'app_data')) {
                    $v = $cfg.volumes.$key
                    if ($v -and $v.name) { $script:AppVolume = [string]$v.name; break }
                }
                if ($DbName) { $detected = $true }
            } catch { }
        }
    }

    # --- fallback: banco mencionado no .env (DB_NAME/DATABASE_URL) ---
    if (-not $detected) {
        $envFile = Join-Path $InstallDir '.env'
        if (Test-Path $envFile) {
            $n = ''
            $url = ''
            foreach ($line in (Get-Content $envFile)) {
                if     ($line -match '^DB_NAME=(.+)$')      { $n = $Matches[1].Trim(); break }
                elseif ($line -match '^DATABASE_URL=(.+)$') { $url = $Matches[1].Trim() }
            }
            if (-not $n -and $url -and $url -match '^.*/([^/?]+)(\?.*)?$') { $n = $Matches[1] }
            if ($n) { $script:DbName = $n; $detected = $true }
        }
    }

    # --- volume: se o compose nao resolveu, deriva do diretorio (padrao do Compose) ---
    if (-not $DbVolume)  { $script:DbVolume  = "$(Get-ComposeProjectName)_db-data" }
    if (-not $AppVolume) { $script:AppVolume = "$(Get-ComposeProjectName)_app-data" }

    return $detected
}

function Remove-Containers {
    info 'Containers (compose down)'
    if (-not (Test-DockerOk)) {
        warn 'Docker indisponivel - containers NAO removidos nesta execucao (reexecute com o Docker ativo).'
        return
    }
    if ((Test-Path (Join-Path $InstallDir 'docker-compose.yml')) -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        $running = @(& docker compose --project-directory $InstallDir -f (Join-Path $InstallDir 'docker-compose.yml') ps -q 2>$null)
        $byname = @(& docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -eq $AppCname -or $_ -eq $DbCname })
        if (($running | Where-Object { $_ }) -or $byname) {
            Invoke-DCC down --remove-orphans *> $null
            ok "Containers do projeto removidos ($AppCname, $DbCname)."
        } else {
            ok 'Nenhum container do projeto em execucao - nada a fazer.'
        }
    } else {
        # Sem compose: remove containers por nome (best-effort, idempotente)
        $removed = 0
        foreach ($c in @($AppCname, $DbCname)) {
            if (@(& docker ps -a --format '{{.Names}}' 2>$null) -contains $c) {
                & docker rm -f $c *> $null
                $removed++
            }
        }
        if ($removed -gt 0) { ok "$removed container(s) removido(s) por nome (compose ausente)." }
        else { ok 'Nenhum container do projeto encontrado - nada a fazer.' }
    }
    $fw = Get-NetFirewallRule -DisplayName "$FwRuleName*" -ErrorAction SilentlyContinue
    if ($fw) {
        $fw | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        ok 'Regra de firewall da aplicacao removida.'
    }
}

function Remove-DbVolume {
    # VOLUME DO BANCO = todos os dados: confirmacao digitando o nome (mesmo com -Yes)
    info 'Volume do banco de dados'
    if ($KeepDb) {
        warn "Desinstalacao com -KeepDb: volume do banco PRESERVADO ($DbVolume)."
        return
    }
    if (-not (Test-DockerOk)) {
        warn "Docker daemon indisponivel - volume '$DbVolume' PRESERVADO (reexecute com o Docker ativo para remove-lo)."
        return
    }
    if (-not (Test-VolumeExists $DbVolume)) {
        ok "Volume '$DbVolume' nao existe - nada a fazer."
        return
    }
    if ($DbName) {
        warn "O volume do banco '$DbVolume' contem o banco '$DbName' e TODOS os seus dados."
    } else {
        warn "O volume do banco '$DbVolume' contem TODOS os dados do banco."
    }
    # Confirmacao OBRIGATORIA (mesmo com -Yes): digitar o nome do banco
    $c1 = Read-Host "Digite o nome do banco para CONFIRMAR a remocao do volume '$DbVolume' (vazio = preservar)"
    if (-not $DbName) {
        if ($c1 -eq $DbVolume) {
            # aceita o nome do volume como confirmacao quando o banco e desconhecido
            $script:DbName = $DbVolume
        } else {
            warn 'Banco PRESERVADO (confirmacao nao recebida).'
            return
        }
    }
    if ($c1 -ne $DbName) {
        warn 'Banco PRESERVADO (confirmacao nao recebida).'
        return
    }
    & docker volume rm $DbVolume *> $null
    if ($LASTEXITCODE -ne 0) {
        warn 'Nao foi possivel remover o volume (em uso?). Pare os containers e reexecute.'
        return
    }
    ok "Volume '$DbVolume' (banco '$DbName') removido."
}

function Remove-AppVolume {
    # backups/logs da app - decisao separada (nao e o banco)
    info 'Volume app-data (backups/logs da aplicacao)'
    if (-not (Test-DockerOk)) {
        warn 'Docker daemon indisponivel - volume app-data PRESERVADO.'
        return
    }
    $av = $AppVolume
    if (-not $av) { $av = "$(Get-ComposeProjectName)_app-data" }
    if (-not (Test-VolumeExists $av)) {
        ok "Volume '$av' nao existe - nada a fazer."
        return
    }
    if (Test-Confirmed "Remover o volume '$av' (backups/logs da aplicacao - irreversivel)? (s/N): ") {
        & docker volume rm $av *> $null
        if ($LASTEXITCODE -eq 0) { ok "Volume '$av' removido." }
        else { warn "Nao foi possivel remover o volume '$av' (em uso?)." }
    } else {
        warn "Volume app-data PRESERVADO por solicitacao (backups mantidos no Docker)."
    }
}

function Remove-AppDir {
    # codigo, .env (com credenciais) e clone - decisao do operador
    info 'Diretorio da aplicacao'
    if (Test-Path $InstallDir) {
        if (Test-Confirmed "Remover $InstallDir INTEIRO (codigo, .env com credenciais, compose do clone - irreversivel)? (s/N): ") {
            Remove-Item -Recurse -Force $InstallDir -ErrorAction Stop
            ok 'Diretorio removido.'
        } else {
            warn 'Diretorio PRESERVADO por solicitacao (.env mantido - remova manualmente se nao precisar das credenciais).'
        }
    } else {
        ok "$InstallDir nao existe - nada a fazer."
    }
}

function Purge-Images {
    # DESTRUTIVO OPCIONAL (-PurgeDocker): imagens do projeto - dupla confirmacao (padrao 027)
    if (-not $PurgeDocker) { return }
    info 'Remocao das imagens do projeto (solicitada via -PurgeDocker)'
    if (-not (Test-DockerOk)) {
        warn 'Docker daemon indisponivel - imagens PRESERVADAS.'
        return
    }
    warn '================================================================'
    warn 'ATENCAO: isto remove as imagens construidas para este projeto.'
    warn 'Outros containers/imagens do servidor NAO sao afetados; o Docker'
    warn 'Desktop/Engine (daemon) NUNCA e removido por este script.'
    warn '================================================================'
    $c1 = Read-Host "Digite EXATAMENTE 'PURGAR-IMAGENS' para confirmar"
    if ($c1 -ne 'PURGAR-IMAGENS') { warn 'Imagens PRESERVADAS.'; return }
    $c2 = Read-Host 'Confirmar novamente (s/N)'
    if ($c2 -notmatch '^(s|S|sim|SIM|y|Y)$') { warn 'Imagens PRESERVADAS.'; return }

    # Imagem da app: resolvida do compose (services.app.image) ou candidatos
    # usuais de build local; ultima alternativa: derivada do diretorio
    $removed = 0
    $candidates = @()
    if ($AppImage) { $candidates += $AppImage }
    $candidates += ("$(Get-ComposeProjectName)-app", 'sispatrimoniopro-app', 'sispat-app')
    foreach ($img in $candidates) {
        & docker image inspect $img *> $null
        if ($LASTEXITCODE -eq 0) {
            & docker rmi $img *> $null
            if ($LASTEXITCODE -eq 0) { ok "Imagem da app removida: $img"; $removed++ }
            else { warn "Imagem da app '$img' esta EM USO por um container - nao removida." }
            break
        }
    }

    # mariadb:11: remove APENAS se nenhum outro container a referencia (orfa)
    & docker image inspect $DbImageDefault *> $null
    if ($LASTEXITCODE -eq 0) {
        $users = @(& docker ps -a --filter "ancestor=$DbImageDefault" --format '{{.ID}}' 2>$null)
        if (-not ($users | Where-Object { $_ })) {
            & docker rmi $DbImageDefault *> $null
            if ($LASTEXITCODE -eq 0) { ok "Imagem orfa removida: $DbImageDefault"; $removed++ }
            else { warn "Nao foi possivel remover $DbImageDefault." }
        } else {
            ok "Imagem $DbImageDefault ainda referenciada por outros containers - PRESERVADA."
        }
    }

    if ($removed -eq 0) { ok 'Nenhuma imagem do projeto precisou ser removida.' }
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
    info "SisPatrimonio Pro - Desinstalador WINDOWS via DOCKER v$Version ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
    if (-not $AssumeYes) {
        $gate = Read-Host 'Desinstalar o SisPatrimonio Pro (DOCKER) deste servidor? (s/N)'
        if ($gate -notmatch '^(s|S|sim|SIM|y|Y)$') {
            die 'Desinstalacao cancelada. Nada foi alterado.'
        }
    }

    # Deteccao ANTES de remover o diretorio (compose + .env sao a fonte do
    # banco/volume - mesma logica do detect_from_env_and_compose)
    if (Detect-FromEnvAndCompose) {
        ok "Configuracao detectada: banco '$DbName' | volume '$DbVolume' (senhas NUNCA exibidas)."
    } else {
        warn 'compose/.env nao encontrados/legiveis - o volume sera inferido do diretorio; o nome do banco sera pedido na etapa de banco.'
    }

    Remove-Containers
    Remove-DbVolume
    Remove-AppVolume
    Remove-AppDir
    Purge-Images
    Remove-InstallLog

    Write-Host ''
    ok 'Desinstalacao concluida.'
    if ($KeepDb) { warn 'Lembrete: volume do banco foi PRESERVADO (-KeepDb).' }
    warn 'Docker Desktop/Engine e demais imagens/containers do servidor foram mantidos - remova manualmente se desejar.'
}

Main
