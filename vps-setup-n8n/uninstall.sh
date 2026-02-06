#!/usr/bin/env bash
# =============================================================================
# VPS Setup n8n - Desinstalação
# Opção 1: Remover apenas as stacks (Docker e Swarm permanecem)
# Opção 2: Reverter tudo (stacks + recursos + Swarm + opcionalmente Docker)
# =============================================================================
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m'
log_info()  { echo -e "${green}[INFO]${nc} $*"; }
log_warn()  { echo -e "${yellow}[WARN]${nc} $*"; }
log_err()   { echo -e "${red}[ERR]${nc} $*"; }

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
}

# Stacks criadas por este setup (ordem: dependentes primeiro, portainer por último)
readonly STACKS=(n8n redis postgres traefik portainer)

# Recursos criados por este setup
readonly CONFIGS=(traefik_global_middlewares postgres_init_n8n)
readonly SECRETS=(portainer_admin_password)
readonly VOLUMES=(postgres_data redis_data portainer_data vol_certificates vol_traefik_logs)
readonly NETWORK=main

remove_stacks() {
  log_info "Removendo stacks..."
  for stack in "${STACKS[@]}"; do
    if $SUDO docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$stack"; then
      $SUDO docker stack rm "$stack"
      log_info "  Stack '$stack' removida."
    else
      log_info "  Stack '$stack' não encontrada, ignorando."
    fi
  done
  log_info "Aguardando serviços encerrarem (até ~60s)..."
  sleep 30
  local i=0
  while [[ $i -lt 6 ]]; do
    local tasks
    tasks=$($SUDO docker service ls -q 2>/dev/null | wc -l)
    [[ "${tasks:-0}" -eq 0 ]] && break
    sleep 5
    i=$((i+1))
  done
  sleep 10
}

remove_configs_secrets_volumes_network() {
  log_info "Removendo configs, secrets, volumes e rede criados pelo setup..."

  for c in "${CONFIGS[@]}"; do
    if $SUDO docker config inspect "$c" &>/dev/null; then
      $SUDO docker config rm "$c" 2>/dev/null && log_info "  Config '$c' removido." || log_warn "  Não foi possível remover config '$c' (pode estar em uso)."
    fi
  done

  for s in "${SECRETS[@]}"; do
    if $SUDO docker secret inspect "$s" &>/dev/null; then
      $SUDO docker secret rm "$s" 2>/dev/null && log_info "  Secret '$s' removido." || log_warn "  Não foi possível remover secret '$s' (pode estar em uso)."
    fi
  done

  for v in "${VOLUMES[@]}"; do
    if $SUDO docker volume inspect "$v" &>/dev/null; then
      $SUDO docker volume rm "$v" 2>/dev/null && log_info "  Volume '$v' removido." || log_warn "  Não foi possível remover volume '$v' (pode estar em uso)."
    fi
  done

  if $SUDO docker network inspect "$NETWORK" &>/dev/null; then
    $SUDO docker network rm "$NETWORK" 2>/dev/null && log_info "  Rede '$NETWORK' removida." || log_warn "  Não foi possível remover rede '$NETWORK' (pode estar em uso)."
  fi
}

leave_swarm() {
  if $SUDO docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_info "Saindo do Swarm..."
    $SUDO docker swarm leave --force
    log_info "Swarm encerrado."
  else
    log_info "Swarm não está ativo."
  fi
}

uninstall_docker() {
  log_warn "Isso vai remover o Docker e seus dados (imagens, containers, etc.)."
  read -r -p "Desinstalar o Docker? (y/N): " resp
  if [[ "${resp,,}" == "y" || "${resp,,}" == "yes" ]]; then
    log_info "Removendo pacotes Docker..."
    $SUDO apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    $SUDO apt-get purge -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    log_info "Limpando dados do Docker (opcional)..."
    $SUDO rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true
    log_info "Docker desinstalado."
  else
    log_info "Docker mantido."
  fi
}

main() {
  log_info "=== VPS Setup n8n - Desinstalação ==="
  check_root

  if ! command -v docker &>/dev/null; then
    log_warn "Docker não encontrado. Nada a desinstalar deste setup."
    exit 0
  fi

  echo ""
  echo "Escolha o que desfazer:"
  echo "  1) Apenas stacks – remove as stacks (n8n, redis, postgres, traefik, portainer)"
  echo "     e os recursos criados pelo setup (configs, secrets, volumes, rede)."
  echo "     Docker e Swarm permanecem; você pode rodar setup.sh de novo depois."
  echo ""
  echo "  2) Reverter tudo – faz o acima, depois sai do Swarm e pode desinstalar o Docker."
  echo ""
  read -r -p "Opção (1 ou 2) [1]: " opt
  opt="${opt:-1}"

  if [[ "$opt" == "2" ]]; then
    remove_stacks
    remove_configs_secrets_volumes_network
    leave_swarm
    uninstall_docker
  else
    remove_stacks
    remove_configs_secrets_volumes_network
    log_info "Docker e Swarm mantidos."
  fi

  log_info "=== Desinstalação concluída ==="
}

main "$@"
