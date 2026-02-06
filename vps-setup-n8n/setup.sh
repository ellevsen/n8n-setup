#!/usr/bin/env bash
# =============================================================================
# VPS Setup n8n - Script de instalação do zero
# Instala: Docker, Swarm, Portainer, Traefik, Postgres (com user n8n), Redis, n8n
# Stacks postgres, redis, traefik e n8n são lançadas via API do Portainer.
# Uso: copie .env.example para .env, preencha (ou deixe o script perguntar).
#      ./setup.sh
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STACKS_DIR="${SCRIPT_DIR}/stacks"

# -----------------------------------------------------------------------------
# Cores e helpers
# -----------------------------------------------------------------------------
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m'
log_info()  { echo -e "${green}[INFO]${nc} $*"; }
log_warn()  { echo -e "${yellow}[WARN]${nc} $*"; }
log_err()   { echo -e "${red}[ERR]${nc} $*"; }

gen_password() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

prompt_val() {
  local name="$1"
  local default="${2:-}"
  local val="${!name:-}"
  if [[ -z "$val" ]]; then
    read -r -p "  $name${default:+ [$default]}: " val
    val="${val:-$default}"
  fi
  echo "$val"
}

# Carrega .env se existir (exporta para o shell)
load_env() {
  local env_file="${SCRIPT_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    log_info "Carregando ${env_file}..."
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi
}

# Pergunta variáveis obrigatórias que estiverem vazias
gather_inputs() {
  log_info "Variáveis (use .env ou responda abaixo). Senhas vazias = geradas automaticamente."
  PORTAINER_ADMIN_USER="${PORTAINER_ADMIN_USER:-}"
  PORTAINER_ADMIN_USER=$(prompt_val PORTAINER_ADMIN_USER "admin")
  DOMAIN_PORTAINER="${DOMAIN_PORTAINER:-}"
  DOMAIN_PORTAINER=$(prompt_val DOMAIN_PORTAINER "")
  DOMAIN_TRAEFIK_DASHBOARD="${DOMAIN_TRAEFIK_DASHBOARD:-}"
  DOMAIN_TRAEFIK_DASHBOARD=$(prompt_val DOMAIN_TRAEFIK_DASHBOARD "")
  DOMAIN_N8N_EDITOR="${DOMAIN_N8N_EDITOR:-}"
  DOMAIN_N8N_EDITOR=$(prompt_val DOMAIN_N8N_EDITOR "")
  DOMAIN_N8N_WEBHOOK="${DOMAIN_N8N_WEBHOOK:-}"
  DOMAIN_N8N_WEBHOOK=$(prompt_val DOMAIN_N8N_WEBHOOK "")
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
  LETSENCRYPT_EMAIL=$(prompt_val LETSENCRYPT_EMAIL "")

  for v in DOMAIN_PORTAINER DOMAIN_TRAEFIK_DASHBOARD DOMAIN_N8N_EDITOR DOMAIN_N8N_WEBHOOK LETSENCRYPT_EMAIL; do
    if [[ -z "${!v}" ]]; then
      log_err "Variável obrigatória: $v"
      exit 1
    fi
  done

  # Senhas: gerar se vazias
  PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-}"
  [[ -z "$PORTAINER_ADMIN_PASSWORD" ]] && PORTAINER_ADMIN_PASSWORD=$(gen_password)
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
  [[ -z "$POSTGRES_PASSWORD" ]] && POSTGRES_PASSWORD=$(gen_password)
  N8N_DB_USER="${N8N_DB_USER:-n8n}"
  N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
  N8N_DB_PASSWORD="${N8N_DB_PASSWORD:-}"
  [[ -z "$N8N_DB_PASSWORD" ]] && N8N_DB_PASSWORD=$(gen_password)
  REDIS_PASSWORD="${REDIS_PASSWORD:-}"
  [[ -z "$REDIS_PASSWORD" ]] && REDIS_PASSWORD=$(gen_password)
  N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"
  [[ -z "$N8N_ENCRYPTION_KEY" ]] && N8N_ENCRYPTION_KEY=$(gen_password)
  TZ="${TZ:-America/Sao_Paulo}"
}

# -----------------------------------------------------------------------------
# Checagens iniciais
# -----------------------------------------------------------------------------
check_root() {
  if [[ "$(id -u)" -ne 0 ]] && ! command -v sudo &>/dev/null; then
    log_err "Execute como root ou com sudo."
    exit 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    SUDO=sudo
  else
    SUDO=
  fi
  if ! command -v jq &>/dev/null; then
    log_info "Instalando jq (necessário para a API do Portainer)..."
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq jq
  fi
  if ! command -v curl &>/dev/null; then
    log_info "Instalando curl..."
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq curl
  fi
}

install_docker() {
  if command -v docker &>/dev/null; then
    log_info "Docker já instalado: $(docker --version)"
    return 0
  fi
  log_info "Instalando Docker..."
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO usermod -aG docker "${SUDO_USER:-root}" 2>/dev/null || true
  log_info "Docker instalado."
}

init_swarm() {
  if $SUDO docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_info "Swarm já ativo."
    return 0
  fi
  log_info "Iniciando Docker Swarm..."
  $SUDO docker swarm init
  log_info "Swarm ativo."
}

create_network_and_volumes() {
  log_info "Criando rede e volumes..."
  $SUDO docker network inspect main &>/dev/null || $SUDO docker network create -d overlay main
  for vol in postgres_data redis_data portainer_data vol_certificates vol_traefik_logs; do
    $SUDO docker volume inspect "$vol" &>/dev/null || $SUDO docker volume create "$vol"
  done
}

create_configs_and_secret() {
  log_info "Criando configs e secret..."

  # Traefik middlewares
  if ! $SUDO docker config inspect traefik_global_middlewares &>/dev/null; then
    $SUDO docker config create traefik_global_middlewares "${STACKS_DIR}/traefik-dynamic.yml"
  fi

  # Init Postgres: criar usuário e DB n8n (senha escapada para SQL)
  local n8n_pass_sql="${N8N_DB_PASSWORD//\'/\'\'\'}"
  local init_script
  init_script="#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username \"\$POSTGRES_USER\" <<EOSQL
CREATE USER ${N8N_DB_USER} WITH PASSWORD '${n8n_pass_sql}';
CREATE DATABASE ${N8N_DB_NAME} OWNER ${N8N_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB_NAME} TO ${N8N_DB_USER};
\\\\c ${N8N_DB_NAME}
GRANT ALL ON SCHEMA public TO ${N8N_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${N8N_DB_USER};
EOSQL
"
  local tmp_init="/tmp/postgres_init_n8n_$$.sh"
  echo "$init_script" > "$tmp_init"
  chmod 755 "$tmp_init"
  $SUDO docker config inspect postgres_init_n8n &>/dev/null && $SUDO docker config rm postgres_init_n8n 2>/dev/null || true
  $SUDO docker config create postgres_init_n8n "$tmp_init"
  rm -f "$tmp_init"

  # Secret senha admin Portainer
  echo -n "$PORTAINER_ADMIN_PASSWORD" | $SUDO docker secret create portainer_admin_password - 2>/dev/null || \
    ($SUDO docker secret rm portainer_admin_password 2>/dev/null; echo -n "$PORTAINER_ADMIN_PASSWORD" | $SUDO docker secret create portainer_admin_password -)
  log_info "Configs e secret criados."
}

# Deploy Portainer via docker stack (para ter API disponível)
deploy_portainer_stack() {
  log_info "Fazendo deploy da stack Portainer (docker stack)..."
  export DOMAIN_PORTAINER
  $SUDO docker stack deploy -c "${STACKS_DIR}/portainer.yaml" portainer
  log_info "Aguardando Portainer ficar pronto..."
  local i=0
  while ! curl -sf -o /dev/null "http://127.0.0.1:9000/api/system/status" 2>/dev/null; do
    sleep 5
    i=$((i+1))
    [[ $i -gt 24 ]] && { log_err "Portainer não respondeu a tempo."; exit 1; }
  done
  log_info "Portainer pronto."
}

# Autentica e obtém JWT
portainer_auth() {
  local res
  res=$(curl -sf -X POST "http://127.0.0.1:9000/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"Username\":\"${PORTAINER_ADMIN_USER}\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}")
  PORTAINER_JWT=$(echo "$res" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p')
  if [[ -z "$PORTAINER_JWT" ]]; then
    log_err "Falha ao obter token Portainer. Verifique usuário/senha."
    exit 1
  fi
  log_info "Autenticado na API Portainer."
}

# Retorna endpoint ID (normalmente 1). O agent pode demorar alguns segundos para registrar.
# Portainer CE usa GET /api/endpoints (não /api/environments).
get_endpoint_id() {
  local res i=0 max=24
  local url="http://127.0.0.1:9000/api/endpoints"
  PORTAINER_ENDPOINT_ID=""
  log_info "Aguardando endpoint do Portainer (agent) ficar disponível..."
  while true; do
    res=$(curl -sf "$url" -H "Authorization: Bearer ${PORTAINER_JWT}" 2>/dev/null) || res=""
    if [[ -n "$res" ]]; then
      if command -v jq &>/dev/null; then
        PORTAINER_ENDPOINT_ID=$(echo "$res" | jq -r '(if type == "array" then .[0] else .endpoints[0] end | .Id // .id)? // empty' 2>/dev/null)
      fi
      [[ -z "$PORTAINER_ENDPOINT_ID" ]] && PORTAINER_ENDPOINT_ID=$(echo "$res" | sed -n 's/.*"Id":\([0-9]*\).*/\1/p' | head -1)
      [[ -z "$PORTAINER_ENDPOINT_ID" ]] && PORTAINER_ENDPOINT_ID=$(echo "$res" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)
    fi
    if [[ -n "$PORTAINER_ENDPOINT_ID" ]]; then
      log_info "Endpoint ID: $PORTAINER_ENDPOINT_ID"
      return 0
    fi
    i=$((i+1))
    if [[ $i -ge $max ]]; then
      log_err "Nenhum endpoint encontrado (agent pode não ter registrado a tempo)."
      res=$(curl -s -w "\n%{http_code}" "$url" -H "Authorization: Bearer ${PORTAINER_JWT}" 2>/dev/null)
      log_err "GET $url HTTP: $(echo "$res" | tail -n1). Body: $(echo "$res" | sed '$d' | tail -c 300)"
      exit 1
    fi
    sleep 5
  done
}

# Retorna Swarm ID
get_swarm_id() {
  local res
  res=$(curl -sf "http://127.0.0.1:9000/api/endpoints/${PORTAINER_ENDPOINT_ID}/docker/swarm" \
    -H "Authorization: Bearer ${PORTAINER_JWT}")
  SWARM_ID=$(echo "$res" | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p')
  if [[ -z "$SWARM_ID" ]]; then
    log_err "Swarm ID não encontrado."
    exit 1
  fi
  log_info "Swarm ID: $SWARM_ID"
}

# Deploy stack via API (nome, arquivo yaml, env array "VAR1=val1 VAR2=val2")
deploy_stack_via_api() {
  local name="$1"
  local yaml_file="$2"
  shift 2
  local env_args=("$@")
  # Conteúdo do stack como string JSON (escape correto)
  local stack_json
  stack_json=$(jq -Rs . < "$yaml_file")
  local env_json="[]"
  if [[ ${#env_args[@]} -gt 0 ]]; then
    env_json="["
    local first=1
    for pair in "${env_args[@]}"; do
      local k="${pair%%=*}"
      local v="${pair#*=}"
      v="${v//\\/\\\\}"
      v="${v//\"/\\\"}"
      [[ $first -eq 0 ]] && env_json+=","
      env_json+="{\"name\":\"$k\",\"value\":\"$v\"}"
      first=0
    done
    env_json+="]"
  fi
  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg swarmId "$SWARM_ID" \
    --argjson stack "$stack_json" \
    --argjson env "$env_json" \
    '{Name: $name, SwarmID: $swarmId, StackFileContent: $stack, Env: $env}')
  local res
  res=$(curl -sf -X POST "http://127.0.0.1:9000/api/stacks/create/swarm?endpointId=${PORTAINER_ENDPOINT_ID}" \
    -H "Authorization: Bearer ${PORTAINER_JWT}" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null) || true
  if echo "$res" | grep -q '"Id"'; then
    log_info "Stack '$name' criada via API."
  else
    log_warn "Resposta da API (stack $name): $res"
    log_warn "Se a stack já existir, pode ser atualização. Verifique no Portainer."
  fi
}

deploy_stacks_via_api() {
  log_info "Deploy das stacks Traefik, Postgres, Redis e n8n via API Portainer..."

  deploy_stack_via_api "traefik" "${STACKS_DIR}/traefik.yaml" \
    "LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL" \
    "DOMAIN_TRAEFIK_DASHBOARD=$DOMAIN_TRAEFIK_DASHBOARD"

  deploy_stack_via_api "postgres" "${STACKS_DIR}/postgres.yaml" \
    "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    "N8N_DB_USER=$N8N_DB_USER" \
    "N8N_DB_NAME=$N8N_DB_NAME" \
    "N8N_DB_PASSWORD=$N8N_DB_PASSWORD" \
    "TZ=$TZ"

  deploy_stack_via_api "redis" "${STACKS_DIR}/redis.yaml" \
    "REDIS_PASSWORD=$REDIS_PASSWORD"

  # n8n: host do postgres/redis no Swarm = nome do serviço (stack_servicename)
  local n8n_editor_url="https://${DOMAIN_N8N_EDITOR}"
  local n8n_webhook_url="https://${DOMAIN_N8N_WEBHOOK}"
  deploy_stack_via_api "n8n" "${STACKS_DIR}/n8n.yaml" \
    "DB_POSTGRESDB_DATABASE=$N8N_DB_NAME" \
    "DB_POSTGRESDB_HOST=postgres_postgres" \
    "DB_POSTGRESDB_PORT=5432" \
    "DB_POSTGRESDB_USER=$N8N_DB_USER" \
    "DB_POSTGRESDB_PASSWORD=$N8N_DB_PASSWORD" \
    "N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY" \
    "N8N_HOST=$DOMAIN_N8N_EDITOR" \
    "N8N_EDITOR_BASE_URL=$n8n_editor_url" \
    "WEBHOOK_URL=$n8n_webhook_url" \
    "EDITOR_DOMAIN=$DOMAIN_N8N_EDITOR" \
    "WEBHOOK_DOMAIN=$DOMAIN_N8N_WEBHOOK" \
    "QUEUE_BULL_REDIS_HOST=redis_redis" \
    "QUEUE_BULL_REDIS_PORT=6379" \
    "QUEUE_BULL_REDIS_PASSWORD=$REDIS_PASSWORD" \
    "TZ=$TZ" \
    "GENERIC_TIMEZONE=$TZ"
}

save_credentials() {
  local out="${SCRIPT_DIR}/.credentials.generated"
  cat > "$out" << EOF
# Gerado em $(date). NÃO commitar no git.

# Portainer
URL: https://${DOMAIN_PORTAINER}
User: ${PORTAINER_ADMIN_USER}
Password: ${PORTAINER_ADMIN_PASSWORD}

# Postgres (superuser - use apenas para admin)
Host: postgres_postgres (dentro do Swarm)
User: postgres
Password: ${POSTGRES_PASSWORD}

# Postgres - usuário n8n (uso pela aplicação)
Database: ${N8N_DB_NAME}
User: ${N8N_DB_USER}
Password: ${N8N_DB_PASSWORD}

# Redis
Password: ${REDIS_PASSWORD}

# n8n
Editor: https://${DOMAIN_N8N_EDITOR}
Webhook: https://${DOMAIN_N8N_WEBHOOK}
Encryption key: ${N8N_ENCRYPTION_KEY}
EOF
  chmod 600 "$out"
  log_info "Credenciais salvas em: $out"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log_info "=== VPS Setup n8n ==="
  check_root
  load_env
  gather_inputs

  install_docker
  init_swarm
  create_network_and_volumes
  create_configs_and_secret
  deploy_portainer_stack

  portainer_auth
  get_endpoint_id
  get_swarm_id
  deploy_stacks_via_api
  save_credentials

  log_info "=== Concluído ==="
  log_info "Portainer: https://${DOMAIN_PORTAINER}"
  log_info "n8n Editor: https://${DOMAIN_N8N_EDITOR}"
  log_info "Traefik Dashboard: https://${DOMAIN_TRAEFIK_DASHBOARD}"
  log_info "Credenciais em: ${SCRIPT_DIR}/.credentials.generated"
}

main "$@"
