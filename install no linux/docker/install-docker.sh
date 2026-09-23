#!/usr/bin/env bash
# ============================================================================
# SisPatrimônio Pro — Instalador Automatizado de Produção Linux via DOCKER
# (variante Docker do instalador original — install.sh permanece intacto)
#
# Prepara um servidor Debian/Ubuntu (ou derivada com apt + systemd) para
# executar o SisPatrimônio Pro em produção usando o Docker Compose DO
# PRÓPRIO REPOSITÓRIO (docker-compose.yml + Dockerfile versionados no repo):
#   pré-requisitos → Docker Engine + Compose v2 → Git → clone
#   → análise do compose do repo → .env (0600) → build da imagem
#   → container MariaDB (volume db-data) → init_db → app → /health → resumo
#
# Arquitetura (definida pelo compose do repositório — fonte da verdade):
#   ┌────────────────────────┐        ┌───────────────────────────────┐
#   │ container sispat-app   │        │ container sispat-db           │
#   │ imagem: build local    │ ─────► │ imagem: mariadb:11            │
#   │ host ${APP_PORT}→8000  │ rede   │ volume: <projeto>_db-data     │
#   │ volume: <projeto>_app-data (backups/logs da app)                │
#   └────────────────────────┘        └───────────────────────────────┘
#   Sem systemd para a aplicação: `restart: unless-stopped` + healthcheck.
#   Banco/usuário fixados pelo compose: sispatrimonio_pro / sispatrimonio.
#
# Idempotente (mesma filosofia do install.sh): cada etapa detecta o estado
# anterior e REUTILIZA o que já existe. O .env NUNCA é sobrescrito (backup +
# mescla apenas de chaves ausentes). O volume do banco NUNCA é apagado —
# recriação somente via --reset-db, com dupla confirmação interativa
# (e afeta SOMENTE o volume do banco: app-data — backups/logs — é preservado).
#
# Segurança (mesmos princípios SR-001..SR-005 do install.sh):
#   - senha do banco coletada SEM ECO ou gerada via secrets; NUNCA em argv
#     visível (MYSQL_PWD via `docker compose exec -e`), NUNCA no log;
#   - SECRET_KEY e DB_ROOT_PASSWORD sempre geradas pelo instalador (o default
#     'changeme-root' do compose NUNCA entra em produção);
#   - segredos ficam SOMENTE no .env (0600); o compose do repo não contém
#     credenciais literais (apenas referências ${VAR});
#   - o compose do repositório NUNCA é alterado pelo instalador.
#
# Uso:
#   sudo bash install-docker.sh
#   sudo bash install-docker.sh --non-interactive --generate-db-password
#   sudo bash install-docker.sh --reset-db   # APAGA o volume do banco (destrutivo)
#
# Contrato base: specs/027-instalador-producao-linux/contracts/installer-contract.md
# (variante Docker mantém o mesmo contrato, trocando systemd/venv/MariaDB
# nativo por Docker Compose com os arquivos versionados no repositório)
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ----------------------------------------------------------------------------
# Constantes e defaults
# ----------------------------------------------------------------------------
readonly DEFAULT_REPO_URL="https://github.com/wellingtonsr1/SisPatrimonioPro.git"
readonly DEFAULT_BRANCH="main"
readonly DEFAULT_INSTALL_DIR="/opt/SisPatrimonioPro"
readonly DEFAULT_APP_PORT="8000"      # porta exposta no HOST (a app escuta 8000 DENTRO do container)
readonly DEFAULT_TZ="America/Recife"  # default do compose do repo
readonly INSTALL_LOG="/var/log/sispatrimonio-install-docker.log"
readonly HEALTH_TIMEOUT_SECONDS=180
readonly DB_WAIT_TIMEOUT_SECONDS=240
readonly APP_INTERNAL_PORT="8000"

APP_VERSION_INSTALLER="2.1.0-docker"
NON_INTERACTIVE="false"
RESET_DB="false"
INSTALL_DIR=""
REPO_URL="$DEFAULT_REPO_URL"
BRANCH="$DEFAULT_BRANCH"
APP_PORT="$DEFAULT_APP_PORT"
GENERATE_DB_PASSWORD="false"
DB_PASSWORD=""
SECRET_KEY=""
DB_ROOT_PASSWORD=""
TZ_VALUE=""

# Valores resolvidos do compose do repositório (parse_compose_config)
APP_CNAME="sispat-app"
DB_CNAME="sispat-db"
DB_NAME=""
DB_USER=""
DB_VOLUME=""
DB_NAME_CLI=""             # --db-name informado na CLI (só conferência contra o compose)
DB_USER_CLI=""             # --db-user informado na CLI (só conferência contra o compose)
DB_NAME_PROVIDED="false"
DB_USER_PROVIDED="false"

REUSED_ENV="false"          # true quando .env existente foi reutilizado (credenciais dele)
EXISTING_VOLUME="false"     # volume do banco já existe antes desta execução
EXISTING_ENV="false"        # .env já existe antes desta execução
MYSQLDUMP_DETECTED=""       # caminho do mysqldump DENTRO da imagem (se houver)

STEP=""
STEP_NO=0
TOTAL_STEPS=10

# ----------------------------------------------------------------------------
# Log (mesma filosofia do install.sh: níveis INFO/OK/WARNING/ERROR + arquivo
# 0600, cores só em TTY, arquivo SEMPRE com texto limpo)
# ----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ] && command -v tput >/dev/null 2>&1 \
    && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_BLUE=$(tput setaf 4)
    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3)
    C_RED=$(tput setaf 1)
else
    C_RESET=''
    C_BOLD=''
    C_BLUE=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
fi

_msg() {  # $1=cor da tag  $2=tag  $3...=mensagem — SEMPRE stderr (canal único)
    local color="$1" tag="$2"
    shift 2
    printf '[%s%5s%s] %s\n' "$color" "$tag" "$C_RESET" "$*" >&2
}
info()  { _msg "$C_BLUE"   "INFO " "$@"; }
ok()    { _msg "$C_GREEN"  " OK  " "$@"; }
warn()  { _msg "$C_YELLOW" "AVISO" "$@"; }
err()   { _msg "$C_RED"    "ERRO " "$@"; }

setup_logging() {
    touch "$INSTALL_LOG" 2>/dev/null || true
    chmod 600 "$INSTALL_LOG" 2>/dev/null || true
    # Log SEMPRE limpo: remove sequências ANSI (a tela pode ter cor; o arquivo, não)
    exec > >(tee >(sed -u 's/\x1B\[[0-9;]*[A-Za-z]//g' >> "$INSTALL_LOG")) 2>&1
}

prompt_printf() {  # prompt no canal stderr — MESMA fila do restante da saída
    printf '%s' "$*" >&2
}

on_error() {  # caixa visual de falha — conteúdo/garantias preservados do install.sh
    local exit_code=$?
    {
        echo "${C_RESET}${C_RED}"
        echo "  ┌── INSTALAÇÃO INTERROMPIDA ──────────────────────────"
        echo "  │ Etapa: ${STEP:-desconhecida} (exit $exit_code, linha ${1:-?})"
        echo "  │ Log completo: $INSTALL_LOG (sem credenciais)"
        echo "  │ Corrija o problema e reexecute o instalador — ele é"
        echo "  │ idempotente e reutiliza o que já foi concluído"
        echo "  │ (nenhum dado é apagado; o volume do banco só é"
        echo "  │  afetado com --reset-db e dupla confirmação)."
        echo "  └─────────────────────────────────────────────────────"
        printf '%s\n' "$C_RESET"
    } >&2
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

die() { err "$*"; exit 1; }

run_step() {  # rotula a etapa atual para o trap ERR; numera a fase na tela
    STEP="$1"
    shift
    STEP_NO=$((STEP_NO + 1))
    echo "${C_BOLD}── [${STEP_NO}/${TOTAL_STEPS}] ${STEP}${C_RESET}" >&2
    "$@"
}

_kv() {  # par "label : valor" — label JÁ vem pré-padded do chamador
    printf '  %s: %s\n' "$1" "$2" >&2
}

# ----------------------------------------------------------------------------
# Coleta de senha SEM ECO (SR-001): idêntico ao install.sh
# ----------------------------------------------------------------------------
prompt_secret() {  # $1=prompt → senha na stdout da função
    local prompt="$1" value confirm
    prompt_printf "$prompt"
    read -rs value
    prompt_printf $'\n'
    prompt_printf "Confirme a senha (vazio nas duas = gerar automaticamente): "
    read -rs confirm
    prompt_printf $'\n'
    if [ -z "$value" ] && [ -z "$confirm" ]; then
        return 0
    fi
    if [ -z "$value" ] || [ "$value" != "$confirm" ]; then
        die "As senhas não conferem (ou primeira vazia e confirmação preenchida). Operação abortada."
    fi
    printf '%s' "$value"
}

generate_secret() {  # segredo criptograficamente seguro (SR-002)
    python3 -c 'import secrets; print(secrets.token_urlsafe(24))'
}

generate_hex_key() {  # chave de sessão (formato recomendado no cabeçalho do compose)
    python3 -c 'import secrets; print(secrets.token_hex(32))'
}

system_timezone() {  # TZ do servidor; fallback = default do compose
    local tz=""
    if command -v timedatectl >/dev/null 2>&1; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    [ -n "$tz" ] || tz="$(cat /etc/timezone 2>/dev/null || true)"
    [ -n "$tz" ] || tz="$DEFAULT_TZ"
    printf '%s' "$tz"
}

# ----------------------------------------------------------------------------
# Parser e validação de CLI
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
SisPatrimônio Pro — instalador de produção Linux via DOCKER v${APP_VERSION_INSTALLER}

Uso: sudo bash install-docker.sh [opções]

  --non-interactive           Nenhum prompt; exige --db-password ou --generate-db-password
  --install-dir <caminho>     Diretório de instalação (default: ${DEFAULT_INSTALL_DIR})
  --repo <url>                Repositório Git (default: repo oficial)
  --branch <nome>             Branch (default: ${DEFAULT_BRANCH})
  --db-password <senha>       Senha do banco (não interativo; NÃO use em produção compartilhada)
  --generate-db-password      Gera senha forte automaticamente (vai direto ao .env)
  --db-name <nome>            SOMENTE para conferência: o compose do repo fixa o banco
                              (sispatrimonio_pro) — valor divergente aborta a instalação
  --db-user <usuário>         SOMENTE para conferência: o compose do repo fixa o usuário
                              (sispatrimonio) — valor divergente aborta a instalação
  --app-port <porta>          Porta da aplicação no HOST (default: ${DEFAULT_APP_PORT})
  --reset-db                  APAGA o volume do banco e recria do zero (SÓ interativo;
                              dupla confirmação; proibido com --non-interactive;
                              NÃO afeta o volume app-data — backups/logs preservados)
  --app-host <host>           Sem efeito nesta variante (o compose publica em 0.0.0.0)
  --service-name <nome>       Sem efeito (projeto Compose deriva do diretório de instalação)
  --service-user <usuário>    Sem efeito (containers usam os usuários internos da imagem)
  --help                      Esta ajuda

Nota: esta variante usa o docker-compose.yml + Dockerfile versionados no
PRÓPRIO repositório (app + MariaDB em containers). Para a instalação NATIVA
(systemd + MariaDB do host), use install.sh.

Exit codes: 0 sucesso · 2 uso inválido · 1 falha de execução
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE="true" ;;
            --install-dir)     INSTALL_DIR="${2:-}"; shift ;;
            --repo)            REPO_URL="${2:-}"; shift ;;
            --branch)          BRANCH="${2:-}"; shift ;;
            --db-name)         DB_NAME_CLI="${2:-}"; DB_NAME_PROVIDED="true"; shift ;;
            --db-user)         DB_USER_CLI="${2:-}"; DB_USER_PROVIDED="true"; shift ;;
            --db-password)     DB_PASSWORD="${2:-}"; shift ;;
            --generate-db-password) GENERATE_DB_PASSWORD="true" ;;
            --app-port)        APP_PORT="${2:-}"; shift ;;
            --reset-db)        RESET_DB="true" ;;
            --app-host)        warn "--app-host é sem efeito nesta variante (o compose publica a porta em 0.0.0.0)."; shift ;;
            --service-name)    warn "--service-name é sem efeito nesta variante (projeto Compose deriva do diretório de instalação)."; shift ;;
            --service-user)    warn "--service-user é sem efeito nesta variante (containers usam os usuários internos da imagem)."; shift ;;
            --help|-h)         usage; exit 0 ;;
            *)                 usage; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
}

validate_identifier() {  # identificadores SQL/Linux sem risco de injeção
    local label="$1" value="$2" pattern="$3"
    if ! printf '%s' "$value" | grep -qE "$pattern"; then
        die "$label inválido: '$value' (esperado: $pattern)"
    fi
}

# O compose do repo interpola a senha DIRETAMENTE na DATABASE_URL (sem percent-
# encoding) e em valores YAML. Restrição por ALLOWLIST (não blocklist): apenas
# caracteres seguros nos dois contextos. A senha gerada (token_urlsafe) atende.
validate_password_docker() {
    if ! printf '%s' "$DB_PASSWORD" | grep -qE '^[A-Za-z0-9_.+-]{12,128}$'; then
        die "Senha manual contém caracteres não suportados nesta variante (use apenas letras, números e _ . + - ; mínimo 12). Deixe vazia para gerar automaticamente."
    fi
}

validate_inputs() {  # validação TOTAL antes da primeira mutação
    [ -n "$INSTALL_DIR" ] || INSTALL_DIR="$DEFAULT_INSTALL_DIR"

    if [ "$DB_NAME_PROVIDED" = "true" ]; then
        validate_identifier "Nome do banco" "$DB_NAME_CLI" '^[A-Za-z_][A-Za-z0-9_]*$'
    fi
    if [ "$DB_USER_PROVIDED" = "true" ]; then
        validate_identifier "Usuário do banco" "$DB_USER_CLI" '^[A-Za-z_][A-Za-z0-9_]*$'
    fi

    if ! printf '%s' "$APP_PORT" | grep -qE '^[0-9]+$' || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
        die "Porta da aplicação inválida: $APP_PORT (1–65535)"
    fi

    # Recriação do volume é PROIBIDA em modo não interativo (mesma decisão D2)
    if [ "$RESET_DB" = "true" ] && [ "$NON_INTERACTIVE" = "true" ]; then
        die "Combinação inválida: --reset-db é proibida com --non-interactive."
    fi

    # No modo não interativo, senha deve ser fornecida ou marcada como gerada
    if [ "$NON_INTERACTIVE" = "true" ]; then
        if [ "$GENERATE_DB_PASSWORD" != "true" ] && [ -z "$DB_PASSWORD" ]; then
            die "Modo não interativo exige --db-password ou --generate-db-password."
        fi
    fi

    if [ -n "$DB_PASSWORD" ] && [ "$GENERATE_DB_PASSWORD" = "true" ]; then
        die "Use apenas uma: --db-password OU --generate-db-password."
    fi

    if [ -n "$DB_PASSWORD" ]; then
        validate_password_docker
    fi
}

# ----------------------------------------------------------------------------
# Credenciais: coleta (interativa) ou REUSO do .env existente (idempotência)
# ----------------------------------------------------------------------------
reuse_env_file() {  # lê o .env existente e usa as MESMAS credenciais (nada é sobrescrito)
    local env_file="$INSTALL_DIR/.env"
    DB_PASSWORD="$(grep -E '^DB_PASSWORD=' "$env_file" | head -1 | cut -d= -f2- || true)"
    if [ -z "$DB_PASSWORD" ]; then
        die ".env existente sem DB_PASSWORD — impossível reutilizar. Faça backup, remova/mova o .env e reexecute."
    fi

    SECRET_KEY="$(grep -E '^SECRET_KEY=' "$env_file" | head -1 | cut -d= -f2- || true)"
    if [ -z "$SECRET_KEY" ]; then
        warn "SECRET_KEY ausente no .env — será GERADA e ADICIONADA (chave ausente; nada existente é alterado)."
        SECRET_KEY="$(generate_hex_key)"
    fi

    DB_ROOT_PASSWORD="$(grep -E '^DB_ROOT_PASSWORD=' "$env_file" | head -1 | cut -d= -f2- || true)"
    if [ -z "$DB_ROOT_PASSWORD" ]; then
        warn "DB_ROOT_PASSWORD ausente no .env — será GERADO e ADICIONADO (o default 'changeme-root' do compose NUNCA é usado)."
        DB_ROOT_PASSWORD="$(generate_secret)"
    fi

    local p
    p="$(grep -E '^APP_PORT=' "$env_file" | head -1 | cut -d= -f2- || true)"
    [ -n "$p" ] || p="$DEFAULT_APP_PORT"
    APP_PORT="$p"

    local tz
    tz="$(grep -E '^TZ=' "$env_file" | head -1 | cut -d= -f2- || true)"
    [ -n "$tz" ] || tz="$(system_timezone)"
    TZ_VALUE="$tz"

    REUSED_ENV="true"
    ok ".env existente será REUTILIZADO — credenciais preservadas, nada será sobrescrito."
}

collect_secrets() {
    STEP="Credenciais e configuração"
    if [ "$EXISTING_ENV" = "true" ]; then
        reuse_env_file
        return
    fi
    if [ "$NON_INTERACTIVE" = "true" ]; then
        if [ "$GENERATE_DB_PASSWORD" = "true" ]; then
            DB_PASSWORD="$(generate_secret)"
            ok "Senha do banco gerada automaticamente (gravada apenas no .env)."
        fi
    elif [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD="$(prompt_secret 'Senha do banco (mín. 12 caracteres; ENTER vazio nas duas = gerar automaticamente): ')"
        if [ -z "$DB_PASSWORD" ]; then
            DB_PASSWORD="$(generate_secret)"
            ok "Senha do banco gerada automaticamente (gravada apenas no .env)."
        else
            validate_password_docker
        fi
    fi
    # SECRET_KEY e DB_ROOT_PASSWORD: SEMPRE geradas (não há uso humano; ficam
    # apenas no .env — o default 'changeme-root' do compose nunca entra em produção)
    SECRET_KEY="$(generate_hex_key)"
    DB_ROOT_PASSWORD="$(generate_secret)"
    TZ_VALUE="$(system_timezone)"
    ok "SECRET_KEY e senha de root do MariaDB geradas (gravadas apenas no .env)."
}

confirm_plan() {
    [ "$NON_INTERACTIVE" = "true" ] && return 0
    true
    echo >&2
    echo "${C_BOLD}  RESUMO DA INSTALAÇÃO (DOCKER — compose do repositório)${C_RESET}" >&2
    _kv "Diretório   " "$INSTALL_DIR"
    _kv "Repositório " "$REPO_URL (branch $BRANCH)"
    _kv "Compose     " "$INSTALL_DIR/docker-compose.yml (versionado no repo — não alterado)"
    _kv "Imagem app  " "build local do Dockerfile do repo (serviço 'app')"
    _kv "Banco       " "$DB_NAME (usuário $DB_USER) — container $DB_CNAME"
    _kv "Volume bd   " "$DB_VOLUME (app-data de backups/logs preservado)"
    _kv "Porta host  " "0.0.0.0:${APP_PORT} → container ${APP_INTERNAL_PORT}"
    _kv "Fuso (TZ)   " "$TZ_VALUE"
    if [ "$REUSED_ENV" = "true" ]; then
        _kv ".env        " "EXISTENTE será reutilizado (credenciais preservadas)"
    fi
    [ "$RESET_DB" = "true" ] && warn "*** --reset-db ATIVO: o volume '$DB_VOLUME' será APAGADO e recriado ***"
    echo >&2
    prompt_printf '  Confirmar e iniciar a instalação? (s/N): '
    read -r answer
    case "$answer" in
        s|S|sim|SIM|y|Y) ok "Confirmado." ;;
        *) die "Instalação cancelada pelo operador. Nada foi alterado." ;;
    esac
}

confirm_reset_db() {  # dupla confirmação digitando o nome do banco (padrão do install.sh)
    [ "$RESET_DB" = "true" ] || return 0
    if [ "$EXISTING_VOLUME" != "true" ]; then
        ok "--reset-db informado, mas nenhum volume de banco existe — nada a apagar."
        return 0
    fi
    warn "=============================================================="
    warn "MODO DESTRUTIVO: --reset-db APAGARÁ o volume '$DB_VOLUME'"
    warn "e TODOS os dados do banco '$DB_NAME'. IRREVERSÍVEL."
    warn "(o volume app-data — backups/logs da aplicação — é PRESERVADO)"
    warn "=============================================================="
    prompt_printf 'Digite o nome do banco para confirmar (1/2): '
    read -r c1
    prompt_printf 'Digite novamente (2/2): '
    read -r c2
    if [ "$c1" != "$DB_NAME" ] || [ "$c2" != "$DB_NAME" ]; then
        die "Confirmação divergente. Operação abortada — nada foi alterado."
    fi
    ok "Dupla confirmação recebida."
}

# ----------------------------------------------------------------------------
# Gates de pré-requisitos (idênticos ao install.sh)
# ----------------------------------------------------------------------------
require_root() {
    STEP="Verificação de privilégios"
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -v 2>/dev/null; then
            ok "Privilégios de administrador via sudo."
            SUDO="sudo"
        else
            die "Este instalador requer execução como root ou via sudo."
        fi
    else
        ok "Executando como root."
        SUDO=""
    fi
}

check_distro() {
    STEP="Verificação da distribuição"
    [ -r /etc/os-release ] || die "Arquivo /etc/os-release não encontrado — distribuição não suportada."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*)
            ok "Distribuição base Debian detectada: ${PRETTY_NAME:-desconhecida}" ;;
        *)
            die "Distribuição não suportada nesta variante (base Debian/Ubuntu esperada): ${PRETTY_NAME:-$ID}." ;;
    esac
    [ -d /run/systemd/system ] || die "systemd não está em execução — pré-requisito para habilitar o daemon do Docker."
    ok "systemd presente."
}

check_connectivity() {
    STEP="Verificação de conectividade"
    command -v git >/dev/null 2>&1 || apt-get install -y git >/dev/null 2>&1 || true
    if git ls-remote --heads "$REPO_URL" "$BRANCH" >/dev/null 2>&1; then
        ok "Repositório acessível e branch '$BRANCH' existe."
    else
        die "Não foi possível acessar $REPO_URL (branch '$BRANCH'). Verifique rede/URL."
    fi
    if command -v apt-get >/dev/null 2>&1; then
        ok "apt disponível."
    else
        die "apt-get não encontrado — gerenciador de pacotes esperado na base Debian."
    fi
}

# ----------------------------------------------------------------------------
# Detecção do ambiente (Docker/Compose, .env, volume — best-effort pré-clone;
# o nome REAL do volume é resolvido depois, no parse do compose)
# ----------------------------------------------------------------------------
detect_host() {
    STEP="Detecção do ambiente"
    if command -v docker >/dev/null 2>&1; then
        ok "Docker CLI detectado: $(docker --version 2>/dev/null || echo 'docker')"
    else
        warn "Docker não encontrado (será instalado)."
    fi
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "Docker Compose v2 detectado."
    else
        warn "Docker Compose v2 não detectado (será instalado)."
    fi

    EXISTING_ENV="false"
    if [ -f "$INSTALL_DIR/.env" ]; then
        EXISTING_ENV="true"
        ok ".env existente detectado em $INSTALL_DIR (credenciais serão REUTILIZADAS)."
    fi

    # Porta do HOST em uso? (reportada antes do start, como no install.sh)
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${APP_PORT}\$"; then
        warn "Porta $APP_PORT já está em uso no host (verifique antes de iniciar o container)."
    fi
}

# ----------------------------------------------------------------------------
# Wrapper do Docker Compose (v2) sempre no contexto do projeto
# ----------------------------------------------------------------------------
DC() {
    docker compose "$@"
}

DCC() {  # compose com projeto/diretório fixos — todas as operações passam por aqui
    DC --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"
}

# ----------------------------------------------------------------------------
# Pacotes: Docker Engine + Compose v2 + git + python3 (host)
# ----------------------------------------------------------------------------
apt_install_pkgs() {
    $SUDO apt-get update -y >&2
    $SUDO apt-get install -y ca-certificates curl "$@" >&2
}

ensure_packages() {
    STEP="Docker Engine, Compose v2 e pacotes base"
    export DEBIAN_FRONTEND=noninteractive

    local need_pkgs=()
    command -v git >/dev/null 2>&1 || need_pkgs+=(git)
    command -v python3 >/dev/null 2>&1 || need_pkgs+=(python3)  # host: geração de segredos e parse do /health
    if [ "${#need_pkgs[@]}" -gt 0 ]; then
        info "Instalando: ${need_pkgs[*]}"
        apt_install_pkgs "${need_pkgs[@]}"
    else
        ok "git e python3 já presentes."
    fi

    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker não encontrado — instalando via get.docker.com (canal oficial Docker)."
        curl -fsSL https://get.docker.com | $SUDO bash >&2
    fi
    command -v docker >/dev/null 2>&1 || die "Docker não disponível mesmo após a instalação (get.docker.com)."
    ok "Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') disponível."

    if ! docker info >/dev/null 2>&1; then
        info "Iniciando o daemon do Docker..."
        $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
        $SUDO systemctl start docker 2>/dev/null || true
        sleep 2
    fi
    docker info >/dev/null 2>&1 || die "Daemon do Docker indisponível (docker info falhou). Verifique: systemctl status docker"
    ok "Daemon do Docker em execução."

    if ! docker compose version >/dev/null 2>&1; then
        warn "Plugin Docker Compose ausente — instalando docker-compose-plugin."
        apt_install_pkgs docker-compose-plugin || die "Não foi possível instalar o Docker Compose v2. Instale manualmente e reexecute."
    fi
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 não disponível (docker compose version falhou)."
    ok "Docker Compose v2 pronto ($(docker compose version --short 2>/dev/null || echo 'v2'))."
}

# ----------------------------------------------------------------------------
# Clone (idêntico ao install.sh)
# ----------------------------------------------------------------------------
ensure_repo() {
    STEP="Obtenção do código-fonte"
    if [ -d "$INSTALL_DIR/.git" ] && git -C "$INSTALL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ok "Clone válido em $INSTALL_DIR — reutilizado (HEAD: $(git -C "$INSTALL_DIR" rev-parse --short HEAD))."
        local dirty
        dirty="$(git -C "$INSTALL_DIR" status --porcelain || true)"
        if [ -n "$dirty" ]; then
            warn "O clone possui alterações locais (git status não vazio). NADA será revertido — revise antes de atualizar."
        fi
        return
    fi
    if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        die "$INSTALL_DIR existe, não está vazio e NÃO é um clone Git válido. Decida o destino do conteúdo (mova/remova manualmente) e reexecute — o instalador não sobrescreve."
    fi
    $SUDO mkdir -p "$(dirname "$INSTALL_DIR")"
    $SUDO git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$INSTALL_DIR"
    ok "Repositório clonado (branch $BRANCH) em $INSTALL_DIR."
}

# ----------------------------------------------------------------------------
# Análise do docker-compose.yml do REPOSITÓRIO (fonte da verdade):
# resolve nomes reais de containers, banco/usuário e volume — e valida os
# parâmetros de CLI contra ele. O compose NUNCA é alterado pelo instalador.
# ----------------------------------------------------------------------------
parse_compose_config() {
    STEP="Análise do docker-compose.yml do repositório"
    [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "docker-compose.yml não encontrado em $INSTALL_DIR — esta variante usa o compose versionado no repositório. Atualize o clone (git pull) e reexecute."
    [ -f "$INSTALL_DIR/Dockerfile" ] || die "Dockerfile não encontrado em $INSTALL_DIR — o compose do repo constrói a imagem da app a partir dele. Atualize o clone (git pull) e reexecute."

    local err_file parsed rc
    err_file="$(mktemp)"
    # Variáveis dummy apenas para satisfazer os ':?' do compose na análise
    # estrutural (NÃO são as credenciais reais; a saída nunca vai ao log).
    parsed="$(DB_PASSWORD=dummy SECRET_KEY=dummy DB_ROOT_PASSWORD=dummy APP_PORT="$APP_PORT" \
        DCC config --format json 2>"$err_file")" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$parsed" ]; then
        sed -n '1,10p' "$err_file" >&2 || true
        rm -f "$err_file"
        die "docker-compose.yml do repositório é inválido ou o Compose é antigo demais para --format json."
    fi
    rm -f "$err_file"

    # Extrai valores e imprime atribuições shell-seguras (shlex.quote)
    # shellcheck disable=SC2016
    eval "$(printf '%s' "$parsed" | python3 -c '
import json, shlex, sys
try:
    cfg = json.load(sys.stdin)
except Exception as e:
    sys.exit(f"JSON do compose config inválido: {e}")
svc = cfg.get("services", {})

def envget(env, key):
    if isinstance(env, dict):
        return env.get(key)
    if isinstance(env, list):
        for item in env:
            if isinstance(item, str) and item.startswith(key + "="):
                return item.split("=", 1)[1]
    return None

app = svc.get("app", {})
db = svc.get("db", {})

app_cname = app.get("container_name") or "sispat-app"
db_cname = db.get("container_name") or "sispat-db"
db_name = envget(db.get("environment"), "MARIADB_DATABASE") or ""
db_user = envget(db.get("environment"), "MARIADB_USER") or ""

db_volume = ""
vols = cfg.get("volumes", {})
for key in ("db-data", "db_data"):
    v = vols.get(key) or {}
    if isinstance(v, dict) and v.get("name"):
        db_volume = v["name"]
        break
if not db_volume:
    proj = cfg.get("name") or "sispatrimoniopro"
    db_volume = f"{proj}_db-data"

print("APP_CNAME=" + shlex.quote(str(app_cname)))
print("DB_CNAME=" + shlex.quote(str(db_cname)))
print("DB_NAME=" + shlex.quote(str(db_name)))
print("DB_USER=" + shlex.quote(str(db_user)))
print("DB_VOLUME=" + shlex.quote(str(db_volume)))
')" || die "Não foi possível interpretar o docker compose config do repositório."

    [ -n "$DB_NAME" ] || { DB_NAME="sispatrimonio_pro"; warn "MARIADB_DATABASE não resolvido do compose — assumindo '$DB_NAME'."; }
    [ -n "$DB_USER" ] || { DB_USER="sispatrimonio"; warn "MARIADB_USER não resolvido do compose — assumindo '$DB_USER'."; }

    # Validação cruzada CLI × compose (o repo fixa banco/usuário — fonte da verdade)
    if [ "$DB_NAME_PROVIDED" = "true" ] && [ -n "${DB_NAME_CLI:-}" ] && [ "$DB_NAME_CLI" != "$DB_NAME" ]; then
        die "--db-name '$DB_NAME_CLI' diverge do banco fixado pelo compose do repositório ('$DB_NAME'). O compose é a fonte da verdade — remova a opção ou ajuste o compose no repo."
    fi
    if [ "$DB_USER_PROVIDED" = "true" ] && [ -n "${DB_USER_CLI:-}" ] && [ "$DB_USER_CLI" != "$DB_USER" ]; then
        die "--db-user '$DB_USER_CLI' diverge do usuário fixado pelo compose do repositório ('$DB_USER'). O compose é a fonte da verdade — remova a opção ou ajuste o compose no repo."
    fi

    # Volume do banco: existe? (define o caminho reuso vs primeira criação)
    if docker volume ls -q 2>/dev/null | grep -qx "$DB_VOLUME"; then
        EXISTING_VOLUME="true"
        ok "Volume do banco detectado: $DB_VOLUME (será REUTILIZADO)."
    else
        info "Volume do banco '$DB_VOLUME' não existe (primeira instalação do banco)."
    fi

    ok "Compose analisado: containers $APP_CNAME/$DB_CNAME · banco $DB_NAME (usuário $DB_USER) · volume $DB_VOLUME."
}

# ----------------------------------------------------------------------------
# .env (0600, nunca sobrescrito; mescla só chaves ausentes) + validação final
# ----------------------------------------------------------------------------
ensure_env_file() {
    STEP="Arquivo de configuração .env"
    local env_file="$INSTALL_DIR/.env"

    if [ -f "$env_file" ]; then
        local bak
        bak="$env_file.bak-$(date +%Y%m%d%H%M%S)"
        warn ".env existente — NUNCA é sobrescrito."
        cp -a "$env_file" "$bak"
        ok "Backup criado: $bak"
        # Mescla APENAS chaves ausentes (credenciais existentes preservadas)
        local added=0
        if ! grep -q '^SECRET_KEY=' "$env_file"; then echo "SECRET_KEY=$SECRET_KEY" >> "$env_file"; added=$((added+1)); fi
        if ! grep -q '^DB_ROOT_PASSWORD=' "$env_file"; then echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD" >> "$env_file"; added=$((added+1)); fi
        if ! grep -q '^APP_PORT=' "$env_file"; then echo "APP_PORT=$APP_PORT" >> "$env_file"; added=$((added+1)); fi
        if ! grep -q '^TZ=' "$env_file"; then echo "TZ=$TZ_VALUE" >> "$env_file"; added=$((added+1)); fi
        if [ "$added" -gt 0 ]; then
            ok "$added chave(s) ausentes adicionadas ao .env (valores existentes preservados)."
        else
            ok ".env mantido sem alterações (todas as chaves exigidas pelo compose presentes)."
        fi
    else
        umask 077  # arquivo nasce 0600 (SR-002)
        cat > "$env_file" <<ENVEOF
# Gerado por install-docker.sh v${APP_VERSION_INSTALLER} em $(date '+%Y-%m-%d %H:%M:%S %Z')
# ATENÇÃO: contém credenciais — permissões 0600. NUNCA versionar/compartilhar.

# Banco de dados (valores lidos pelo docker-compose.yml do repositório)
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD

# Chave de sessão da aplicação (gerada — ver cabeçalho do compose)
SECRET_KEY=$SECRET_KEY

# Porta exposta no HOST (a app escuta fixo em ${APP_INTERNAL_PORT} dentro do container)
APP_PORT=$APP_PORT

# Fuso horário dos containers
TZ=$TZ_VALUE
ENVEOF
        chmod 600 "$env_file"
        ok ".env gerado com permissões 0600 (SR-002)."
    fi
    chmod 600 "$env_file" 2>/dev/null || true

    # Validação FINAL do compose COM as credenciais reais (silenciosa — nada
    # interpolado vai ao log; falha indica variável exigida ausente no .env)
    DCC config --quiet 2>/dev/null || die "docker-compose.yml inválido ou variável exigida ausente no .env — verifique com: cd $INSTALL_DIR && docker compose config"
    ok "docker-compose.yml validado com o .env (docker compose config OK)."
}

# ----------------------------------------------------------------------------
# Build da imagem da app (Dockerfile do repo, via compose — camadas cacheadas)
# ----------------------------------------------------------------------------
compose_build() {
    STEP="Build da imagem da aplicação"
    info "Construindo a imagem do serviço 'app' (pode levar vários minutos na primeira vez)..."
    DCC build >&2
    ok "Imagem construída."

    # mysqldump DENTRO da imagem (backup/restauração pela própria app)
    MYSQLDUMP_DETECTED="$(DCC run --rm --no-deps --entrypoint /bin/sh app -c 'command -v mysqldump || true' 2>/dev/null | tail -1 || true)"
    if [ -n "$MYSQLDUMP_DETECTED" ]; then
        ok "mysqldump presente na imagem: $MYSQLDUMP_DETECTED (backups da app OK)."
    else
        warn "mysqldump AUSENTE na imagem — backup/restauração pela app não funcionará (o restante não é afetado)."
    fi
}

# ----------------------------------------------------------------------------
# Banco de dados (container MariaDB + volume nomeado do compose)
# ----------------------------------------------------------------------------
sql_escape() {  # padrão SQL do install.sh (' -> ''); backslash rejeitado
    case "$1" in
        *\\*) die "Senha contém backslash (\\) — não suportado pelo escape SQL do instalador." ;;
    esac
    printf '%s' "$1" | sed "s/'/''/g"
}

db_root_sql() {  # SQL administrativo (MYSQL_PWD via exec -e — NUNCA argv/log)
    [ -n "$DB_ROOT_PASSWORD" ] || return 1
    DCC exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" db mariadb -uroot -N -B -e "$1" 2>/dev/null
}

db_user_sql() {  # SQL como o usuário da aplicação
    DCC exec -T -e MYSQL_PWD="$DB_PASSWORD" db mariadb -u"$DB_USER" -N -B -e "$1" 2>/dev/null
}

wait_db_healthy() {
    info "Aguardando o container do banco ficar saudável (até ${DB_WAIT_TIMEOUT_SECONDS}s; primeira inicialização pode demorar)..."
    local waited=0 st
    while [ "$waited" -lt "$DB_WAIT_TIMEOUT_SECONDS" ]; do
        st="$(docker inspect -f '{{.State.Health.Status}}' "$DB_CNAME" 2>/dev/null || echo unknown)"
        case "$st" in
            healthy)
                ok "Container do banco saudável."
                return 0 ;;
            unhealthy)
                err "Container do banco em estado unhealthy — últimas linhas do log:"
                DCC logs --tail 40 db >&2 2>/dev/null || true
                die "Container do banco falhou (unhealthy). Corrija e reexecute — o instalador é idempotente." ;;
        esac
        sleep 3
        waited=$((waited + 3))
    done
    DCC logs --tail 40 db >&2 2>/dev/null || true
    die "Container do banco não ficou saudável em ${DB_WAIT_TIMEOUT_SECONDS}s."
}

verify_fresh_db() {  # primeira inicialização: entrypoint do MariaDB cria banco+usuário
    local tries=0 found=""
    while [ "$tries" -lt 20 ]; do
        if found="$(db_root_sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_escape "$DB_NAME")';")" \
           && [ "$found" = "$DB_NAME" ]; then
            ok "Banco '$DB_NAME' e usuário '$DB_USER' criados pelo entrypoint do MariaDB."
            return 0
        fi
        sleep 3
        tries=$((tries + 1))
    done
    DCC logs --tail 40 db >&2 2>/dev/null || true
    die "Banco '$DB_NAME' não apareceu após a inicialização do container (logs acima)."
}

verify_app_db_user() {  # reuso: alinha a senha do usuário ao .env (caso divergente)
    if db_user_sql "SELECT 1;" >/dev/null 2>&1; then
        ok "Credencial do usuário do banco confere com o .env."
        return 0
    fi
    warn "Senha do usuário '$DB_USER' diverge do estado atual do banco — tentando realinhar via root..."
    if db_root_sql "SELECT 1;" >/dev/null 2>&1; then
        local esc
        esc="$(sql_escape "$DB_PASSWORD")"
        db_root_sql "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$esc'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || die "ALTER USER falhou — verifique o banco manualmente (docker compose exec db mariadb -uroot -p)."
        ok "Senha do usuário '$DB_USER' realinhada à do .env."
    else
        die "Credencial da app inválida e root indisponível (DB_ROOT_PASSWORD ausente/incorreto no .env). Corrija o .env ou use --reset-db (DESTRUTIVO — dupla confirmação) e reexecute."
    fi
}

ensure_database() {
    STEP="Banco de dados (container MariaDB)"
    if [ "$EXISTING_VOLUME" = "true" ] && [ "$RESET_DB" != "true" ]; then
        ok "Volume '$DB_VOLUME' existente — REUTILIZADO (nada será apagado)."
    elif [ "$EXISTING_VOLUME" = "true" ]; then
        # Precisão destrutiva: remove SOMENTE o volume do banco (NÃO usa
        # `down -v`, que também apagaria app-data — backups/logs da app)
        warn "APAGANDO o volume do banco '$DB_VOLUME' (solicitação explícita --reset-db)..."
        DCC down --remove-orphans >/dev/null 2>&1 || true
        if ! docker volume rm "$DB_VOLUME" >/dev/null 2>&1; then
            die "Não foi possível remover o volume '$DB_VOLUME' (em uso?). Execute: docker volume rm $DB_VOLUME — e reexecute."
        fi
        ok "Volume do banco removido (app-data PRESERVADO) — banco será criado do zero."
    fi
    info "Subindo o container do banco..."
    DCC up -d db >&2
    wait_db_healthy
    if [ "$EXISTING_VOLUME" = "true" ] && [ "$RESET_DB" != "true" ]; then
        verify_app_db_user
    else
        verify_fresh_db
    fi
}

# ----------------------------------------------------------------------------
# init_db explícito (mesmo contrato do install.sh: VERIFICADO pelo instalador;
# roda em container EFÊMERO antes da app subir — sem corrida com o boot da app)
# ----------------------------------------------------------------------------
init_database() {
    STEP="Inicialização do schema do banco (init_db)"
    info "Executando init_db() do projeto em container efêmero (create_all idempotente)..."
    # --entrypoint python3: robusto tanto para imagens com CMD quanto com ENTRYPOINT
    if ! DCC run --rm --no-deps --entrypoint python3 app -c "from app.database import init_db; init_db()"; then
        die "init_db() falhou — verifique o .env e o estado do banco. Instalação interrompida (nenhum dado alterado)."
    fi
    ok "Schema verificado/criado via init_db() do projeto."
}

# ----------------------------------------------------------------------------
# Start da app + health check (mesmo contrato do install.sh)
# ----------------------------------------------------------------------------
start_and_health_check() {
    STEP="Inicialização e verificação de saúde"
    DCC up -d app >&2
    info "Aguardando /health em http://127.0.0.1:$APP_PORT (até ${HEALTH_TIMEOUT_SECONDS}s)..."
    local waited=0 result status
    while [ "$waited" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
        if result="$(curl -fsS "http://127.0.0.1:$APP_PORT/health" 2>/dev/null)"; then
            status="$(printf '%s' "$result" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
            case "$status" in
                healthy)
                    ok "Aplicação saudável: /health -> healthy"
                    return 0 ;;
                degraded)
                    warn "/health -> degraded (aplicação no ar; componente informado no corpo da resposta, ex.: AD configurado e indisponível). Instalação prossegue."
                    return 0 ;;
                *)
                    info "status=$status — aguardando..." ;;
            esac
        fi
        sleep 2
        waited=$((waited + 2))
    done
    err "Aplicação não respondeu em /health dentro de ${HEALTH_TIMEOUT_SECONDS}s."
    err "=== Últimas linhas do log do container da app ==="
    DCC logs --tail 60 app 2>/dev/null || true
    err "=== Inspeção do container ==="
    docker inspect -f 'State: {{.State.Status}} · OOMKilled: {{.State.OOMKilled}} · RestartCount: {{.RestartCount}} · Error: {{.State.Error}}' "$APP_CNAME" 2>/dev/null || true
    # Interrompe o loop de reinício (restart: unless-stopped reiniciaria para sempre)
    DCC stop app >/dev/null 2>&1 || true
    warn "Container da app PARADO para encerrar o loop de reinício. Reexecute o instalador quando quiser tentar novamente (idempotente)."
    die "Falha na verificação de saúde. Diagnóstico acima; log completo em $INSTALL_LOG."
}

# ----------------------------------------------------------------------------
# Bateria pós-instalação (equivalente docker da bateria do install.sh)
# ----------------------------------------------------------------------------
post_install_checks() {
    STEP="Bateria de verificação pós-instalação"
    local failures=0

    if docker info >/dev/null 2>&1; then
        ok "Docker daemon: OK"
    else
        err "Docker daemon: FALHOU"
        failures=$((failures + 1))
    fi

    if [ "$(docker inspect -f '{{.State.Running}}' "$APP_CNAME" 2>/dev/null || echo missing)" = "true" ]; then
        ok "Container da app em execução: OK"
    else
        err "Container da app: FALHOU"
        failures=$((failures + 1))
    fi

    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CNAME" 2>/dev/null || echo missing)" = "healthy" ]; then
        ok "Container do banco saudável: OK"
    else
        err "Container do banco: FALHOU"
        failures=$((failures + 1))
    fi

    if db_user_sql "SELECT 1 FROM \`$(sql_escape "$DB_NAME")\`.users LIMIT 1;" >/dev/null 2>&1; then
        ok "Tabela base (users) existente: OK"
    else
        err "Tabela base (users): FALHOU"
        failures=$((failures + 1))
    fi

    if curl -fsS "http://127.0.0.1:$APP_PORT/health" >/dev/null 2>&1; then
        ok "HTTP /health (host): OK"
    else
        err "HTTP /health (host): FALHOU"
        failures=$((failures + 1))
    fi

    local perms
    perms="$(stat -c '%a' "$INSTALL_DIR/.env" 2>/dev/null || echo '?')"
    if [ "$perms" = "600" ]; then
        ok ".env com permissão 600 (SR-002): OK"
    else
        err ".env com permissão $perms (esperado 600)"
        failures=$((failures + 1))
    fi

    if [ "$failures" -gt 0 ]; then
        die "$failures verificação(ões) pós-instalação falharam — veja mensagens acima e o log."
    fi
    ok "Bateria completa: todas as verificações passaram."
}

# ----------------------------------------------------------------------------
# Auto-check de segurança (SR-001): segredos NÃO podem estar no log
# ----------------------------------------------------------------------------
security_self_check() {
    STEP="Auditoria de segurança do instalador"
    local leaked=0
    local secret
    for secret in "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "$SECRET_KEY"; do
        if [ -n "$secret" ] && grep -Fq "$secret" "$INSTALL_LOG" 2>/dev/null; then
            warn "Uma credencial foi encontrada no log do instalador — REVISE $INSTALL_LOG (remova a linha) e investigue a origem."
            leaked=1
        fi
    done
    if [ "$leaked" = "0" ]; then
        ok "Auto-check: nenhuma credencial no log (SR-001)."
    fi

    local perms
    perms="$(stat -c '%a' "$INSTALL_DIR/.env" 2>/dev/null || echo '?')"
    if [ "$perms" = "600" ]; then
        ok ".env com permissão 600 (SR-002)."
    else
        warn ".env com permissão $perms (esperado 600)."
    fi

    # O default 'changeme-root' do compose NUNCA pode estar em vigor:
    # exige DB_ROOT_PASSWORD definido no .env (sempre gerado pelo instalador)
    if grep -q '^DB_ROOT_PASSWORD=.\+' "$INSTALL_DIR/.env" 2>/dev/null; then
        ok "DB_ROOT_PASSWORD definido no .env (default 'changeme-root' do compose não está em vigor)."
    else
        warn "DB_ROOT_PASSWORD ausente no .env — o MariaDB do container pode ter aceitado o default 'changeme-root'. Corrija o .env e realinhe a senha (ou --reset-db)."
    fi

    # Informativo: usuário do processo da app dentro do container (imagem do repo)
    local cuser
    cuser="$(docker inspect -f '{{.Config.User}}' "$APP_CNAME" 2>/dev/null || echo '?')"
    if [ "$cuser" = "" ] || [ "$cuser" = "?" ]; then
        cuser="root (default da imagem)"
    fi
    info "Processo da app roda como: $cuser no container (definido pela imagem do repositório)."
}

# ----------------------------------------------------------------------------
# Resumo final
# ----------------------------------------------------------------------------
print_summary() {
    local ip_addr
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo >&2
    echo "${C_BOLD}  ══════════════════════════════════════════════════════════════${C_RESET}" >&2
    ok "SisPatrimônio Pro instalado com sucesso (DOCKER)!"
    echo "${C_BOLD}  ══════════════════════════════════════════════════════════════${C_RESET}" >&2
    echo >&2
    echo "${C_BOLD}  ACESSO${C_RESET}" >&2
    _kv "Aplicação   " "http://${ip_addr:-$(hostname -f 2>/dev/null || echo localhost)}:$APP_PORT"
    _kv "Swagger API " "http://${ip_addr:-$(hostname -f 2>/dev/null || echo localhost)}:$APP_PORT/docs"
    _kv "Health check" "http://${ip_addr:-$(hostname -f 2>/dev/null || echo localhost)}:$APP_PORT/health"
    echo >&2
    echo "${C_BOLD}  INSTALAÇÃO${C_RESET}" >&2
    _kv "Diretório   " "$INSTALL_DIR"
    _kv "Compose     " "$INSTALL_DIR/docker-compose.yml (versionado no repo — não alterado)"
    _kv "Containers  " "$APP_CNAME · $DB_CNAME"
    _kv "Volumes     " "$DB_VOLUME (banco) · dados da app: backups/logs"
    _kv "Configuração" "$INSTALL_DIR/.env (0600 — contém credenciais)"
    _kv "Log         " "$INSTALL_LOG"
    echo >&2
    echo "${C_BOLD}  GERENCIAR OS CONTAINERS (cd $INSTALL_DIR)${C_RESET}" >&2
    echo "    docker compose ps          # estado" >&2
    echo "    docker compose logs -f app # logs da aplicação" >&2
    echo "    docker compose restart app # reiniciar aplicação" >&2
    echo "    docker compose stop        # parar tudo (persistência mantida)" >&2
    echo "    docker compose up -d       # subir novamente" >&2
    echo >&2
    echo "${C_BOLD}  BACKUP DO BANCO (exemplo — senha em $INSTALL_DIR/.env)${C_RESET}" >&2
    echo "    cd $INSTALL_DIR && docker compose exec -T -e MYSQL_PWD=\"\$(grep '^DB_ROOT_PASSWORD=' .env | cut -d= -f2-)\" \\" >&2
    echo "      db mariadb-dump -uroot $DB_NAME > backup-\$(date +%F).sql" >&2
    echo >&2
    echo "${C_BOLD}  PRIMEIRO ADMINISTRADOR (escolha um caminho — nunca exibimos senhas)${C_RESET}" >&2
    echo "    A) CLI (recomendado):" >&2
    echo "       cd $INSTALL_DIR && docker compose exec app python3 -m app.cli \\" >&2
    echo "         create-user --username admin --name 'Administrador' --admin" >&2
    echo "       (a senha é solicitada de forma oculta; mínimo 8 caracteres)" >&2
    echo "    B) Primeiro acesso: abra a aplicação e use a página /setup" >&2
    echo "       (disponível enquanto não existir nenhum usuário)" >&2
    echo "    C) Variáveis de ambiente: AUTH_ADMIN_USERNAME/AUTH_ADMIN_PASSWORD" >&2
    echo "       no .env antes do primeiro start (remova após o primeiro login)" >&2
    echo >&2
    echo "  As senhas do banco NÃO aparecem neste resumo nem no log — estão" >&2
    echo "  apenas no .env (DB_PASSWORD, DB_ROOT_PASSWORD e SECRET_KEY), 0600." >&2
    echo "${C_BOLD}  ══════════════════════════════════════════════════════════════${C_RESET}" >&2
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    setup_logging
    echo >&2
    echo "==============================================================" >&2
    info "SisPatrimônio Pro — Instalador Linux via DOCKER v${APP_VERSION_INSTALLER} ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "==============================================================" >&2
    echo >&2

    STEP="Parâmetros e validação"
    validate_inputs
    require_root
    check_distro
    check_connectivity
    detect_host

    # Pré-requisitos ADITIVOS e idempotentes antes da confirmação: são eles
    # que habilitam a análise do compose do repo (Docker + clone), da qual
    # saem os valores reais exibidos no plano (banco, volume, containers).
    # Nada destrutivo acontece aqui; a confirmação abaixo cobre as mutações
    # de aplicação (.env, build, banco, schema, start) — adaptação do R12
    # para a variante com compose versionado no repositório.
    run_step "Docker Engine, Compose v2 e pacotes base"       ensure_packages
    run_step "Código-fonte (clone)"                            ensure_repo
    run_step "docker-compose.yml do repo (análise)"            parse_compose_config

    STEP="Coleta de credenciais"
    collect_secrets

    # Interação ANTES das mutações de aplicação (R12/R13 adaptado — acima)
    STEP="Confirmação do plano"
    confirm_plan
    STEP="Confirmação de recriação do banco"
    confirm_reset_db

    run_step "Arquivo de configuração .env"                    ensure_env_file
    run_step "Build da imagem da aplicação"                    compose_build
    run_step "Banco de dados (container MariaDB)"              ensure_database
    run_step "Inicialização do schema (init_db)"               init_database
    run_step "Start + health check"                            start_and_health_check
    run_step "Bateria pós-instalação"                          post_install_checks
    run_step "Auditoria de segurança"                          security_self_check

    print_summary
    ok "Concluído."
}

main "$@"
