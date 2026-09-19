#!/usr/bin/env bash
# ============================================================================
# SisPatrimônio Pro — Desinstalador de Produção Linux (sequência da Feature 027)
#
# Reverte a instalação criada por install.sh, nesta ordem:
#   1. serviço systemd (stop/disable) + unit
#   2. diretório da aplicação (código, venv, .env, logs, backups)
#   3. usuário/grupo Linux do serviço
#   4. banco e usuário do MariaDB/MySQL (SOMENTE com confirmação explícita)
#   5. MariaDB inteiro (apenas com --purge-mariadb + dupla confirmação)
#   6. log do instalador
#
# Segurança (mesmos princípios do install.sh — SR-001..SR-005):
#   - NADA destrutivo sem confirmação explícita (ou --yes para o básico);
#   - banco NUNCA é apagado por engano: exige digitar o nome do banco;
#   - --purge-mariadb apaga TODOS os bancos do servidor — dupla confirmação;
#   - detecta o banco/usuário a partir do .env instalado (não hardcode);
#   - idempotente: pode ser executado repetidamente; nada de 404/erros feios.
#
# Uso:
#   sudo bash uninstall.sh                        # interativo (pergunta tudo)
#   sudo bash uninstall.sh --yes                  # remove app+serviço+usuário Linux;
#                                                 # banco ainda exige confirmação
#   sudo bash uninstall.sh --keep-db              # NÃO toca no banco/usuário do banco
#   sudo bash uninstall.sh --purge-mariadb        # remove o MariaDB inteiro (destrutivo)
#   sudo bash uninstall.sh --service-name X --service-user Y --install-dir Z
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
SERVICE_NAME="sispatrimoniopro"
SERVICE_USER="sispatrimonio"
SERVICE_GROUP="sispatrimonio"
INSTALL_DIR="/opt/SisPatrimonioPro"
INSTALL_LOG="/var/log/sispatrimonio-install.log"

KEEP_DB="false"
PURGE_MARIADB="false"
ASSUME_YES="false"
DB_NAME=""
DB_USER=""
DB_HOST="localhost"
DB_PORT="3306"
BANCO_CLIENT_CMD=""

_msg() {  # $1=formato printf (com cor/tag embutidas)  $2...=mensagem — SEMPRE stderr
    # stderr é sem buffer; misturar canais (stdout vs /dev/tty) reordena a saída
    # em consoles lentos (serial/VNC) e sob pipe — bug observado e corrigido no
    # install.sh (027). Um único canal garante a ordem em qualquer terminal.
    # Cor/tag no FORMATO (\e em argumento %s NÃO é interpretado pelo printf).
    local fmt="$1"
    shift
    printf "$fmt" "$*" >&2
}
info() { _msg '\e[34m[ * ]\e[0m %s\n'  "$@"; }
ok()   { _msg '\e[32m[ OK ]\e[0m %s\n' "$@"; }
warn() { _msg '\e[33m[ !! ]\e[0m %s\n' "$@"; }
err()  { _msg '\e[31m[ XX ]\e[0m %s\n' "$@"; }
die()  { err "$*"; exit 1; }

prompt_printf() {  # prompt no canal stderr — MESMO canal do restante da saída (ordem garantida)
    # Não usar /dev/tty: um segundo canal reordena a saída em consoles lentos
    # (mesma correção aplicada ao install.sh na feature 027).
    printf '%s' "$*" >&2
}

on_error() {
    local exit_code=$?
    err "Falha na desinstalação (exit $exit_code, linha $1)."
    err "Reexecute o comando — a desinstalação é idempotente."
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

sql_escape() {  # padrão SQL (' -> ''); backslash final não é suportado (027)
    case "$1" in
        *\\) die "Nome contém backslash final — não suportado." ;;
    esac
    printf '%s' "$1" | sed "s/'/''/g"
}

usage() {
    cat <<EOF
SisPatrimônio Pro — desinstalador de produção Linux v${VERSION}

Uso: sudo bash uninstall.sh [opções]

  --yes                  Não pede confirmação para app/serviço/usuário Linux
                         (o BANCO continua exigindo confirmação explícita)
  --keep-db              Não apaga banco nem usuário do banco
  --purge-mariadb        Remove o MariaDB/MySQL inteiro (TODOS os bancos —
                         destrutivo; exige dupla confirmação)
  --install-dir <caminho>   Default: ${INSTALL_DIR}
  --service-name <nome>     Default: ${SERVICE_NAME}
  --service-user <usuário>  Default: ${SERVICE_USER}
  --help                 Esta ajuda

Exit codes: 0 sucesso · 2 uso inválido · 1 falha de execução
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes)            ASSUME_YES="true" ;;
            --keep-db)        KEEP_DB="true" ;;
            --purge-mariadb)  PURGE_MARIADB="true" ;;
            --install-dir)    INSTALL_DIR="${2:-}"; shift ;;
            --service-name)   SERVICE_NAME="${2:-}"; shift ;;
            --service-user)   SERVICE_USER="${2:-}"; shift ;;
            --help|-h)        usage; exit 0 ;;
            *)                usage; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
    [ -n "$INSTALL_DIR" ] || die "--install-dir não pode ser vazio."
    [ -n "$SERVICE_NAME" ] || die "--service-name não pode ser vazio."
    [ -n "$SERVICE_USER" ] || die "--service-user não pode ser vazio."
    # Deriva o grupo do usuário (install.sh usa usuário=grupo por default)
    SERVICE_GROUP="$SERVICE_USER"
}

confirm() {  # $1=pergunta → 0 se confirmado (respeita --yes)
    if [ "$ASSUME_YES" = "true" ]; then
        return 0
    fi
    prompt_printf "$1"
    local ans
    read -r ans
    case "$ans" in
        s|S|sim|SIM|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

detect_db_from_env() {  # lê DATABASE_URL do .env instalado (sem exibir a senha)
    local env_file="$INSTALL_DIR/.env"
    if [ ! -r "$env_file" ]; then
        return 1
    fi
    local url
    url="$(grep -E '^DATABASE_URL=' "$env_file" | head -1 | cut -d= -f2- || true)"
    [ -n "$url" ] || return 1
    # Parse SEM ecoar credenciais: mariadb+pymysql://user:pass@host:port/db[?...]
    DB_USER="$(printf '%s' "$url" | sed -E 's#^[^:]+://([^:]+):.*#\1#')"
    local rest
    rest="$(printf '%s' "$url" | sed -E 's#^[^:]+://[^:]+:[^@]+@##')"
    DB_HOST="$(printf '%s' "$rest" | sed -E 's#^([^:/]+):([0-9]+)/.*#\1#')"
    DB_PORT="$(printf '%s' "$rest" | sed -E 's#^([^:/]+):([0-9]+)/.*#\2#')"
    DB_NAME="$(printf '%s' "$rest" | sed -E 's#^[^/]+/([^?]+).*#\1#')"
    export DB_HOST DB_PORT   # mantidos para diagnóstico/operações manuais do operador
    [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]
}

remove_service() {
    info "Serviço systemd"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null || true
        ok "Serviço $SERVICE_NAME removido."
    else
        ok "Serviço $SERVICE_NAME não está instalado — nada a fazer."
    fi
}

remove_app_dir() {
    info "Diretório da aplicação"
    if [ -d "$INSTALL_DIR" ]; then
        if confirm "Remover $INSTALL_DIR INTEIRO (código, venv, .env, data/logs e data/backups — irreversível)? (s/N): "; then
            rm -rf "$INSTALL_DIR"
            ok "Diretório removido."
        else
            warn "Diretório PRESERVADO por solicitação."
        fi
    else
        ok "$INSTALL_DIR não existe — nada a fazer."
    fi
}

remove_service_user() {
    info "Usuário/grupo Linux do serviço"
    if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
        userdel "$SERVICE_USER" 2>/dev/null || warn "Não foi possível remover o usuário $SERVICE_USER (verifique processos)."
        ok "Usuário $SERVICE_USER removido."
    else
        ok "Usuário $SERVICE_USER não existe — nada a fazer."
    fi
    getent group "$SERVICE_GROUP" >/dev/null 2>&1 && groupdel "$SERVICE_GROUP" 2>/dev/null || true
}

remove_database() {
    info "Banco de dados"
    if [ "$KEEP_DB" = "true" ]; then
        warn "Desinstalação com --keep-db: banco e usuário do banco PRESERVADOS."
        return
    fi
    if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        ok "Cliente MariaDB/MySQL não presente — nada a fazer."
        return
    fi
    BANCO_CLIENT_CMD="$(command -v mariadb || command -v mysql)"
    if [ -n "$DB_NAME" ]; then
        warn "O .env instalado apontava para o banco '$DB_NAME' (usuário '$DB_USER')."
    else
        printf 'Nome do banco da aplicação a remover: ' >&2
        read -r DB_NAME
        [ -n "$DB_NAME" ] || { warn "Nenhum banco informado — preservado."; return; }
    fi
    # Confirmação OBRIGATÓRIA (mesmo com --yes): digitar o nome do banco
    prompt_printf "Digite o nome do banco para CONFIRMAR a remoção de '$DB_NAME' e seus dados (vazio = preservar): "
    read -r c1
    if [ "$c1" != "$DB_NAME" ]; then
        warn "Banco PRESERVADO (confirmação não recebida)."
        return
    fi
    local esc
    esc="$(sql_escape "$DB_NAME")"
    "$BANCO_CLIENT_CMD" -e "DROP DATABASE IF EXISTS \`$esc\`;"
    ok "Banco '$DB_NAME' removido."
    if [ -n "$DB_USER" ]; then
        prompt_printf "Remover também o usuário do banco '$DB_USER'@'localhost'? (s/N): "
        read -r c2
        case "$c2" in
            s|S|sim|SIM|y|Y)
                "$BANCO_CLIENT_CMD" -e "DROP USER IF EXISTS '$(sql_escape "$DB_USER")'@'localhost';"
                "$BANCO_CLIENT_CMD" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
                ok "Usuário '$DB_USER'@'localhost' removido."
                ;;
            *) warn "Usuário do banco preservado." ;;
        esac
    fi
}

purge_mariadb() {  # DESTRUTIVO: TODOS os bancos do servidor — dupla confirmação (padrão 027)
    if [ "$PURGE_MARIADB" != "true" ]; then
        return
    fi
    info "Remoção do MariaDB/MySQL (solicitada via --purge-mariadb)"
    warn "================================================================"
    warn "ATENÇÃO: isto apaga TODOS os bancos de dados deste servidor —"
    warn "não apenas o do SisPatrimônio. IRREVERSÍVEL."
    warn "================================================================"
    prompt_printf "Digite EXATAMENTE 'PURGAR-MARIADB' para confirmar: "
    read -r c1
    [ "$c1" = "PURGAR-MARIADB" ] || { warn "MariaDB PRESERVADO."; return; }
    prompt_printf "Confirmar novamente (s/N): "
    read -r c2
    case "$c2" in
        s|S|sim|SIM|y|Y) ;;
        *) warn "MariaDB PRESERVADO."; return ;;
    esac
    systemctl stop mariadb 2>/dev/null || systemctl stop mysql 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y 'mariadb-*' mariadb-server mariadb-client default-mysql-server >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
        rm -rf /var/lib/mysql /etc/mysql
        ok "MariaDB removido (pacotes + dados)."
    else
        warn "apt-get não encontrado — remova o MariaDB manualmente."
    fi
}

remove_install_log() {
    info "Log do instalador"
    if [ -f "$INSTALL_LOG" ]; then
        rm -f "$INSTALL_LOG"
        ok "$INSTALL_LOG removido."
    else
        ok "Nenhum log de instalação presente."
    fi
}

main() {
    parse_args "$@"
    if [ "$(id -u)" -ne 0 ]; then
        die "Execute como root ou via sudo."
    fi
    info "SisPatrimônio Pro — Desinstalador Linux v${VERSION} ($(date '+%Y-%m-%d %H:%M:%S'))"
    if [ "$ASSUME_YES" != "true" ]; then
        prompt_printf "Desinstalar o SisPatrimônio Pro deste servidor? (s/N): "
        read -r gate
        case "$gate" in
            s|S|sim|SIM|y|Y) ;;
            *) die "Desinstalação cancelada. Nada foi alterado." ;;
        esac
    fi

    # Detecção ANTES de remover o diretório (.env é a fonte do banco/usuário)
    if detect_db_from_env; then
        ok "Configuração detectada no .env: banco '$DB_NAME', usuário '$DB_USER' (senha NUNCA exibida)."
    else
        warn ".env não encontrado/legível — o nome do banco será perguntado na etapa de banco."
    fi

    remove_service
    remove_app_dir
    remove_service_user
    remove_database
    purge_mariadb
    remove_install_log

    echo >&2
    ok "Desinstalação concluída."
    [ "$KEEP_DB" = "true" ] && warn "Lembrete: banco/usuário do banco foram PRESERVADOS (--keep-db)."
    warn "Pacotes padrão (python3-venv, git, curl) foram mantidos — remova manualmente se desejar."
}

main "$@"
