#!/usr/bin/env bash
# ============================================================================
# SisPatrimônio Pro — Desinstalador de Produção Linux via DOCKER
# (variante Docker do desinstalador original — uninstall.sh permanece intacto)
#
# Reverte a instalação criada por install-docker.sh, nesta ordem:
#   1. containers (stop/down do Compose — app + db)
#   2. volume do banco db-data (SOMENTE com confirmação digitando o nome)
#   3. volume app-data — backups/logs da app (SOMENTE com confirmação própria)
#   4. diretório da aplicação (código, .env, docker-compose.yml do clone)
#   5. imagem da app (build local) e imagem mariadb:11 (apenas se órfãs)
#   6. log do instalador
#
# Segurança (mesmos princípios do uninstall.sh — SR-001..SR-005):
#   - NADA destrutivo sem confirmação explícita (ou --yes para o básico);
#   - volume do banco NUNCA é apagado por engano: exige digitar o nome do banco;
#   - --purge-docker remove imagens (app + mariadb) — dupla confirmação;
#   - detecta banco/volume a partir do .env + compose instalados (não hardcode);
#   - idempotente: pode ser executado repetidamente; nada de erros feios.
#
# Diferenças em relação ao uninstall.sh nativo (mesma filosofia, alvo docker):
#   - systemd/useradd não existem aqui: containers + volumes + imagens;
#   - não há "purge do MariaDB do host" — o banco vive no volume db-data;
#   - o Docker Engine instalado NÃO é removido (uso geral do servidor),
#     exceto com --purge-docker? NÃO — mesmo --purge-docker só remove as
#     IMAGENS do projeto (jamais o Engine/daemon).
#
# Uso:
#   sudo bash uninstall-docker.sh                        # interativo (pergunta tudo)
#   sudo bash uninstall-docker.sh --yes                  # remove containers+diretório+imagens
#                                                        # órfãs; VOLUME do banco ainda exige
#                                                        # confirmação digitando o nome
#   sudo bash uninstall-docker.sh --keep-db              # NÃO toca no volume do banco
#   sudo bash uninstall-docker.sh --purge-docker         # também remove as imagens do
#                                                        # projeto (dupla confirmação)
#   sudo bash uninstall-docker.sh --install-dir Z
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

VERSION="2.1.0-docker"
INSTALL_DIR="/opt/SisPatrimonioPro"
INSTALL_LOG="/var/log/sispatrimonio-install-docker.log"
DB_IMAGE_DEFAULT="mariadb:11"

KEEP_DB="false"
PURGE_DOCKER="false"
ASSUME_YES="false"
DB_NAME=""
DB_VOLUME=""
APP_VOLUME=""      # resolvido do compose (volumes.app-data.name), se disponível
APP_IMAGE=""      # resolvido do compose (services.app.image), se disponível
APP_CNAME="sispat-app"
DB_CNAME="sispat-db"

_msg() {  # $1=formato printf (com cor/tag embutidas)  $2...=mensagem — SEMPRE stderr
    # stderr é sem buffer; misturar canais reordena a saída em consoles lentos
    # (serial/VNC) e sob pipe — mesma correção do uninstall.sh nativo (027).
    local fmt="$1"
    shift
    printf "$fmt" "$*" >&2
}
info() { _msg '\e[34m[ * ]\e[0m %s\n'  "$@"; }
ok()   { _msg '\e[32m[ OK ]\e[0m %s\n' "$@"; }
warn() { _msg '\e[33m[ !! ]\e[0m %s\n' "$@"; }
err()  { _msg '\e[31m[ XX ]\e[0m %s\n' "$@"; }
die()  { err "$*"; exit 1; }

prompt_printf() {  # prompt no canal stderr — MESMO canal do restante da saída
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
SisPatrimônio Pro — desinstalador de produção Linux via DOCKER v${VERSION}

Uso: sudo bash uninstall-docker.sh [opções]

  --yes                  Não pede confirmação para containers/diretório/imagens
                         órfãs (o VOLUME DO BANCO continua exigindo confirmação
                         explícita digitando o nome do banco)
  --keep-db              Não apaga o volume do banco (dados preservados)
  --purge-docker         Também remove as imagens do projeto (app local + mariadb
                         SE não for usada por outros containers — destrutivo;
                         exige dupla confirmação). O Docker Engine NUNCA é removido.
  --install-dir <caminho>   Default: ${INSTALL_DIR}
  --help                 Esta ajuda

Ordem da remoção:
  1. containers (compose down)  2. volume do banco (confirmação digitando o nome)
  3. volume app-data (backups/logs — confirmação própria)  4. diretório da app
  5. imagens do projeto (com --purge-docker)  6. log do instalador

Exit codes: 0 sucesso · 2 uso inválido · 1 falha de execução
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes)           ASSUME_YES="true" ;;
            --keep-db)       KEEP_DB="true" ;;
            --purge-docker)  PURGE_DOCKER="true" ;;
            --install-dir)   INSTALL_DIR="${2:-}"; shift ;;
            --help|-h)       usage; exit 0 ;;
            *)               usage; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
    [ -n "$INSTALL_DIR" ] || die "--install-dir não pode ser vazio."
}

confirm() {  # $1=pergunta → 0 se confirmado (respeita --yes; EOF/stdin fechado = NÃO confirmado)
    if [ "$ASSUME_YES" = "true" ]; then
        return 0
    fi
    prompt_printf "$1"
    local ans
    read -r ans || ans=""
    case "$ans" in
        s|S|sim|SIM|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

docker_ok() {  # daemon disponível? (desinstalação segue mesmo sem Docker — idempotência)
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

DCC() {  # compose com projeto/diretório fixos (só se o clone/compose existirem)
    docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"
}

detect_from_env_and_compose() {  # .env (banco) + compose (volume/containers), sem exibir segredos
    local detected="false"

    # --- nome do banco a partir do compose (fonte da verdade) ou fallback ---
    if [ -f "$INSTALL_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1; then
        local parsed
        if parsed="$(DB_PASSWORD=dummy SECRET_KEY=dummy DB_ROOT_PASSWORD=dummy APP_PORT=8000 \
            DCC config --format json 2>/dev/null)"; then
            eval "$(printf '%s' "$parsed" | python3 -c '
import json, shlex, sys
try:
    cfg = json.load(sys.stdin)
except Exception:
    sys.exit(0)
svc = cfg.get("services", {})

def envget(env, key):
    if isinstance(env, dict):
        return env.get(key)
    if isinstance(env, list):
        for item in env:
            if isinstance(item, str) and item.startswith(key + "="):
                return item.split("=", 1)[1]
    return None

db = svc.get("db", {})
app = svc.get("app", {})
db_name = envget(db.get("environment"), "MARIADB_DATABASE") or ""
app_cname = app.get("container_name") or "sispat-app"
db_cname = db.get("container_name") or "sispat-db"

db_volume = ""
for key in ("db-data", "db_data"):
    v = (cfg.get("volumes", {}) or {}).get(key) or {}
    if isinstance(v, dict) and v.get("name"):
        db_volume = v["name"]
        break
if not db_volume:
    proj = cfg.get("name") or "sispatrimoniopro"
    db_volume = f"{proj}_db-data"

app_volume = ""
for key in ("app-data", "app_data"):
    v = (cfg.get("volumes", {}) or {}).get(key) or {}
    if isinstance(v, dict) and v.get("name"):
        app_volume = v["name"]
        break
if not app_volume:
    proj = cfg.get("name") or "sispatrimoniopro"
    app_volume = f"{proj}_app-data"

app_image = app.get("image") or ""

print("DB_NAME=" + shlex.quote(str(db_name)))
print("DB_VOLUME=" + shlex.quote(str(db_volume)))
print("APP_VOLUME=" + shlex.quote(str(app_volume)))
print("APP_IMAGE=" + shlex.quote(str(app_image)))
print("APP_CNAME=" + shlex.quote(str(app_cname)))
print("DB_CNAME=" + shlex.quote(str(db_cname)))
' 2>/dev/null)" || true
            [ -n "$DB_NAME" ] && detected="true"
        fi
    fi

    # --- fallback: banco mencionado no .env (DB_PASSWORD/DB_NAME/DATABASE_URL) ---
    if [ "$detected" != "true" ] && [ -r "$INSTALL_DIR/.env" ]; then
        local n
        n="$(grep -E '^DB_NAME=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2- || true)"
        if [ -n "$n" ]; then
            DB_NAME="$n"
        else
            local url
            url="$(grep -E '^DATABASE_URL=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2- || true)"
            if [ -n "$url" ]; then
                n="$(printf '%s' "$url" | sed -E 's#^.*/([^/?]+)(\?.*)?$#\1#')"
                [ -n "$n" ] && DB_NAME="$n"
            fi
        fi
        [ -n "$DB_NAME" ] && detected="true"
    fi

    # --- volume: se o compose não resolveu, deriva do diretório (padrão do Compose) ---
    if [ -z "$DB_VOLUME" ]; then
        local proj
        proj="$(compose_project_name)"
        DB_VOLUME="${proj}_db-data"
    fi
    if [ -z "$APP_VOLUME" ]; then
        local proj
        proj="$(compose_project_name)"
        APP_VOLUME="${proj}_app-data"
    fi

    [ "$detected" = "true" ]
}

compose_project_name() {  # nome de projeto do Compose derivado do diretório (mesma regra do Compose)
    local proj
    proj="$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"
    [ -n "$proj" ] || proj="sispatrimoniopro"
    printf '%s' "$proj"
}

remove_containers() {  # equivalente docker do remove_service nativo
    info "Containers (compose down)"
    if ! docker_ok; then
        warn "Docker indisponível — containers NÃO removidos nesta execução (reexecute com o Docker ativo)."
        return
    fi
    if [ -f "$INSTALL_DIR/docker-compose.yml" ] && docker compose version >/dev/null 2>&1; then
        if DCC ps -q 2>/dev/null | grep -q . || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$APP_CNAME" \
            || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CNAME"; then
            DCC down --remove-orphans >&2 2>/dev/null || true
            ok "Containers do projeto removidos ($APP_CNAME, $DB_CNAME)."
        else
            ok "Nenhum container do projeto em execução — nada a fazer."
        fi
    else
        # Sem compose: remove containers por nome (best-effort, idempotente)
        local c removed=0
        for c in "$APP_CNAME" "$DB_CNAME"; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
                docker rm -f "$c" >/dev/null 2>&1 || true
                removed=$((removed + 1))
            fi
        done
        if [ "$removed" -gt 0 ]; then
            ok "$removed container(s) removido(s) por nome (compose ausente)."
        else
            ok "Nenhum container do projeto encontrado — nada a fazer."
        fi
    fi
}

remove_db_volume() {  # VOLUME DO BANCO = todos os dados: confirmação digitando o nome (mesmo com --yes)
    info "Volume do banco de dados"
    if [ "$KEEP_DB" = "true" ]; then
        warn "Desinstalação com --keep-db: volume do banco PRESERVADO ($DB_VOLUME)."
        return
    fi
    if ! docker_ok; then
        if docker_ok || command -v docker >/dev/null 2>&1; then
            warn "Docker daemon indisponível — volume '$DB_VOLUME' PRESERVADO (reexecute com o Docker ativo para removê-lo)."
        else
            warn "Docker não instalado — volume '$DB_VOLUME' PRESERVADO (nada a fazer)."
        fi
        return
    fi
    if ! docker volume ls -q 2>/dev/null | grep -qx "$DB_VOLUME"; then
        ok "Volume '$DB_VOLUME' não existe — nada a fazer."
        return
    fi

    if [ -n "$DB_NAME" ]; then
        warn "O volume do banco '$DB_VOLUME' contém o banco '$DB_NAME' e TODOS os seus dados."
    else
        warn "O volume do banco '$DB_VOLUME' contém TODOS os dados do banco."
    fi
    # Confirmação OBRIGATÓRIA (mesmo com --yes): digitar o nome do banco
    prompt_printf "Digite o nome do banco para CONFIRMAR a remoção do volume '$DB_VOLUME' (vazio = preservar): "
    local c1
    read -r c1 || c1=""
    if [ -z "$DB_NAME" ]; then
        if [ "$c1" = "$DB_VOLUME" ]; then
            DB_NAME="$DB_VOLUME"   # aceita o nome do volume como confirmação quando o banco é desconhecido
        else
            warn "Banco PRESERVADO (confirmação não recebida)."
            return
        fi
    fi
    if [ "$c1" != "$DB_NAME" ]; then
        warn "Banco PRESERVADO (confirmação não recebida)."
        return
    fi
    docker volume rm "$DB_VOLUME" >/dev/null 2>&1 \
        || { warn "Não foi possível remover o volume (em uso?). Pare os containers e reexecute."; return; }
    ok "Volume '$DB_VOLUME' (banco '$DB_NAME') removido."
}

remove_app_volume() {  # backups/logs da app — decisão separada (não é o banco)
    info "Volume app-data (backups/logs da aplicação)"
    if ! docker_ok; then
        warn "Docker daemon indisponível — volume app-data PRESERVADO."
        return
    fi
    local app_volume="$APP_VOLUME"
    [ -n "$app_volume" ] || app_volume="$(compose_project_name)_app-data"
    if ! docker volume ls -q 2>/dev/null | grep -qx "$app_volume"; then
        ok "Volume '$app_volume' não existe — nada a fazer."
        return
    fi
    if confirm "Remover o volume '$app_volume' (backups/logs da aplicação — irreversível)? (s/N): "; then
        docker volume rm "$app_volume" >/dev/null 2>&1 \
            && ok "Volume '$app_volume' removido." \
            || warn "Não foi possível remover o volume '$app_volume' (em uso?)."
    else
        warn "Volume app-data PRESERVADO por solicitação (backups mantidos em Docker)."
    fi
}

remove_app_dir() {  # idêntico ao nativo: código, .env (com credenciais) e clones
    info "Diretório da aplicação"
    if [ -d "$INSTALL_DIR" ]; then
        if confirm "Remover $INSTALL_DIR INTEIRO (código, .env com credenciais, compose do clone — irreversível)? (s/N): "; then
            rm -rf "$INSTALL_DIR"
            ok "Diretório removido."
        else
            warn "Diretório PRESERVADO por solicitação (.env mantido — remova manualmente se não precisar das credenciais)."
        fi
    else
        ok "$INSTALL_DIR não existe — nada a fazer."
    fi
}

purge_images() {  # DESTRUTIVO OPCIONAL (--purge-docker): imagens do projeto — dupla confirmação (padrão 027)
    if [ "$PURGE_DOCKER" != "true" ]; then
        return
    fi
    info "Remoção das imagens do projeto (solicitada via --purge-docker)"
    if ! docker_ok; then
        warn "Docker daemon indisponível — imagens PRESERVADAS."
        return
    fi
    warn "================================================================"
    warn "ATENÇÃO: isto remove as imagens construídas para este projeto."
    warn "Outros containers/im do servidor NÃO são afetados; o Docker"
    warn "Engine (daemon) NUNCA é removido por este script."
    warn "================================================================"
    prompt_printf "Digite EXATAMENTE 'PURGAR-IMAGENS' para confirmar: "
    local c1
    read -r c1 || c1=""
    [ "$c1" = "PURGAR-IMAGENS" ] || { warn "Imagens PRESERVADAS."; return; }
    prompt_printf "Confirmar novamente (s/N): "
    local c2
    read -r c2 || c2=""
    case "$c2" in
        s|S|sim|SIM|y|Y) ;;
        *) warn "Imagens PRESERVADAS."; return ;;
    esac

    # Imagem da app: resolvida do compose (services.app.image) ou candidatos
    # usuais de build local; última alternativa: derivada do diretório
    local app_img img removed=0
    local -a candidates=()
    [ -n "$APP_IMAGE" ] && candidates+=("$APP_IMAGE")
    candidates+=("$(compose_project_name)-app" "sispatrimoniopro-app" "sispat-app")
    for app_img in "${candidates[@]}"; do
        if docker image inspect "$app_img" >/dev/null 2>&1; then
            docker rmi "$app_img" >/dev/null 2>&1 && { ok "Imagem da app removida: $app_img"; removed=$((removed+1)); } \
                || warn "Imagem da app '$app_img' está EM USO por um container — não removida."
            break
        fi
    done

    # mariadb:11: remove APENAS se nenhum outro container a referencia (órfã)
    if docker image inspect "$DB_IMAGE_DEFAULT" >/dev/null 2>&1; then
        if [ -z "$(docker ps -a --filter "ancestor=$DB_IMAGE_DEFAULT" --format '{{.ID}}' 2>/dev/null)" ]; then
            docker rmi "$DB_IMAGE_DEFAULT" >/dev/null 2>&1 && { ok "Imagem órfã removida: $DB_IMAGE_DEFAULT"; removed=$((removed+1)); } \
                || warn "Não foi possível remover $DB_IMAGE_DEFAULT."
        else
            ok "Imagem $DB_IMAGE_DEFAULT ainda referenciada por outros containers — PRESERVADA."
        fi
    fi

    if [ "$removed" -eq 0 ]; then
        ok "Nenhuma imagem do projeto precisou ser removida."
    fi
}

remove_install_log() {  # idêntico ao nativo
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
    info "SisPatrimônio Pro — Desinstalador Linux via DOCKER v${VERSION} ($(date '+%Y-%m-%d %H:%M:%S'))"
    if [ "$ASSUME_YES" != "true" ]; then
        prompt_printf "Desinstalar o SisPatrimônio Pro (DOCKER) deste servidor? (s/N): "
        local gate
        read -r gate || gate=""
        case "$gate" in
            s|S|sim|SIM|y|Y) ;;
            *) die "Desinstalação cancelada. Nada foi alterado." ;;
        esac
    fi

    # Detecção ANTES de remover o diretório (compose + .env são a fonte do
    # banco/volume — mesma lógica do detect_db_from_env do nativo)
    if detect_from_env_and_compose; then
        ok "Configuração detectada: banco '$DB_NAME' · volume '$DB_VOLUME' (senhas NUNCA exibidas)."
    else
        warn "compose/.env não encontrados/legíveis — o volume será inferido do diretório; o nome do banco será pedido na etapa de banco."
    fi

    remove_containers
    remove_db_volume
    remove_app_volume
    remove_app_dir
    purge_images
    remove_install_log

    echo >&2
    ok "Desinstalação concluída."
    [ "$KEEP_DB" = "true" ] && warn "Lembrete: volume do banco foi PRESERVADO (--keep-db)."
    warn "Docker Engine e demais imagens/containers do servidor foram mantidos — remova manualmente se desejar."
}

main "$@"
