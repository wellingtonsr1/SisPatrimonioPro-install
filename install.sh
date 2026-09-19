#!/usr/bin/env bash
# ============================================================================
# SisPatrimônio Pro — Instalador Automatizado de Produção Linux (Feature 027)
#
# Prepara um servidor Debian/Ubuntu (ou derivada com apt + systemd) para
# executar o SisPatrimônio Pro em produção:
#   pré-requisitos → Python ≥ 3.10 → Git → MariaDB/MySQL → banco+usuário
#   → clone → venv → requirements.txt → .env → systemd → /health → resumo
#
# Idempotente: pode ser executado novamente — cada etapa detecta o estado
# anterior e REUTILIZA o que já existe. Banco de dados existente NUNCA é
# apagado (recriação só via --recreate-db, com dupla confirmação interativa).
#
# Segurança (spec SR-001..SR-005): senha do banco coletada SEM ECO ou gerada
# via secrets; NUNCA em argv (usa MYSQL_PWD no ambiente, como a própria
# aplicação), NUNCA em log; .env criado com 0600; serviço roda com usuário
# dedicado sem login; privilégios do banco somente no banco da aplicação.
#
# Uso:
#   sudo bash install.sh
#   sudo bash install.sh --non-interactive --db-name X --db-user Y \
#        --generate-db-password
#   sudo bash install.sh --update   # reservado (ainda não implementado)
#
# Contrato completo: specs/027-instalador-producao-linux/contracts/installer-contract.md
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Constantes e defaults (data-model §1.1)
# ----------------------------------------------------------------------------
readonly DEFAULT_REPO_URL="https://github.com/wellingtonsr1/sistema_patrimonio_mysql.git"
readonly DEFAULT_BRANCH="main"
readonly DEFAULT_INSTALL_DIR="/opt/SisPatrimonioPro"
readonly DEFAULT_DB_NAME="sispatrimoniopro"
readonly DEFAULT_DB_USER="patrimonio"
readonly DEFAULT_DB_HOST="localhost"
readonly DEFAULT_DB_PORT="3306"
readonly DEFAULT_APP_HOST="0.0.0.0"   # default de código (192.168.0.9) é específico do operador
readonly DEFAULT_APP_PORT="8000"
readonly DEFAULT_SERVICE_NAME="sispatrimoniopro"
readonly DEFAULT_SERVICE_USER="sispatrimonio"
readonly DEFAULT_SERVICE_GROUP="sispatrimonio"
readonly INSTALL_LOG="/var/log/sispatrimonio-install.log"
readonly HEALTH_TIMEOUT_SECONDS=120
readonly APP_LOG_DIR="data/logs"
readonly BACKUP_DIR="data/backups"
readonly MIN_PYTHON_MAJOR=3
readonly MIN_PYTHON_MINOR=10

APP_VERSION_INSTALLER="1.0.0"
NON_INTERACTIVE="false"
RECREATE_DB="false"
INSTALL_DIR=""
REPO_URL="$DEFAULT_REPO_URL"
BRANCH="$DEFAULT_BRANCH"
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_HOST="$DEFAULT_DB_HOST"
DB_PORT="$DEFAULT_DB_PORT"
APP_HOST="$DEFAULT_APP_HOST"
APP_PORT="$DEFAULT_APP_PORT"
SERVICE_NAME="$DEFAULT_SERVICE_NAME"
SERVICE_USER="$DEFAULT_SERVICE_USER"
SERVICE_GROUP="$DEFAULT_SERVICE_GROUP"
GENERATE_DB_PASSWORD="false"
DB_PASSWORD_CHANGED="false"   # true quando o usuário do banco foi criado/recriado nesta execução

STEP=""
STEP_NO=0
TOTAL_STEPS=15
BANCO_SERVICE_DETECTED=""
BANCO_CLIENT_CMD=""

# ----------------------------------------------------------------------------
# Log (FR-016, R1/R2): níveis INFO/OK/WARNING/ERROR + arquivo 0600
# Cores SOMENTE quando stdout é um terminal (tput; respeita NO_COLOR/TERM=dumb);
# o arquivo de log recebe SEMPRE texto limpo (ANSI removido no tee — setup_logging).
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

# Saída humana: [ TAG ] em coluna fixa (alinhada) + mensagem
_msg() {  # $1=cor da tag  $2=tag  $3...=mensagem — SEMPRE stderr (canal único)
    # stderr é sem buffer; stdout sob tee é bufferizado. Misturar canais em console
    # lento (serial/VNC) reordena linhas — pós setup_logging stderr==stdout (mesmo
    # pipe), então um canal único garante a ordem. err() duplicaria o redirecionamento
    # (>&2 >&2 é inofensivo).
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

prompt_printf() {  # prompt no canal stderr — MESMA fila do restante da saída (ordem garantida)
    # NÃO escrever em /dev/tty: um segundo canal (tty direto vs pipe do tee)
    # reordena a saída em consoles lentos (serial/VNC) — o prompt saltava para
    # FRENTE do resumo (bug observado em VM). Pós setup_logging, stderr == stdout
    # (mesmo pipe → tee → tela+log): um único canal preserva a ordem em qualquer
    # terminal. Com stdout redirecionado, o prompt segue visível no stderr.
    # O prompt vai ao log (R2) e não contém segredos (SR-001).
    printf '%s' "$*" >&2
}

on_error() {  # caixa visual de falha — conteúdo/garantias preservados
    local exit_code=$?
    {
        echo "${C_RESET}${C_RED}"
        echo "  ┌── INSTALAÇÃO INTERROMPIDA ──────────────────────────"
        echo "  │ Etapa: ${STEP:-desconhecida} (exit $exit_code, linha ${1:-?})"
        echo "  │ Log completo: $INSTALL_LOG (sem credenciais)"
        echo "  │ Corrija o problema e reexecute o instalador — ele é"
        echo "  │ idempotente e reutiliza o que já foi concluído"
        echo "  │ (nenhum dado é apagado)."
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

_kv() {  # par "label : valor" — label JÁ vem pré-padded do chamador em largura
         # visual 13 (printf conta bytes, não colunas: acentos quebrariam o %-Ns)
    printf '  %s: %s\n' "$1" "$2" >&2
}

# ----------------------------------------------------------------------------
# Coleta de senha SEM ECO (SR-001, R2): prompt vai ao log ANTES do read;
# leitura dentro de janela set +x (defesa contra xtrace acidental)
# ----------------------------------------------------------------------------
prompt_secret() {  # $1=prompt  →  senha na stdout da função (capturado pelo chamador)
    # Vazio NAS DUAS entradas = "gerar automaticamente" (retorna vazio; o chamador gera).
    # Prompts via stderr (mesmo canal único da saída — ver prompt_printf).
    # NUNCA reativar set -x aqui: xtrace herdado por subshells imprimiria a senha no stderr
    # → log (violação SR-001 detectada na revisão).
    local prompt="$1" value confirm
    prompt_printf "$prompt"
    read -rs value
    prompt_printf $'\n'
    prompt_printf "Confirme a senha (vazio nas duas = gerar automaticamente): "
    read -rs confirm
    prompt_printf $'\n'
    if [ -z "$value" ] && [ -z "$confirm" ]; then
        return 0  # chamador decide gerar
    fi
    if [ -z "$value" ] || [ "$value" != "$confirm" ]; then
        die "As senhas não conferem (ou primeira vazia e confirmação preenchida). Operação abortada."
    fi
    printf '%s' "$value"
}

generate_secret() {  # segredo criptograficamente seguro (SR-002, R5)
    python3 -c 'import secrets; print(secrets.token_urlsafe(24))'
}

# ----------------------------------------------------------------------------
# T003 — Parser e validação de CLI (contract §1, FR-015, D2)
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
SisPatrimônio Pro — instalador de produção Linux v${APP_VERSION_INSTALLER}

Uso: sudo bash install.sh [opções]

  --non-interactive           Nenhum prompt; exige os parâmetros obrigatórios
  --install-dir <caminho>     Diretório de instalação (default: ${DEFAULT_INSTALL_DIR})
  --repo <url>                Repositório Git (default: repo oficial)
  --branch <nome>             Branch (default: ${DEFAULT_BRANCH})
  --db-name <nome>            Nome do banco (default: ${DEFAULT_DB_NAME})
  --db-user <usuário>         Usuário do banco (default: ${DEFAULT_DB_USER})
  --db-password <senha>       Senha do banco (não interativo; NÃO use em produção compartilhada)
  --generate-db-password      Gera senha forte automaticamente (vai direto ao .env)
  --db-host <host>            Host do banco (default: ${DEFAULT_DB_HOST})
  --db-port <porta>           Porta do banco (default: ${DEFAULT_DB_PORT})
  --app-host <host>           Bind da aplicação (default: ${DEFAULT_APP_HOST})
  --app-port <porta>          Porta da aplicação (default: ${DEFAULT_APP_PORT})
  --service-name <nome>       Nome do serviço systemd (default: ${DEFAULT_SERVICE_NAME})
  --service-user <usuário>    Usuário Linux do serviço (default: ${DEFAULT_SERVICE_USER})
  --recreate-db               APAGA e recria o banco da aplicação (SÓ interativo;
                              dupla confirmação; proibido com --non-interactive)
  --update                    Reservado: ainda não implementado (NFR-005)
  --help                      Esta ajuda

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
            --db-name)         DB_NAME="${2:-}"; shift ;;
            --db-user)         DB_USER="${2:-}"; shift ;;
            --db-password)     DB_PASSWORD="${2:-}"; shift ;;
            --generate-db-password) GENERATE_DB_PASSWORD="true" ;;
            --db-host)         DB_HOST="${2:-}"; shift ;;
            --db-port)         DB_PORT="${2:-}"; shift ;;
            --app-host)        APP_HOST="${2:-}"; shift ;;
            --app-port)        APP_PORT="${2:-}"; shift ;;
            --service-name)    SERVICE_NAME="${2:-}"; shift ;;
            --service-user)    SERVICE_USER="${2:-}"; shift ;;
            --recreate-db)     RECREATE_DB="true" ;;
            --update)          die "A opção --update ainda não está implementada (NFR-005). Use o fluxo manual documentado no README." ;;
            --help|-h)         usage; exit 0 ;;
            *)                 usage; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
}

validate_identifier() {  # identificadores SQL/Linux sem risco de injeção (R5)
    local label="$1" value="$2" pattern="$3"
    if ! printf '%s' "$value" | grep -qE "$pattern"; then
        die "$label inválido: '$value' (esperado: $pattern)"
    fi
}

validate_inputs() {  # validação TOTAL antes da primeira mutação (FR-015/R12)
    [ -n "$DB_NAME" ]      || DB_NAME="$DEFAULT_DB_NAME"
    [ -n "$DB_USER" ]      || DB_USER="$DEFAULT_DB_USER"
    [ -n "$INSTALL_DIR" ]  || INSTALL_DIR="$DEFAULT_INSTALL_DIR"

    validate_identifier "Nome do banco"    "$DB_NAME"      '^[A-Za-z_][A-Za-z0-9_]*$'
    validate_identifier "Usuário do banco" "$DB_USER"      '^[A-Za-z_][A-Za-z0-9_]*$'
    validate_identifier "Nome do serviço"  "$SERVICE_NAME" '^[a-z][a-z0-9-]*$'
    validate_identifier "Usuário do serviço" "$SERVICE_USER" '^[a-z_][a-z0-9_-]*$'

    if ! printf '%s' "$APP_PORT" | grep -qE '^[0-9]+$' || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
        die "Porta da aplicação inválida: $APP_PORT (1–65535)"
    fi

    # D2/FR-015: recriação de banco é PROIBIDA em modo não interativo
    if [ "$RECREATE_DB" = "true" ] && [ "$NON_INTERACTIVE" = "true" ]; then
        die "Combinação inválida: --recreate-db é proibida com --non-interactive (decisão D2)."
    fi

    # FR-015: no modo não interativo, senha deve ser fornecida ou marcada como gerada
    if [ "$NON_INTERACTIVE" = "true" ]; then
        if [ "$GENERATE_DB_PASSWORD" != "true" ] && [ -z "$DB_PASSWORD" ]; then
            die "Modo não interativo exige --db-password ou --generate-db-password."
        fi
    fi

    if [ -n "$DB_PASSWORD" ] && [ "$GENERATE_DB_PASSWORD" = "true" ]; then
        die "Use apenas uma: --db-password OU --generate-db-password."
    fi

    if [ -n "$DB_PASSWORD" ] && [ "${#DB_PASSWORD}" -lt 12 ]; then
        die "Senha manual do banco deve ter no mínimo 12 caracteres (gerada atende automaticamente)."
    fi
}

collect_secrets() {  # modo interativo: coleta senha (sem eco) ou marca para gerar
    if [ "$NON_INTERACTIVE" = "true" ]; then
        if [ "$GENERATE_DB_PASSWORD" = "true" ]; then
            DB_PASSWORD="$(generate_secret)"
            ok "Senha do banco gerada automaticamente (gravada apenas no .env)."
        fi
        return
    fi
    if [ -z "$DB_PASSWORD" ]; then
        if [ "$RECREATE_DB" != "true" ] && db_exists; then
            warn "Banco '$DB_NAME' já existe e será REUTILIZADO (nada será apagado)."
            warn "Pressione ENTER para gerar/confirmar senha conforme o fluxo (ou Ctrl+C para abortar)."
        fi
        DB_PASSWORD="$(prompt_secret 'Senha do banco (mín. 12 caracteres; ENTER vazio nas duas = gerar automaticamente): ')"
        if [ -z "$DB_PASSWORD" ]; then
            DB_PASSWORD="$(generate_secret)"
            ok "Senha do banco gerada automaticamente (gravada apenas no .env)."
        elif [ "${#DB_PASSWORD}" -lt 12 ]; then
            die "Senha manual do banco deve ter no mínimo 12 caracteres (ou deixe vazia para gerar)."
        fi
    fi
}

confirm_plan() {  # R12: confirmação final antes da primeira mutação (interativo)
    # return 0 EXPLÍCITO: `&& return` devolveria o status do teste que falhou
    # (NON_INTERACTIVE=false → 1) e `set -e` abortaria (mesmo bug do confirm_recreate_db)
    [ "$NON_INTERACTIVE" = "true" ] && return 0
    true
    echo >&2
    echo "${C_BOLD}  RESUMO DA INSTALAÇÃO${C_RESET}" >&2
    _kv "Diretório   " "$INSTALL_DIR"
    _kv "Repositório " "$REPO_URL (branch $BRANCH)"
    _kv "Banco       " "$DB_NAME (usuário $DB_USER em $DB_HOST:$DB_PORT)"
    _kv "Aplicação   " "$APP_HOST:$APP_PORT"
    _kv "Serviço     " "$SERVICE_NAME (usuário Linux $SERVICE_USER)"
    [ "$RECREATE_DB" = "true" ] && warn "*** --recreate-db ATIVO: o banco '$DB_NAME' será APAGADO e recriado ***"
    echo >&2
    prompt_printf '  Confirmar e iniciar a instalação? (s/N): '
    read -r answer
    case "$answer" in
        s|S|sim|SIM|y|Y) ok "Confirmado." ;;
        *) die "Instalação cancelada pelo operador. Nada foi alterado." ;;
    esac
}

# ----------------------------------------------------------------------------
# T004 — Gates de pré-requisitos (FR-002, SR-005)
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
            die "Distribuição não suportada nesta feature (base Debian/Ubuntu esperada): ${PRETTY_NAME:-$ID}. Veja NFR-001." ;;
    esac
    [ -d /run/systemd/system ] || die "systemd não está em execução — pré-requisito para o serviço (NFR-001)."
    ok "systemd presente."
}

check_connectivity() {
    STEP="Verificação de conectividade"
    command -v git >/dev/null 2>&1 || apt-get install -y git >/dev/null 2>&1 || true
    if git ls-remote --heads "$REPO_URL" "$BRANCH" >/dev/null 2>&1; then
        ok "Repositório acessível e branch '$BRANCH' existe."
    else
        die "Não foi possível acessar $REPO_URL (branch '$BRANCH'). Verifique rede/URL (FR-008)."
    fi
    if command -v apt-get >/dev/null 2>&1; then
        ok "apt disponível."
    else
        die "apt-get não encontrado — gerenciador de pacotes esperado na base Debian."
    fi
}

# ----------------------------------------------------------------------------
# T005 — Detecção de host (data-model §1.2, R3/R4)
# ----------------------------------------------------------------------------
python_version() {
    python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo "0.0"
}

python_at_least() {  # $1=major $2=minor
    local v; v="$(python_version)"
    local major="${v%%.*}" minor="${v##*.}"
    [ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]; }
}

detect_host() {
    STEP="Detecção do ambiente"
    if command -v python3 >/dev/null 2>&1; then
        HAS_PYTHON="true"
        PY_VER="$(python_version)"
        ok "Python $PY_VER detectado."
    else
        HAS_PYTHON="false"
        warn "Python 3 não encontrado."
    fi
    HAS_GIT="false"
    command -v git >/dev/null 2>&1 && { HAS_GIT="true"; ok "Git detectado."; } || warn "Git não encontrado."

    # D3/R4: detecta MariaDB OU MySQL por serviço e utilitários reais
    BANCO_SERVICE_DETECTED=""
    for svc in mariadb mysql; do
        if systemctl is-active --quiet "$svc.service" 2>/dev/null; then
            BANCO_SERVICE_DETECTED="$svc.service"
            break
        fi
    done
    if [ -z "$BANCO_SERVICE_DETECTED" ] && command -v mariadbd >/dev/null 2>&1; then
        BANCO_SERVICE_DETECTED="mariadb.service"
    fi
    if [ -z "$BANCO_SERVICE_DETECTED" ] && command -v mysqld >/dev/null 2>&1; then
        BANCO_SERVICE_DETECTED="mysql.service"
    fi
    detect_db_client
    if [ -n "$BANCO_SERVICE_DETECTED" ]; then
        ok "Servidor de banco detectado: $BANCO_SERVICE_DETECTED (será REUTILIZADO)."
    else
        warn "Nenhum servidor MariaDB/MySQL detectado (será instalado MariaDB — decisão D3)."
    fi
    if [ -n "$BANCO_CLIENT_CMD" ] && command -v mysqldump >/dev/null 2>&1; then
        ok "Utilitários de banco (cliente + mysqldump) presentes."
    else
        warn "Utilitários de banco incompletos (cliente/mysqldump) — serão providos com o servidor."
    fi

    # Porta da aplicação em uso? (risco da spec — detecção antes do start; reportada no resumo)
    PORT_IN_USE="false"
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${APP_PORT}\$"; then
        PORT_IN_USE="true"
        warn "Porta $APP_PORT já está em uso (verifique antes de iniciar o serviço)."
    fi
    export PORT_IN_USE
}

# ----------------------------------------------------------------------------
# T006 — Pacotes (FR-003/FR-004/FR-005, R3)
# ----------------------------------------------------------------------------
apt_install_pkgs() {  # apt não interativo (output integral segue para o log)
    # >&2: stderr não tem buffering — mantém o progresso do apt em ordem real
    # (stdout sob pipe seria bufferizado em blocos e embaralharia avisos)
    $SUDO apt-get update -y >&2
    $SUDO apt-get install -y ca-certificates curl "$@" >&2
}

apt_repair_pkg() {  # restaura a instalação do pacote SEM remover dados:
    # --reinstall regrava binários e o ARQUIVO DE UNIDADE systemd
    # (/var/lib/mysql do MariaDB é preservado — nenhum dado é apagado).
    info "Restaurando instalação do pacote $1 (unidade systemd ausente)..."
    $SUDO apt-get update -y >&2
    $SUDO apt-get install -y --reinstall -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$1" >&2
}

ensure_packages() {
    STEP="Instalação/verificação de pacotes do sistema"
    export DEBIAN_FRONTEND=noninteractive

    local need_pkgs=()
    [ "$HAS_PYTHON" != "true" ] && need_pkgs+=("python3")
    # Sonda REAL de criação de venv (não `import venv`, que passa no Ubuntu 24.04
    # mesmo sem python3.12-venv — o que falta lá é o ensurepip, usado pelo venv):
    if ! python3 -m ensurepip --version >/dev/null 2>&1; then
        need_pkgs+=("python3-venv")
    fi
    [ "$HAS_GIT" != "true" ] && need_pkgs+=("git")
    if ! python3 -m pip --version >/dev/null 2>&1; then
        need_pkgs+=("python3-pip")
    fi
    [ -z "$BANCO_SERVICE_DETECTED" ] && need_pkgs+=("mariadb-server")  # D3: instala MariaDB se NENHUM sgbd

    if [ "${#need_pkgs[@]}" -gt 0 ]; then
        info "Instalando: ${need_pkgs[*]}"
        apt_install_pkgs "${need_pkgs[@]}"
    else
        ok "Todos os pacotes necessários já estão presentes."
    fi

    # FR-003/R3: re-verificação OBRIGATÓRIA após instalar (apt pode ser no-op)
    if ! python_at_least "$MIN_PYTHON_MAJOR" "$MIN_PYTHON_MINOR"; then
        die "Python $(python_version) encontrado; o projeto exige >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}. Esta distribuição não provê versão suficiente — não são usados repositórios de terceiros (FR-003). Utilize uma distribuição suportada (NFR-001)."
    fi
    ok "Python $(python_version) atende ao requisito (>= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR})."

    # Garantir serviço do banco ativo (sem tocar configuração de servidor existente)
    if [ -z "$BANCO_SERVICE_DETECTED" ]; then
        BANCO_SERVICE_DETECTED="mariadb.service"
    fi
    # Re-detecção OBRIGATÓRIA aqui: em instalação fresca o servidor de banco
    # acabou de ser instalado e o cliente não existia na detecção inicial
    detect_db_client
    [ -n "$BANCO_CLIENT_CMD" ] || die "Cliente SQL (mariadb/mysql) não encontrado mesmo após a instalação dos pacotes."
    ok "Cliente de banco: $BANCO_CLIENT_CMD"

    if ! systemctl is-active --quiet "$BANCO_SERVICE_DETECTED"; then
        # Caso real (Ubuntu Server 24.04): binário mariadbd presente, porém a
        # UNIDADE systemd do banco não existe — o `enable --now` não sobe nada
        # ("is not a native service, redirecting to systemd-sysv-install").
        # Unidade ausente => pacote quebrado/retocado: reinstalá-lo regrava a
        # unidade SEM remover dados (/var/lib/mysql é preservado).
        if ! systemctl cat "$BANCO_SERVICE_DETECTED" >/dev/null 2>&1; then
            warn "Unidade $BANCO_SERVICE_DETECTED não existe (pacote do banco quebrado ou instalado manualmente)."
            apt_repair_pkg "${BANCO_SERVICE_DETECTED%.service}"
        fi
        $SUDO systemctl enable --now "$BANCO_SERVICE_DETECTED" >/dev/null 2>&1 || true
        $SUDO systemctl start "$BANCO_SERVICE_DETECTED" 2>/dev/null || true
    fi
    if ! systemctl is-active --quiet "$BANCO_SERVICE_DETECTED"; then
        err "Serviço de banco $BANCO_SERVICE_DETECTED não ficou ativo."
        systemctl status "$BANCO_SERVICE_DETECTED" --no-pager -n 20 2>/dev/null | sed -n '1,15p' >&2 || true
        journalctl -u "$BANCO_SERVICE_DETECTED" -n 20 --no-pager 2>/dev/null | tail -10 >&2 || true
        die "Verifique o MariaDB/MySQL manualmente (journalctl -u ${BANCO_SERVICE_DETECTED}) e reexecute o instalador — ele é idempotente."
    fi
    ok "Serviço de banco ativo: $BANCO_SERVICE_DETECTED"
}

# ----------------------------------------------------------------------------
# Banco (FR-006/FR-007, R5/R13): MYSQL_PWD no ambiente — NUNCA argv
# ----------------------------------------------------------------------------
detect_db_client() {  # cliente SQL real (D3); vazio = ausente. Reexecutada
                      # após instalar o servidor (instalação fresca: a detecção
                      # inicial roda SEM SGBD e o cliente só existe depois)
    BANCO_CLIENT_CMD=""
    if command -v mariadb >/dev/null 2>&1; then
        BANCO_CLIENT_CMD="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        BANCO_CLIENT_CMD="mysql"
    fi
}

db_client() {  # executa SQL com credencial no ambiente (senha nunca em argv/log)
    local sql="$1"
    if [ -S /run/mysqld/mysqld.sock ] && [ "$DB_HOST" = "$DEFAULT_DB_HOST" ]; then
        # instalação local: autenticação administrativa via socket unix_auth quando disponível
        "$BANCO_CLIENT_CMD" -N -B -e "$sql" 2>/dev/null && return 0
    fi
    env MYSQL_PWD="$DB_PASSWORD" "$BANCO_CLIENT_CMD" -h "$DB_HOST" -P "$DB_PORT" -N -B -e "$sql"
}

db_exists() {  # banco da aplicação já existe? (usado antes de coletar senha)
    local client="$BANCO_CLIENT_CMD"
    [ -n "$client" ] || client="mysql"
    if [ -S /run/mysqld/mysqld.sock ]; then
        $client -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" 2>/dev/null | grep -q "$DB_NAME"
    else
        return 1
    fi
}

db_admin_ok() {  # credencial admin (root via socket) funciona?
    local client="$BANCO_CLIENT_CMD"
    [ -n "$client" ] || client="mysql"
    $client -N -B -e "SELECT 1;" >/dev/null 2>&1
}

ensure_database() {
    STEP="Criação/validação do banco de dados"

    # Via administrativa: socket local (unix_auth) é o caminho padrão em instalação nova
    if ! db_admin_ok; then
        die "Não foi possível administrar o banco localmente (socket). Configure acesso administrativo ou execute como root no próprio servidor."
    fi

    local exists
    exists="$("$BANCO_CLIENT_CMD" -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_escape "$DB_NAME")';")"
    if [ "$exists" = "$DB_NAME" ] && [ "$RECREATE_DB" != "true" ]; then
        ok "Banco '$DB_NAME' já existe — REUTILIZADO (nada será apagado)."
    elif [ "$exists" = "$DB_NAME" ] && [ "$RECREATE_DB" = "true" ]; then
        # R13/D2: dupla confirmação já realizada em confirm_recreate_db
        warn "APAGANDO banco '$DB_NAME' (solicitação explícita --recreate-db)..."
        "$BANCO_CLIENT_CMD" -e "DROP DATABASE \`$DB_NAME\`;"
        "$BANCO_CLIENT_CMD" -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        ok "Banco '$DB_NAME' recriado (utf8mb4/utf8mb4_unicode_ci)."
    else
        "$BANCO_CLIENT_CMD" -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        ok "Banco '$DB_NAME' criado (utf8mb4/utf8mb4_unicode_ci)."
    fi

    # Usuário: reutiliza se existir, com ALINHAMENTO de senha (caso real:
    # usuário de rodada anterior com senha antiga + .env desta execução =>
    # init_db() falhava com Access denied e3q8)
    local user_exists
    user_exists="$("$BANCO_CLIENT_CMD" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='$DB_USER' AND Host='localhost';")"
    if [ "$user_exists" = "0" ]; then
        local esc
        esc="$(sql_escape "$DB_PASSWORD")"
        "$BANCO_CLIENT_CMD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$esc';"
        DB_PASSWORD_CHANGED="true"
        ok "Usuário '$DB_USER'@'localhost' criado."
    else
        ok "Usuário '$DB_USER'@'localhost' já existe — reutilizado."
        # Testa a senha REAL do usuário (login como o próprio usuário)
        if env MYSQL_PWD="$DB_PASSWORD" "$BANCO_CLIENT_CMD" --user="$DB_USER" -N -B -e "SELECT 1;" >/dev/null 2>&1; then
            ok "Senha do usuário confere com a desta execução."
        elif [ "$NON_INTERACTIVE" = "true" ] || [ "$RECREATE_DB" = "true" ]; then
            set_placeholder_password
            DB_PASSWORD_CHANGED="true"
            ok "Senha do usuário '$DB_USER' alinhada à desta execução."
        else
            prompt_printf "Senha do usuário do banco DIVERGE da digitada. Atualizá-la para a desta execução? (S/n): "
            read -r ans
            case "$ans" in
                n|N|nao|não|no)
                    warn "Senha do usuário preservada — o .env usará a senha digitada; init_db() pode falhar com Access denied."
                    ;;
                *)
                    set_placeholder_password
                    DB_PASSWORD_CHANGED="true"
                    ok "Senha do usuário '$DB_USER' atualizada para a desta execução."
                    ;;
            esac
        fi
    fi

    # Grants: SOMENTE no banco da aplicação (SR-003) — idempotente
    "$BANCO_CLIENT_CMD" -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
    "$BANCO_CLIENT_CMD" -e "FLUSH PRIVILEGES;"
    ok "Privilégios garantidos apenas em '$DB_NAME'.* (sem privilégios globais — SR-003)."
}

confirm_recreate_db() {  # R13/D2: aviso + dupla confirmação digitando o nome do banco
    # return 0 EXPLÍCITO: `|| return` sem status devolveria o status do teste
    # que acabou de falhar (1) e `set -e` abortaria após o confirm (bug real)
    [ "$RECREATE_DB" = "true" ] || return 0
    [ "$NON_INTERACTIVE" = "true" ] && die "Inconsistência: --recreate-db em modo não interativo (deveria ter sido bloqueado)."
    warn "=============================================================="
    warn "MODO DESTRUTIVO: --recreate-db APAGARÁ o banco '$DB_NAME'"
    warn "e TODOS os seus dados. Esta ação é IRREVERSÍVEL."
    warn "=============================================================="
    prompt_printf 'Digite o nome do banco para confirmar (1/2): '
    read -r c1
    prompt_printf 'Digite novamente (2/2): '
    read -r c2
    [ "$c1" = "$DB_NAME" ] && [ "$c2" = "$DB_NAME" ] || die "Confirmação divergente. Operação abortada — nada foi alterado."
    ok "Dupla confirmação recebida."
}

sql_escape() {  # escape SQL para literais entre aspas simples (padrão SQL: ' -> '')
    # valida contra backslash no fim (MySQL interpreta \' como escape dentro de string)
    case "$1" in
        *\\) die "Senha contém backslash final — não suportado pelo escape SQL do instalador (escolha outra senha)." ;;
    esac
    printf '%s' "$1" | sed "s/'/''/g"
}

set_placeholder_password() {  # define a senha REAL do usuário criado, via ALTER USER
    # autentica-se como ADMIN (root via socket) e define a senha do usuário da app;
    # a senha vai escapada dentro do SQL (nunca em argv visível como argumento de senha)
    local esc
    esc="$(sql_escape "$DB_PASSWORD")"
    "$BANCO_CLIENT_CMD" -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$esc';"
}

# ----------------------------------------------------------------------------
# T008 — Clone (FR-008, R7)
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
# T008 — venv + requirements (FR-009, R8)
# ----------------------------------------------------------------------------
venv_ok() {
    [ -x "$INSTALL_DIR/.venv/bin/python" ] || return 1
    "$INSTALL_DIR/.venv/bin/python" -m pip --version >/dev/null 2>&1 || return 1
    "$INSTALL_DIR/.venv/bin/python" -c 'import fastapi, sqlalchemy, pymysql, ldap3, reportlab, openpyxl, dotenv' >/dev/null 2>&1
}

ensure_venv() {
    STEP="Ambiente virtual e dependências"
    if venv_ok; then
        ok "venv existente válido — reutilizado."
        return
    fi
    if [ -d "$INSTALL_DIR/.venv" ]; then
        warn "venv inválido/incompleto detectado — removendo e recriando (artefato regenerável; nenhum dado é afetado)."
        $SUDO rm -rf "$INSTALL_DIR/.venv"
    fi
    $SUDO python3 -m venv "$INSTALL_DIR/.venv"
    $SUDO "$INSTALL_DIR/.venv/bin/python" -m pip install --upgrade pip >/dev/null
    # Saída VISÍVEL (sem >/dev/null): pip demora minutos e output silencioso parece
    # travamento — que convida a uma 2ª execução concorrente (causa real de
    # crash-loop ENOENT observada em instalação real)
    info "Instalando requirements.txt (do repositório recém-clonado; leva alguns minutos)..."
    $SUDO "$INSTALL_DIR/.venv/bin/python" -m pip install --progress-bar off -r "$INSTALL_DIR/requirements.txt" >&2
    # FR-009: validação final = imports do próprio README (roda como o usuário do serviço,
    # pois o venv é dele; o chown ocorre depois, em ensure_service_user)
    "$INSTALL_DIR/.venv/bin/python" -c 'import fastapi, sqlalchemy, pymysql, ldap3, reportlab, openpyxl, dotenv'
    ok "Dependências instaladas e validadas (imports OK)."
}

# ----------------------------------------------------------------------------
# T007 (parte final) — teste de conexão REAL via engine do projeto (FR-007)
# ----------------------------------------------------------------------------
test_db_connection() {
    STEP="Teste de conexão com o banco (engine do projeto)"
    # CWD = diretório do projeto: `from app.config import ...` exige o pacote app
    # importável (equivalente ao WorkingDirectory da unit; falhou em CWD arbitrário)
    ( cd "$INSTALL_DIR" && "$INSTALL_DIR/.venv/bin/python" - "$DB_NAME" <<PYEOF
import sys
from app.config import DATABASE_URL
from sqlalchemy import create_engine, text
e = create_engine(DATABASE_URL)
c = e.connect()
print("CONEXÃO OK")
print("BANCO:", c.execute(text("SELECT DATABASE()")).scalar())
assert c.execute(text("SELECT DATABASE()")).scalar() == sys.argv[1], "banco inesperado"
c.close()
PYEOF
    )
    ok "Conexão validada via DATABASE_URL (mariadb+pymysql)."
}

# ----------------------------------------------------------------------------
# T009 — .env (FR-010, R6): 0600, nunca sobrescrito
# ----------------------------------------------------------------------------
ensure_env_file() {
    STEP="Arquivo de configuração .env"
    local env_file="$INSTALL_DIR/.env"

    if [ -f "$env_file" ]; then
        local bak
        bak="$env_file.bak-$(date +%Y%m%d%H%M%S)"
        warn ".env existente — NUNCA é sobrescrito."
        $SUDO cp -a "$env_file" "$bak"
        ok "Backup criado: $bak"
        # Caso real: reexecução após falha no meio da instalação — o .env da rodada
        # anterior aponta para a senha ANTERIOR (ou não existe ainda). Oferece atualizar
        # APENAS o DATABASE_URL quando o banco foi criado/recriado NESTA execução.
        if [ "$NON_INTERACTIVE" != "true" ] && [ "$DB_PASSWORD_CHANGED" = "true" ]; then
            prompt_printf 'DATABASE_URL do .env aponta para senha diferente da desta execução. Atualizar apenas o DATABASE_URL? (S/n): '
            read -r ans
            case "$ans" in
                n|N|nao|não|no)
                    warn ".env mantido sem alterações (valores existentes preservados)."
                    ;;
                *)
                    $SUDO sed -i "s|^DATABASE_URL=.*|DATABASE_URL=$DATABASE_URL_BUILT|" "$env_file"
                    ok "DATABASE_URL atualizado no .env existente (demais chaves preservadas)."
                    ;;
            esac
        else
            # Comportamento original: completa apenas chaves ausentes (merge consentido)
            if [ "$NON_INTERACTIVE" != "true" ]; then
                prompt_printf 'Completar chaves ausentes no .env existente com os valores desta instalação? (s/N): '
                read -r ans
                case "$ans" in
                    s|S|sim|SIM|y|Y)
                        grep -q '^DATABASE_URL=' "$env_file" || echo "DATABASE_URL=$DATABASE_URL_BUILT" | $SUDO tee -a "$env_file" >/dev/null
                        grep -q '^APP_HOST='     "$env_file" || echo "APP_HOST=$APP_HOST" | $SUDO tee -a "$env_file" >/dev/null
                        grep -q '^APP_PORT='     "$env_file" || echo "APP_PORT=$APP_PORT" | $SUDO tee -a "$env_file" >/dev/null
                        ok "Chaves ausentes adicionadas ao .env existente."
                        ;;
                    *) warn ".env mantido sem alterações (valores existentes preservados)." ;;
                esac
            else
                warn "Modo não interativo: .env mantido sem alterações (valores existentes preservados)."
            fi
        fi
        chmod 600 "$env_file"
        return
    fi

    umask 077  # arquivo nasce 0600 (SR-002)
    cat > "$env_file" <<ENVEOF
# Gerado por install.sh (feature 027) em $(date '+%Y-%m-%d %H:%M:%S %Z')
# Conexão com o banco MariaDB/MySQL (obrigatória — a aplicação não inicia sem ela)
DATABASE_URL=$DATABASE_URL_BUILT

# Bind da aplicação
APP_HOST=$APP_HOST
APP_PORT=$APP_PORT
ENVEOF

    if ! command -v mysqldump >/dev/null 2>&1; then
        echo "" >> "$env_file"
        echo "# Caminho do mysqldump (não está no PATH do processo do serviço)" >> "$env_file"
        echo "MYSQLDUMP_PATH=$(command -v mysqldump || echo /usr/bin/mysqldump)" >> "$env_file"
    fi
    chmod 600 "$env_file"
    ok ".env gerado com permissões 0600 (senha percent-encoded — SR-002)."
}

build_database_url() {  # percent-encoding programático (nunca montagem manual — R5/R6)
    DATABASE_URL_BUILT="$("$INSTALL_DIR/.venv/bin/python" - "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_NAME" <<'PYEOF'
import sys
from urllib.parse import quote_plus
user, pwd, host, port, db = sys.argv[1:6]
print(f"mariadb+pymysql://{quote_plus(user)}:{quote_plus(pwd)}@{host}:{port}/{db}")
PYEOF
)"
}

# ----------------------------------------------------------------------------
# T010 — usuário/grupo/permissões/unit systemd (FR-012, R9/R10)
# ----------------------------------------------------------------------------
ensure_service_user() {
    STEP="Usuário e permissões do serviço"
    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        $SUDO groupadd --system "$SERVICE_GROUP"
        ok "Grupo $SERVICE_GROUP criado."
    fi
    if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
        $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin -g "$SERVICE_GROUP" "$SERVICE_USER"
        ok "Usuário de sistema $SERVICE_USER criado (sem login)."
    else
        ok "Usuário $SERVICE_USER já existe — reutilizado."
    fi
    $SUDO chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
    chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
    $SUDO mkdir -p "$INSTALL_DIR/$APP_LOG_DIR" "$INSTALL_DIR/$BACKUP_DIR"
    $SUDO chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR/$APP_LOG_DIR" "$INSTALL_DIR/$BACKUP_DIR"
    ok "Diretório $INSTALL_DIR e data/ sob $SERVICE_USER:$SERVICE_GROUP."
}

ensure_systemd_unit() {
    STEP="Unidade systemd"
    local unit="/etc/systemd/system/$SERVICE_NAME.service"
    local content
    content="$(cat <<UNITEOF
[Unit]
Description=SisPatrimônio Pro
After=network-online.target $BANCO_SERVICE_DETECTED
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/.venv/bin/python $INSTALL_DIR/run.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
)"
    if [ -f "$unit" ] && [ "$(cat "$unit")" = "$content" ]; then
        ok "Unidade $unit já está correta — inalterada (idempotência)."
    else
        if [ -f "$unit" ]; then
            warn "Unidade existente difere do conteúdo gerado — atualizando."
        fi
        printf '%s\n' "$content" > "$unit"
        ok "Unidade $unit instalada (padrão real do README + usuário dedicado)."
    fi
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    ok "Serviço $SERVICE_NAME habilitado no boot (multi-user.target)."
}

# ----------------------------------------------------------------------------
# T011 — start + health (FR-013, R11)
# ----------------------------------------------------------------------------
pre_start_sanity() {  # falha ANTES do start nomeando o arquivo ausente (evita
                      # crash-loop ENOENT opaco observado em instalação real)
    STEP="Sanity pré-start"
    local missing=()
    [ -r "$INSTALL_DIR/.env" ]            || missing+=("EnvironmentFile: $INSTALL_DIR/.env")
    [ -x "$INSTALL_DIR/.venv/bin/python" ] || missing+=("ExecStart: $INSTALL_DIR/.venv/bin/python")
    [ -f "$INSTALL_DIR/run.py" ]           || missing+=("run.py: $INSTALL_DIR/run.py")
    if [ "${#missing[@]}" -gt 0 ]; then
        local m
        err "Arquivos exigidos pela unit estão AUSENTES — o serviço NÃO será iniciado (FR-019):"
        for m in "${missing[@]}"; do err "  - $m"; done
        die "Instalação incompleta. Reexecute o instalador (idempotente) — e evite rodar duas instâncias ao mesmo tempo."
    fi
    ok "Arquivos do serviço presentes (.env, venv, run.py)."
}

# T011 — init_db explícito (efeito do run.py, mas VERIFICADO pelo instalador:
# a unidade executa o mesmo comando, portanto sem risco de divergência; se o
# boot do app falhar antes do create_all, o instalador declara sucesso com o
# banco vazio e o app só quebra depois — traceback 'backup_config doesn't
# exist' observado em instalação real). Idempotente: create_all nunca destrói.
stop_service_if_running() {  # corrida 1050: serviço de rodada anterior em
    # crash-loop (Restart=on-failure) executa init_db() a cada boot; se estiver
    # de pé quando o instalador roda o init_db(), ambos avaliam "tabela não
    # existe" ao mesmo tempo e o perdedor leva 1050 "Table already exists"
    STEP="Parada do serviço (evita corrida com init_db do app)"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            $SUDO systemctl stop "$SERVICE_NAME"
            ok "Serviço $SERVICE_NAME parado (rodada anterior) — reativado ao final."
        else
            ok "Serviço $SERVICE_NAME instalado, mas inativo — nada a parar."
        fi
    else
        ok "Serviço $SERVICE_NAME ainda não instalado — nada a parar (primeira instalação)."
    fi
}

init_database() {
    STEP="Inicialização do schema do banco (init_db)"
    info "Executando init_db() do projeto (create_all + migrações leves)..."
    if ! (
        cd "$INSTALL_DIR"
        set +e
        ./.venv/bin/python -c "from app.database import init_db; init_db()"
        rc=$?
        set -e
        exit "$rc"
    ); then
        die "init_db() falhou — verificar DATABASE_URL/.env e acesso do usuário do banco. Instalação interrompida (nenhum dado alterado)."
    fi
    ok "Schema verificado/criado via init_db() do projeto."
}

start_and_health_check() {
    STEP="Inicialização e verificação de saúde"
    $SUDO systemctl start "$SERVICE_NAME"
    info "Aguardando /health (até ${HEALTH_TIMEOUT_SECONDS}s)..."
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
    err "=== Últimas linhas do journal do serviço (sem segredos) ==="
    journalctl -u "$SERVICE_NAME" -n 60 --no-pager 2>/dev/null || true
    err "=== Traceback da última falha, se houver ==="
    journalctl -u "$SERVICE_NAME" --no-pager 2>/dev/null | grep -E 'Error|Traceback|raise_mysql_exception' | tail -10 || true
    err "=== systemctl status ==="
    systemctl --no-pager status "$SERVICE_NAME" 2>/dev/null | head -15 || true
    err "=== unit instalada (systemctl cat) ==="
    systemctl cat "$SERVICE_NAME" 2>/dev/null || true
    # Interrompe o crash-loop (Restart=on-failure reiniciaria para sempre um
    # serviço quebrado — comportamento observado em instalação real)
    $SUDO systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    warn "Serviço PARADO para encerrar o loop de reinício. Reexecute o instalador quando quiser tentar novamente (idempotente)."
    die "Falha na verificação de saúde (FR-013). Diagnóstico acima; log completo em $INSTALL_LOG."
}

# ----------------------------------------------------------------------------
# T012/T018 — bateria pós-instalação + resumo (FR-014, R14)
# ----------------------------------------------------------------------------
post_install_checks() {
    STEP="Bateria de verificação pós-instalação"
    local failures=0

    python_at_least "$MIN_PYTHON_MAJOR" "$MIN_PYTHON_MINOR" && ok "Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}: OK" || { err "Python: FALHOU"; failures=$((failures+1)); }
    venv_ok && ok "venv + dependências: OK" || { err "venv/dependências: FALHOU"; failures=$((failures+1)); }
    systemctl is-active --quiet "$BANCO_SERVICE_DETECTED" && ok "Banco ativo ($BANCO_SERVICE_DETECTED): OK" || { err "Banco ativo: FALHOU"; failures=$((failures+1)); }
    # Mesmo contrato da unit (WorkingDirectory): imports de app.* exigem CWD = projeto
    ( cd "$INSTALL_DIR" && "$INSTALL_DIR/.venv/bin/python" - <<PYEOF >/dev/null 2>&1) && ok "Conexão com o banco: OK" || { err "Conexão com o banco: FALHOU"; failures=$((failures+1)); }
from app.database import SessionLocal
from sqlalchemy import text
db = SessionLocal()
db.execute(text("SELECT 1"))
db.close()
PYEOF
    ( cd "$INSTALL_DIR" && "$INSTALL_DIR/.venv/bin/python" - <<PYEOF >/dev/null 2>&1) && ok "Tabela base (users) existente: OK" || { err "Tabela base: FALHOU"; failures=$((failures+1)); }
from app.database import SessionLocal
from sqlalchemy import text
db = SessionLocal()
db.execute(text("SELECT 1 FROM users LIMIT 1"))
db.close()
PYEOF
    systemctl is-active --quiet "$SERVICE_NAME" && ok "Serviço $SERVICE_NAME ativo: OK" || { err "Serviço ativo: FALHOU"; failures=$((failures+1)); }
    systemctl is-enabled --quiet "$SERVICE_NAME" && ok "Serviço habilitado no boot: OK" || { err "Serviço habilitado: FALHOU"; failures=$((failures+1)); }
    curl -fsS "http://127.0.0.1:$APP_PORT/health" >/dev/null 2>&1 && ok "HTTP /health: OK" || { err "HTTP /health: FALHOU"; failures=$((failures+1)); }

    if [ "$failures" -gt 0 ]; then
        die "$failures verificação(ões) pós-instalação falharam — veja mensagens acima e o log."
    fi
    ok "Bateria completa: todas as verificações passaram."
}

print_summary() {
    local ip_addr
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo >&2
    echo "${C_BOLD}  ══════════════════════════════════════════════════════════════${C_RESET}" >&2
    ok "SisPatrimônio Pro instalado com sucesso!"
    echo "${C_BOLD}  ══════════════════════════════════════════════════════════════${C_RESET}" >&2
    echo >&2
    echo "${C_BOLD}  ACESSO${C_RESET}" >&2
    _kv "Aplicação   " "http://${ip_addr:-$APP_HOST}:$APP_PORT"
    _kv "Swagger API " "http://${ip_addr:-$APP_HOST}:$APP_PORT/docs"
    _kv "Health check" "http://${ip_addr:-$APP_HOST}:$APP_PORT/health"
    echo >&2
    echo "${C_BOLD}  INSTALAÇÃO${C_RESET}" >&2
    _kv "Diretório   " "$INSTALL_DIR"
    _kv "Configuração" "$INSTALL_DIR/.env (0600 — contém credenciais)"
    _kv "Serviço     " "$SERVICE_NAME (usuário Linux: $SERVICE_USER)"
    _kv "Log         " "$INSTALL_LOG"
    _kv "Logs/Backups" "$INSTALL_DIR/data/logs/ · $INSTALL_DIR/data/backups/"
    echo >&2
    echo "${C_BOLD}  GERENCIAR O SERVIÇO${C_RESET}" >&2
    echo "    systemctl status  $SERVICE_NAME" >&2
    echo "    systemctl restart $SERVICE_NAME" >&2
    echo "    systemctl stop    $SERVICE_NAME" >&2
    echo "    journalctl -u     $SERVICE_NAME -f" >&2
    echo >&2
    echo "${C_BOLD}  PRIMEIRO ADMINISTRADOR (escolha um caminho — nunca exibimos senhas)${C_RESET}" >&2
    echo "    A) CLI (recomendado):" >&2
    echo "       cd $INSTALL_DIR && sudo -u $SERVICE_USER .venv/bin/python -m app.cli \\" >&2
    echo "         create-user --username admin --name 'Administrador' --admin" >&2
    echo "       (a senha é solicitada de forma oculta; mínimo 8 caracteres)" >&2
    echo "    B) Primeiro acesso: abra a aplicação e use a página /setup" >&2
    echo "       (disponível enquanto não existir nenhum usuário)" >&2
    echo "    C) Variáveis de ambiente: AUTH_ADMIN_USERNAME/AUTH_ADMIN_PASSWORD" >&2
    echo "       no .env antes do primeiro start (remova após o primeiro login)" >&2
    echo >&2
    echo "  A senha do banco NÃO aparece neste resumo nem no log — está apenas" >&2
    echo "  no .env (DATABASE_URL), com permissão 0600." >&2
    echo "${C_BOLD}  ══════════════════════════════════════════════════════════════${C_RESET}" >&2
}

# ----------------------------------------------------------------------------
# T016 — auto-check de segurança (SR-001): a senha NÃO pode estar no log
# ----------------------------------------------------------------------------
security_self_check() {
    STEP="Auditoria de segurança do instalador"
    if [ -n "$DB_PASSWORD" ] && grep -Fq "$DB_PASSWORD" "$INSTALL_LOG" 2>/dev/null; then
        warn "A senha do banco foi encontrada no log do instalador — REVISE $INSTALL_LOG (remova a linha) e investigue a origem."
    else
        ok "Auto-check: nenhuma credencial no log (SR-001)."
    fi
    local perms
    perms="$(stat -c '%a' "$INSTALL_DIR/.env" 2>/dev/null || echo '?')"
    [ "$perms" = "600" ] && ok ".env com permissão 600 (SR-002)." || warn ".env com permissão $perms (esperado 600)."
    # Grants sem privilégios globais (SR-003): nenhuma linha com ON `*`.*
    local grants
    grants="$("$BANCO_CLIENT_CMD" -N -B -e "SHOW GRANTS FOR '$DB_USER'@'localhost';" 2>/dev/null | grep -c 'ON \`\*\`\.\*\`' || true)"
    if [ "${grants:-0}" = "0" ]; then
        ok "Usuário do banco sem privilégios globais (SR-003)."
    else
        warn "Verifique SHOW GRANTS para '$DB_USER' — padrão global detectado."
    fi
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    setup_logging
    echo >&2
    echo "==============================================================" >&2
    info "SisPatrimônio Pro — Instalador Linux v${APP_VERSION_INSTALLER} ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "==============================================================" >&2
    echo >&2

    STEP="Parâmetros e validação"
    validate_inputs
    require_root
    check_distro
    check_connectivity
    detect_host
    STEP="Coleta de credenciais"
    collect_secrets

    # Interação ANTES de qualquer mutação (R12/R13)
    STEP="Confirmação do plano"
    confirm_plan
    STEP="Confirmação de recriação de banco"
    confirm_recreate_db

    run_step "Pacotes do sistema (Python, Git, MariaDB)"  ensure_packages
    run_step "Código-fonte (clone)"                       ensure_repo
    run_step "Ambiente virtual e dependências"            ensure_venv
    run_step "Montagem da URL do banco"                   build_database_url
    run_step "Banco de dados (criação/validação)"         ensure_database
    run_step "Arquivo de configuração .env"               ensure_env_file
    run_step "Teste de conexão com o banco"               test_db_connection
    run_step "Usuário e permissões do serviço"            ensure_service_user
    run_step "Unidade systemd"                            ensure_systemd_unit
    run_step "Sanity pré-start"                           pre_start_sanity
    run_step "Parada do serviço de rodada anterior"       stop_service_if_running
    run_step "Inicialização do schema (init_db)"          init_database
    run_step "Start + health check"                       start_and_health_check
    run_step "Bateria pós-instalação"                     post_install_checks
    run_step "Auditoria de segurança"                     security_self_check

    print_summary
    ok "Concluído."
}

main "$@"
