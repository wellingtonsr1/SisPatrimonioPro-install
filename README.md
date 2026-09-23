# SisPatrimonioPro-install

Documentação e análise aprofundada dos instaladores de produção do SisPatrimônio Pro (Feature 027): a instalação **nativa** (`install.sh` — systemd + MariaDB do host) e a variante **Docker** (`install-docker.sh` — Docker Compose com os arquivos versionados no repositório).                                                                            
  ──────                                                                                                                                                                                   
  ### Visão Geral e Propósito                                                                                                                                                              
                                                                                                                                                                                           
  O script é um instalador e provisionador de infraestrutura em Bash para ambientes de produção Linux baseados em Debian/Ubuntu com systemd. Ele atua cobrindo desde a validação de pré-   
  requisitos até a inicialização e monitoramento da aplicação com verificação de saúde via HTTP.                                                                                           
                                                                                                                                                                                           
  Ele foi construído sobre três pilares centrais:                                                                                                                                          
                                                                                                                                                                                           
  1. Idempotência total: Pode ser reexecutado múltiplas vezes sem corromper dados, quebrar o estado anterior ou duplicar recursos.                                                         
  2. Defensividade e Robustez: Uso estrito de flags do bash (set -Eeuo pipefail), validação prévia de todas as entradas antes de qualquer mutação, traps de erro detalhados e canal único  
  de I/O sem buffering.  3. Segurança por Padrão: Credenciais não vazam em logs, ps aux ou /proc/<pid>/cmdline; privilégios mínimos no banco de dados e no sistema operacional.
  ──────
  ## 🐳 Instalação via Docker (install-docker.sh)

  Variante de produção que executa a aplicação e o banco em containers, usando como **fonte da verdade** o `docker-compose.yml` e o `Dockerfile` **versionados no próprio repositório** (o instalador nunca os altera).

  | | Instalação nativa (`install.sh`) | Variante Docker (`install-docker.sh`) |
  |---|---|---|
  | Processo da app | venv + unidade systemd | container `sispat-app` (build local do Dockerfile do repo) |
  | Banco de dados | MariaDB instalado via apt no host | container `sispat-db` (imagem `mariadb:11`) |
  | Persistência | `/var/lib/mysql` + `data/` no host | volumes `db-data` (banco) e `app-data` (backups/logs) |
  | Iniciar/parar | `systemctl start/stop sispatrimoniopro` | `docker compose up -d / stop` |
  | Logs da app | `journalctl -u sispatrimoniopro -f` | `docker compose logs -f app` |
  | Boot automático | `systemctl enable` | `restart: unless-stopped` + healthcheck |

  #### Arquitetura da variante Docker

  ```
  ┌─────────────────────────────┐         ┌──────────────────────────────┐
  │ container sispat-app        │         │ container sispat-db          │
  │ imagem: build do Dockerfile │ ──────► │ imagem: mariadb:11           │
  │ host ${APP_PORT} → 8000     │  rede   │ volume: <projeto>_db-data    │
  │ volume: <projeto>_app-data  │  docker │ porta interna 3306           │
  │ (backups/logs da app)       │         │                              │
  └─────────────────────────────┘         └──────────────────────────────┘
  ```

  Banco e usuário são **fixados pelo compose do repositório**: `sispatrimonio_pro` / `sispatrimonio`. A porta do host é configurável (`${APP_PORT:-8000}`); dentro do container a app escuta fixa em `8000`.

  #### Uso

  ```bash
  # Interativo (pede a senha do banco sem eco; vazio nas duas entradas = gerar)
  sudo bash install-docker.sh

  # Não interativo (senha gerada automaticamente, vai direto ao .env)
  sudo bash install-docker.sh --non-interactive --generate-db-password

  # Porta do host customizada
  sudo bash install-docker.sh --app-port 8080
  ```

  O que o instalador faz (10 etapas): instala Docker Engine + Compose v2 (via get.docker.com), clona o repositório, analisa o compose do repo (nomes reais de containers, banco e volumes), gera o `.env` (0600) com `DB_PASSWORD`, `DB_ROOT_PASSWORD` (sempre gerado — o default `changeme-root` do compose **nunca** entra em produção), `SECRET_KEY` (token de 32 bytes), `APP_PORT` e `TZ` (detectado do servidor), constrói a imagem, sobe o MariaDB (healthcheck + criação do banco pelo entrypoint), executa `init_db()` em container efêmero, inicia a app e valida `/health` (até 180s), roda a bateria pós-instalação e a auditoria de segurança.

  #### Opções da CLI

  ```text
  --non-interactive           Nenhum prompt; exige --db-password ou --generate-db-password
  --install-dir <caminho>     Diretório de instalação (default: /opt/SisPatrimonioPro)
  --repo <url> / --branch     Repositório e branch (defaults: repo oficial / main)
  --db-password <senha>       Senha do banco (não interativo; letras, números e _ . + -)
  --generate-db-password      Gera senha forte automaticamente (vai direto ao .env)
  --db-name / --db-user       SOMENTE conferência: divergir do compose do repo aborta
  --app-port <porta>          Porta da aplicação no HOST (default: 8000)
  --reset-db                  APAGA o volume do banco (dupla confirmação; interativo apenas)
  --help                      Ajuda completa
  ```

  > As opções `--app-host`, `--service-name` e `--service-user` existem por compatibilidade com o instalador nativo, mas não têm efeito nesta variante (emitem aviso).

  #### Idempotência e segurança (mesmos princípios do install.sh)

  - **Reexecução segura**: clone, imagem, `.env` e volume do banco são reutilizados quando válidos; o `.env` **nunca é sobrescrito** (backup `.env.bak-<timestamp>` + mescla apenas de chaves ausentes).
  - **Divergência de senha**: se a senha do `.env` divergir do banco já existente, o instalador tenta realinhá-la via `ALTER USER` usando `DB_ROOT_PASSWORD` (nunca digitada em argv).
  - **Segredos**: `MYSQL_PWD` vai por `docker compose exec -e` (nunca argv/log); `.env` nasce 0600 (`umask 077`); auditoria final verifica se credenciais vazaram para o log.
  - **`--reset-db` é cirúrgico**: remove **somente** o volume `db-data` (não usa `down -v`, que apagaria também o `app-data` com backups/logs); exige dupla confirmação digitando o nome do banco e é proibido com `--non-interactive`.
  - **Requisito de rede**: banco/usuário/`DATABASE_URL` usam a rede interna do Compose (`db:3306`); só a porta da app é publicada no host.

  #### Pós-instalação (resumo exibido pelo instalador)

  ```bash
  cd /opt/SisPatrimonioPro
  docker compose ps                    # estado dos containers
  docker compose logs -f app           # logs da aplicação
  docker compose restart app           # reiniciar a aplicação

  # Primeiro administrador (CLI do projeto, dentro do container)
  docker compose exec app python3 -m app.cli \
    create-user --username admin --name 'Administrador' --admin

  # Backup lógico do banco (senha lida do .env, nunca digitada em argv)
  docker compose exec -T -e MYSQL_PWD="$(grep '^DB_ROOT_PASSWORD=' .env | cut -d= -f2-)" \
    db mariadb-dump -uroot sispatrimonio_pro > backup-$(date +%F).sql
  ```

  Acesso: `http://<ip-do-servidor>:8000` · API: `/docs` · Health: `/health`. As credenciais ficam **apenas** no `.env` (0600) — nunca no resumo nem no log.

  ──────
  ## 🖥️ Instalação Nativa (install.sh) — Análise Aprofundada

  As seções seguintes analisam o instalador nativo (systemd + MariaDB do host).

  ### Arquitetura do Fluxo de Execução (15 Etapas)                                                                                                                                         
                                                                                                                                                                                           
    [Validação Prévia & Gates]                                                                                                                                                             
      ├── Parser CLI (--non-interactive, --recreate-db, etc.)                                                                                                                              
      ├── Verificação de privilégios (root/sudo)                                                                                                                                           
      ├── Checagem de SO (Debian/Ubuntu) e systemd ativo                                                                                                                                   
      ├── Conectividade Git e detecção de ferramentas do host                                                                                                                              
      └── Coleta e geração de segredos (interativo ou secrets.token_urlsafe)                                                                                                               
             │                                                                                                                                                                             
    [Provisionamento & Configuração]                                                                                                                                                       
      ├── Instalação seletiva de pacotes apt (Python, Git, MariaDB se ausente)                                                                                                             
      ├── Clone Git do repositório / Verificação de integridade                                                                                                                            
      ├── Criação do ambiente virtual (.venv) e instalação de requirements                                                                                                                 
      ├── Criação do banco, usuário e privilégios mínimos (sem privilégios globais)                                                                                                        
      ├── Geração do .env com permissões 0600 (backup se já existir)                                                                                                                       
      ├── Criação de usuário de sistema dedicado (sem login interativo)                                                                                                                    
      └── Criação/atualização da unidade systemd (sispatrimoniopro.service)                                                                                                                
             │                                                                                                                                                                             
    [Boot, Validação & Conclusão]                                                                                                                                                          
      ├── Parada defensiva do serviço anterior (prevenção de concorrência com init_db)                                                                                                     
      ├── Execução explícita do init_db() da aplicação                                                                                                                                     
      ├── Start do serviço e polling do endpoint /health (até 120s)                                                                                                                        
      ├── Bateria pós-instalação (7 verificações de sanidade)                                                                                                                              
      └── Auditoria de segurança (grep da senha no log, perms do .env e SHOW GRANTS)                                                                                                       
  ──────                                                                                                                                                                                   
  ### Principais Pontos Fortes e Destaques de Engenharia                                                                                                                                   
                                                                                                                                                                                           
  #### 1. Segurança de Credenciais Rigorosa                                                                                                                                                
                                                                                                                                                                                           
  • Proteção contra vazamento em processos (argv): A senha do banco nunca é passada como parâmetro na linha de comando de utilitários como mysql ou mariadb (onde ficaria visível via ps   
  aux ou /proc). O script utiliza MYSQL_PWD exportado no ambiente ou socket local UNIX (unix_auth).                                                                                        
  • Coleta sem eco com blindagem contra xtrace: O uso de read -rs oculta a digitação. O script tem o cuidado de desativar ou evitar set -x na captura, impedindo que subshells imprimam o  
  segredo no stderr/log.                                                                                                                                                                   
  • Percent-Encoding correto na URL do banco: Uso de urllib.parse.quote(..., safe='') em vez de quote_plus. Isso é um detalhe crítico: quote_plus converte espaço em +, mas o SQLAlchemy   
  não decodifica + como espaço em senhas, resultando em erros fatais de Access denied.                                                                                                     
  • Rejeição preventiva de Backslash (\): O script proíbe senhas com barra invertida antes de realizar mutações, pois literais SQL no MySQL/MariaDB interpretam escapes (\n, \t) sem       
  NO_BACKSLASH_ESCAPES, o que corromperia a senha gravada no CREATE/ALTER USER.                                                                                                            
  • Permissões mínimas: Criação do .env com umask 077 (permissão estrita 0600) e usuário de sistema sem permissão de login (/usr/sbin/nologin). No banco, os privilégios são concedidos    
  estritamente em $DB_NAME.*.                                                                                                                                                              
  • Auto-auditoria final (security_self_check): O próprio script faz uma varredura por força bruta (grep -Fq "DB_PASSWORD""INSTALL_LOG") no arquivo de log gerado para garantir que a      
  credencial não escapou em nenhum ponto.                                                                                                                                                  
                                                                                                                                                                                           
  #### 2. Engenharia de I/O e Resolução de Corrida de Buffers                                                                                                                              
                                                                                                                                                                                           
  • Canal Único em stderr: O direcionamento de mensagens, prompts e logs para o canal do stderr com posterior tee resolve um problema recorrente em ambientes virtuais/consoles lentos     
  (como VNC e portas seriais): se a saída padrão (stdout) passa por buffer de bloco da libc devido ao pipe do tee enquanto prompts interativos vão direto a /dev/tty ou outro descritor, os
  prompts são exibidos antes do texto explicativo. Unificar no mesmo fluxo garante a ordem sequencial estrita dos eventos.                                                                 
  • Remoção de sequências ANSI no arquivo de log: O script mantém cores para visualização humana no terminal via tput, mas sanitiza os escapes ANSI com sed antes de gravá-los no log em   
  disco (/var/log/sispatrimonio-install.log), mantendo o arquivo limpo para análise.                                                                                                       
                                                                                                                                                                                           
  #### 3. Idempotência e Tratamento de Concorrência                                                                                                                                        
                                                                                                                                                                                           
  • Prevenção de corrida na inicialização do banco (stop_service_if_running): Se o serviço do systemd estava em falha ou reiniciando (Restart=on-failure), ele tentaria executar o         
  init_db() simultaneamente com o instalador, causando o erro clássico MySQL 1050 ("Table already exists"). O script interrompe o serviço antes de rodar o init_db.                        
  • Detecção de Estado: O clone Git é reaproveitado se íntegro; o ambiente virtual é verificado por importação das bibliotecas principais (FastAPI, SQLAlchemy, PyMySQL, etc.) antes de ser
  recriado; unidades systemd e .env existentes não são cegamente sobrescritos (faz backup com timestamp .env.bak-...).                                                                     
                                                                                                                                                                                           
  #### 4. Tratamento de Erros e Diagnóstico                                                                                                                                                
                                                                                                                                                                                           
  • O trap on_error exibe a linha exata onde ocorreu a falha e o nome da etapa corrente, orientando o operador a consultar o log e reforçando que a operação pode ser repetida sem perda de
  dados.                                                                                                                                                                                   
  • Em caso de timeout no /health, o script extrai automaticamente os últimos registros do journalctl e o traceback de erro, além de parar o serviço para impedir que o systemd entre em   
  loop infinito de restart.                                                                                                                                                                
  ──────                                                                                                                                                                                   
  ### Pontos de Atenção e Oportunidades de Melhoria                                                                                                                                        
                                                                                                                                                                                           
  Apesar da alta qualidade do código, há detalhes técnicos a observar:                                                                                                                     
                                                                                                                                                                                           
  #### 1. Uso do Idioma cmd1 && cmd2 || cmd3 (SC2015 do ShellCheck)                                                                                                                        
                                                                                                                                                                                           
  Em várias partes do script (notadamente em detect_host e post_install_checks), encontra-se a construção:                                                                                 
                                                                                                                                                                                           
    python_at_least "$MIN_PYTHON_MAJOR" "$MIN_PYTHON_MINOR" && ok "..." || { err "..."; failures=$((failures+1)); }                                                                        
  
  • Risco: Em Bash, A && B || C não é equivalente a if A; then B; else C; fi. Se A for verdadeiro mas B retornar status diferente de 0 (por exemplo, se o ok falhar por erro de escrita no 
  stderr), o bloco C será acionado.
  • Recomendação: Usar a estrutura padrão if/then/else:
    if python_at_least "$MIN_PYTHON_MAJOR" "$MIN_PYTHON_MINOR"; then
        ok "Python >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}: OK"
    else
        err "Python: FALHOU"
        failures=$((failures+1))
    fi
  

  #### 2. Expressão de Regex no SHOW GRANTS em security_self_check
  
  Na linha:
  
    grants="$("$BANCO_CLIENT_CMD" -N -B -e "SHOW GRANTS FOR '$DB_USER'@'localhost';" 2>/dev/null | grep -c 'ON \`\*\`\.\*\`' || true)"
  
  • Problema: O grep busca 'ON \*`.*`'` (com crase no final desemparelhada ou formato específico). Diferentes versões do MariaDB e MySQL formatam a saída de privilégios globais de formas 
  distintas:
      • Podem emitir ON *.* TO ... (sem crases nos asteriscos) ou ON *.*.
      • Se o servidor MySQL/MariaDB retornar ON *.*, o grep não encontrará a ocorrência e assumirá erroneamente que não há privilégios globais.
  • Recomendação: Flexibilizar a regex do grep:
    grep -cE 'ON (`\*`|\*)\.(`\*`|\*)'
  

  #### 3. Validação Sintática de APP_HOST
  
  • A variável APP_PORT é validada rigorosamente (entre 1 e 65535 com regex numérica), mas APP_HOST não passa por validação no validate_inputs. Se um operador informar um host inválido   
  via --app-host, o erro só será notado quando a aplicação subir ou no momento do teste de bind.
  
  #### 4. Ambientes Air-Gapped (Sem Acesso Direto à Internet)
  
  • O instalador assume conexão direta e irrestrita com a internet (git ls-remote, git clone e pip install). Se o script for executado em um ambiente corporativo isolado (on-premises     
  fechado com proxy corporativo ou sem acesso externo direto), ele falhará na etapa de pré-requisitos (check_connectivity). Ter suporte a parâmetros como --wheel-dir ou repositórios      
  locais seria uma adição valiosa para ambientes regulados.
  ──────
  ### Resumo do Veredito
  
  O script demonstra maturidade de engenharia de software e práticas de SRE/DevOps muito acima da média. Ele evita os erros mais comuns de scripts bash (como comandos em argv vazando     
  senhas, assincronia de buffers, poluição de logs e falta de idempotência).  As correções pontuais sugeridas acima elevam ainda mais sua resiliência e portabilidade entre diferentes versões do MariaDB/MySQL.

  > **Nota:** a variante Docker (`install-docker.sh`) herda deliberadamente estes mesmos princípios — idempotência, sigilo de credenciais em argv/log, `.env` 0600, confirmação dupla para ações destrutivas e bateria pós-instalação — trocando systemd/venv/MariaDB nativo pelos containers definidos no `docker-compose.yml` do repositório. Veja a seção **Instalação via Docker** no início deste documento.

