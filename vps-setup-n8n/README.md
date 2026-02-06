# VPS Setup n8n

Script para preparar uma VPS do zero com **Docker Swarm**, **Portainer**, **Traefik**, **PostgreSQL**, **Redis** e **n8n**. As stacks de Postgres, Redis, Traefik e n8n são implantadas via API do Portainer.

## Pré-requisitos

- Servidor Linux (Debian/Ubuntu recomendado) com acesso root ou sudo
- Domínios apontando para o IP da VPS (para HTTPS com Let's Encrypt)
- Portas 80 e 443 liberadas no firewall

## Uso rápido

1. **Copie a pasta para a VPS** (ou clone o repositório).

2. **Opcional – arquivo de ambiente**

   ```bash
   cp .env.example .env
   # Edite .env com seus domínios e usuário
   ```

   Se não usar `.env`, o script perguntará interativamente.

3. **Execute o setup** (como root ou com sudo):

   ```bash
   sudo bash setup.sh
   ```

4. **Aguarde** a conclusão. As credenciais serão salvas em `.credentials.generated`.

## Variáveis

| Variável | Obrigatória | Descrição |
|----------|-------------|-----------|
| `PORTAINER_ADMIN_USER` | Sim | Usuário admin do Portainer (ex.: `admin`) |
| `DOMAIN_PORTAINER` | Sim | Domínio do Portainer (ex.: `portainer.seudominio.com`) |
| `DOMAIN_TRAEFIK_DASHBOARD` | Sim | Domínio do dashboard do Traefik |
| `DOMAIN_N8N_EDITOR` | Sim | Domínio do editor n8n |
| `DOMAIN_N8N_WEBHOOK` | Sim | Domínio dos webhooks n8n |
| `LETSENCRYPT_EMAIL` | Sim | E-mail para certificados Let's Encrypt |

Senhas (Portainer, Postgres, usuário n8n, Redis, chave de criptografia do n8n) são **geradas automaticamente** se não forem definidas.

## O que o script faz

1. Instala Docker (se não existir) e inicia o **Docker Swarm**
2. Cria a rede overlay **main**, volumes e configs necessários
3. Faz deploy da stack **Portainer** com `docker stack`
4. Usa a API do Portainer para criar as stacks **Traefik**, **Postgres**, **Redis** e **n8n**
5. No Postgres, cria o usuário e o banco dedicados ao n8n (boas práticas de segurança)
6. Salva credenciais em `.credentials.generated` (não commitar)

## Desinstalação

Use o script de uninstall para reverter o que foi instalado:

```bash
sudo bash uninstall.sh
```

O script oferece duas opções:

- **Apenas stacks** – Remove só as stacks (portainer, traefik, postgres, redis, n8n). Docker e Swarm permanecem; volumes, configs, rede e secrets criados por este setup também são removidos para deixar o ambiente limpo.
- **Reverter tudo** – Remove as stacks, depois configs, secrets, volumes, rede, sai do Swarm e, opcionalmente, desinstala o Docker.

Detalhes em [Uninstall](#uninstall) abaixo.

## Estrutura da pasta

```
vps-setup-n8n/
├── setup.sh           # Instalação
├── uninstall.sh       # Desinstalação (só stacks ou tudo)
├── .env.example       # Exemplo de variáveis
├── README.md          # Este arquivo
└── stacks/
    ├── portainer.yaml
    ├── traefik.yaml
    ├── traefik-dynamic.yml
    ├── postgres.yaml
    ├── redis.yaml
    └── n8n.yaml
```

## Uninstall

Execute:

```bash
sudo bash uninstall.sh
```

1. **Remover apenas as stacks**  
   - Remove as stacks: n8n, redis, postgres, traefik, portainer  
   - Remove configs, secrets, volumes e a rede **main** criados por este setup  
   - Docker e Swarm continuam instalados; você pode rodar o `setup.sh` de novo depois

2. **Reverter todo o processo**  
   - Faz o mesmo que acima  
   - Sai do Swarm (`docker swarm leave --force`)  
   - Pergunta se deseja desinstalar o Docker (pacotes e dados)

Use a opção 1 para “apagar só o n8n e amigos” e manter o Docker. Use a opção 2 para deixar o servidor como antes do setup (e, se quiser, sem Docker).

## Segurança

- Não commitar `.env` nem `.credentials.generated` (já listados no `.gitignore`)
- Os domínios devem apontar para a VPS antes de rodar o setup (Let's Encrypt)
- Postgres: usuário `n8n` com permissões apenas no banco do n8n; superusuário só para administração
