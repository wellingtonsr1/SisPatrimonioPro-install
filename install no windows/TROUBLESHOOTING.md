# 🛠️ Guia rápido de Troubleshooting — Instalação Windows (SisPatrimônio Pro)

Sintoma → diagnóstico → solução para os scripts em `install no windows/` (nativa e Docker).
Os scripts são **idempotentes**: na imensa maioria dos casos, corrija a causa e **reexecute o instalador** — ele reutiliza tudo o que já está correto (clone, venv, `.env`, banco, containers) e não apaga nenhum dado.

> **Antes de começar**: PowerShell **como Administrador**; log do instalador em
> `%ProgramData%\sispatrimonio-install.log` (nativa) ou `%ProgramData%\sispatrimonio-install-docker.log` (Docker).
> Exit codes: `0` sucesso · `2` uso inválido (opção/parâmetro) · `1` falha de execução.
> Nunca cole o conteúdo do `.env` (contém credenciais) em chamados, prints ou fóruns.

---

## Índice de sintomas

| Sintoma | Vá para |
|---|---|
| "O arquivo ... não pode ser carregado porque a execução de scripts foi desabilitada" | [T1](#t1-execução-de-scripts-bloqueada) |
| "Este instalador requer execução como Administrador" | [T2](#t2-sem-privilegio-de-administrador) |
| `winget` não existe / pacote não instala | [T3](#t3-winget-indisponivel-ou-falhou) |
| "Python foi instalado mas nao esta no PATH da sessao" | [T4](#t4-python-instalado-mas-fora-do-path-da-sessao) |
| "Servico de banco ... nao ficou ativo" | [T5](#t5-servico-do-mariadb-nao-sobe) |
| "Nao foi possivel autenticar como root do banco" | [T6](#t6-credencial-de-root-do-banco-rejeitada) |
| "Porta 8000 ja esta em uso" / app não acessível | [T7](#t7-porta-8000-em-uso-ou-bloqueada) |
| "/health" timeout na instalação nativa | [T8](#t8-timeout-no-health-nativa) |
| Erro no `init_db()` / Access denied / "Table already exists" (1050) | [T9](#t9-init_db-falha-access-denied-ou-1050) |
| Acesso via rede não funciona (só funciona no próprio servidor) | [T10](#t10-acesso-via-rede-bloqueado-firewall) |
| "Daemon do Docker indisponivel" | [T11](#t11-docker-daemon-indisponivel) |
| Docker: "diverge do banco fixado pelo compose" | [T12](#t12-dbname--dbuser-diverge-do-compose) |
| Docker: container do banco `unhealthy` | [T13](#t13-container-do-banco-unhealthy) |
| Docker: `-ResetDb` diz "Não foi possivel remover o volume (em uso?)" | [T14](#t14-volume-do-banco-em-uso) |
| Tarefa agendada não inicia no boot / app parada depois de reiniciar o servidor | [T15](#t15-tarefa-agendada-nao-sobe-no-boot) |
| Desinstalação: volume/diretório PRESERVADO | [T16](#t16-desinstalacao-preservou-itens) |
| Ambiente corporativo com proxy / sem internet | [T17](#t17-proxy-ou-rede-restrita) |

---

## Comum a todas as variantes

### T1. Execução de scripts bloqueada

**Sintoma:** `... cannot be loaded because running scripts is disabled on this system`.

**Solução:** use o padrão documentado no README (não altera a política global da máquina):

```powershell
powershell -ExecutionPolicy Bypass -File "install no windows\nativa\install.ps1"
```

### T2. Sem privilégio de Administrador

**Sintoma:** `Este instalador requer execucao como Administrador (abrir PowerShell elevado).`

**Solução:** menu Iniciar → digite `powershell` → botão direito → **Executar como Administrador**. Verifique com:

```powershell
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)  # True esperado
```

### T3. winget indisponível ou falhou

**Sintoma:** `winget nao instalado` na prática (Windows Server costuma vir sem o App Installer), ou o instalador para com "Instale ... manualmente e reexecute".

**Solução:** instale manualmente o componente que faltou e **reexecute o instalador** (ele detecta o que já existe e pula a etapa):

- Python ≥ 3.10: https://www.python.org/downloads/ (marque **Add python.exe to PATH**)
- Git: https://git-scm.com/download/win
- MariaDB 11.x: https://mariadb.org/download/ (instalador MSI cria o serviço automaticamente)

### T4. Python instalado, mas fora do PATH da sessão

**Sintoma:** `Python foi instalado mas nao esta no PATH da sessao. Feche e reabra o PowerShell elevado e reexecute (idempotente).`

**Solução:** é exatamente o que a mensagem diz — a sessão atual foi aberta antes da instalação e não herda o novo PATH. Feche **todas** as janelas do PowerShell, reabra como Administrador e reexecute. Se persistir:

```powershell
python --version                        # deve responder 3.x
where.exe python                        # deve apontar para o Python recém-instalado
```

Requisito mínimo do projeto: **Python 3.10+** (o instalador aborta com versão inferior).

---

## Instalação nativa

### T5. Serviço do MariaDB não sobe

**Sintoma:** `Servico de banco '<nome>' nao ficou ativo. Verifique o Visualizador de Eventos...`

**Diagnóstico:**

```powershell
Get-Service | Where-Object { $_.Name -match '^(MariaDB|MySQL)' }   # existe? Status?
Get-Service <nome> | Select-Object Name, Status, StartType
```

**Soluções:**

```powershell
Set-Service <nome> -StartupType Automatic   # se estiver Disabled (o instalador faz isso)
Start-Service <nome>                        # tente subir manualmente
```

Se `Start-Service` falhar: **Visualizador de Eventos → Logs do Windows → Aplicativo** (fonte `MariaDB`/`MySQL`), causa mais comum é instalação do MariaDB mal concluída (instalador MSI interrompido). Reinstale o MSI e reexecute o instalador — o estado do banco é preservado.

### T6. Credencial de root do banco rejeitada

**Sintoma:** `Nao foi possivel autenticar como root do banco...` / `Credencial de root invalida`.

**Contexto:** no Windows não existe o socket unix do Linux — a administração do banco é feita via TCP com a senha de **root** do MariaDB (a que você definiu no instalador MSI). O instalador tenta automaticamente: `SISPAT_DB_ADMIN_PASSWORD` → senha vazia.

**Solução:** no modo **não interativo**, exporte a senha no ambiente antes de executar (nunca em argv):

```powershell
$env:SISPAT_DB_ADMIN_PASSWORD = 'senha-do-root-do-mariadb'
powershell -ExecutionPolicy Bypass -File install.ps1 -NonInteractive -GenerateDbPassword
Remove-Item Env:\SISPAT_DB_ADMIN_PASSWORD
```

No modo interativo o instalador simplesmente pede a senha sem eco. Se você **perdeu** a senha de root, siga o procedimento oficial de reset (skip-grant-tables) da documentação do MariaDB e reexecute.

Teste manual (senha vai por ambiente — nunca no argv):

```powershell
$env:MYSQL_PWD = 'senha-do-root'
& "C:\Program Files\MariaDB 11.4\bin\mysql.exe" -uroot -h 127.0.0.1 -P 3306 -e "SELECT VERSION();"
Remove-Item Env:\MYSQL_PWD
```

### T7. Porta 8000 em uso ou bloqueada

**Sintoma (instalador):** `Porta 8000 ja esta em uso (verifique antes de iniciar a tarefa).`

**Diagnóstico — quem está usando:**

```powershell
$conn = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
$conn | Select-Object LocalAddress, OwningProcess
Get-Process -Id $conn.OwningProcess
```

**Soluções:** pare o processo conflitante **ou** instale em outra porta (`-AppPort 8080`). Trocar a porta depois: reexecute o instalador com `-AppPort` — ele atualiza o `.env` quando você aceita completar chaves.

### T8. Timeout no /health (nativa)

**Sintoma:** `Aplicacao nao respondeu em /health dentro de 120s` — o instalador mostra o estado da tarefa e o último log da app, e **para a tarefa** de propósito (evita loop de reinício).

**Diagnóstico:** rode a aplicação **em primeiro plano** para ver o traceback real:

```powershell
cd C:\SisPatrimonioPro
.venv\Scripts\python.exe run.py
```

Também útil:

```powershell
Get-ScheduledTask -TaskName sispatrimoniopro | Select-Object State
Get-ChildItem C:\SisPatrimonioPro\data\logs | Sort-Object LastWriteTime -Descending | Select-Object -First 3
Get-Content (Get-ChildItem C:\SisPatrimonioPro\data\logs\*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 40
```

**Causas mais comuns:** `DATABASE_URL` errado no `.env` (veja T9), porta ocupada (T7), dependência nativa quebrada no venv (reexecute o instalador — ele recria o venv inválido automaticamente).

### T9. init_db falha / Access denied / erro 1050

**Sintomas no log/traceback:** `Access denied for user ...`, `backup_config doesn't exist`, `Table 'xxx' already exists` (1050).

| Erro | Causa provável | Solução |
|---|---|---|
| `Access denied` | senha do `.env` diverge da senha do usuário do banco | reexecute o instalador — ele detecta a divergência e oferece **alinhar a senha** via `ALTER USER` |
| `already exists` (1050) | instância anterior da app executou `init_db` junto com o instalador | nada a fazer: o instalador já **para a tarefa** antes do `init_db`; reexecute — `create_all` é idempotente |
| `Unknown database` | banco não existe (ex.: apagado manualmente) | reexecute o instalador (cria o banco; os dados, se havia, não voltam) |

Teste manual da conexão (usa o `DATABASE_URL` do `.env` — rode de dentro do diretório):

```powershell
cd C:\SisPatrimonioPro
.venv\Scripts\python.exe -c "from app.config import DATABASE_URL; from sqlalchemy import create_engine, text; c = create_engine(DATABASE_URL).connect(); print('OK:', c.execute(text('SELECT DATABASE()')).scalar()); c.close()"
```

### T10. Acesso via rede bloqueado (firewall)

**Sintoma:** app responde no próprio servidor (`http://127.0.0.1:8000`) mas não de outra máquina.

**Diagnóstico/solução:** o instalador cria a regra de entrada `SisPatrimonio Pro (<porta>)`. Verifique:

```powershell
Get-NetFirewallRule -DisplayName "SisPatrimonio Pro*" | Select-Object DisplayName, Enabled, Direction, Action
```

Se não existir (ou se `-AppHost 127.0.0.1` foi usado — nesse caso a app **não** escuta na rede de propósito), recrie:

```powershell
New-NetFirewallRule -DisplayName "SisPatrimonio Pro (8000)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8000
```

Atenção também a firewalls corporativos de terceiros e ao IP correto do servidor (`Get-NetIPAddress -AddressFamily IPv4`).

---

## Variante Docker

### T11. Docker daemon indisponível

**Sintoma:** `Daemon do Docker indisponivel (docker info falhou)` — o instalador tenta iniciar o Docker Desktop e aguarda até 2 minutos.

**Solução:**

```powershell
Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue      # está rodando?
Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
# aguarde o ícone do Docker ficar estável e então:
docker info                                                      # deve responder sem erro
```

Depois **reexecute o instalador**. Se o Docker Desktop não estiver instalado: https://www.docker.com/products/docker-desktop/ — exige WSL2 ativado no Windows.

### T12. -DbName / -DbUser diverge do compose

**Sintoma:** `--db-name ... diverge do banco fixado pelo compose do repositorio ('sispatrimonio_pro')`.

**Causa:** na variante Docker o banco/usuário são **fixados pelo `docker-compose.yml` do repositório** (fonte da verdade). As opções `-DbName`/`-DbUser` existem só para conferência.

**Solução:** remova as opções divergentes (ou ajuste o compose no próprio repositório, se você é o mantenedor). **Nunca** edite o compose clonado dentro de `C:\SisPatrimonioPro` — o `git status` ficará sujo e reinstalações futuras recusam o diretório.

### T13. Container do banco unhealthy

**Sintoma:** `Container do banco em estado unhealthy` ou `nao ficou saudavel em 240s` — o instalador imprime as últimas linhas do log do container.

**Diagnóstico:**

```powershell
cd C:\SisPatrimonioPro
docker compose ps
docker compose logs --tail 50 db
docker inspect -f '{{.State.Health.Status}}' sispat-db
```

**Causas comuns:** primeira inicialização lenta (disco cheio/antivírus — aguarde e reexecute); `DB_PASSWORD` mudou no `.env` com volume antigo (o instalador realinha a senha do usuário via root automaticamente; se o root também não confere, veja T14); pouca memória para o WSL2 (aumente em Docker Desktop → Settings → Resources).

### T14. Volume do banco "em uso"

**Sintoma (install com `-ResetDb` ou uninstall):** `Nao foi possivel remover o volume (em uso?)`.

**Solução:** os containers precisam parar primeiro:

```powershell
cd C:\SisPatrimonioPro
docker compose down --remove-orphans
docker volume ls                          # localize <projeto>_db-data
docker volume rm <projeto>_db-data
```

⚠️ `docker volume rm <projeto>_db-data` apaga **todos os dados do banco** — é exatamente o que `-ResetDb`/desinstalação fazem com dupla confirmação. Só faça se é isso mesmo que você quer. O volume `app-data` (backups/logs) é outro volume e não é afetado.

### Verificações rápidas Docker

```powershell
cd C:\SisPatrimonioPro
docker compose ps                 # app Up (healthy?) + db Up (healthy)
docker compose logs -f app        # logs da aplicação
Invoke-RestMethod http://127.0.0.1:8000/health
```

---

## Serviço (Tarefa Agendada) e desinstalação

### T15. Tarefa agendada não sobe no boot

**Sintoma:** após reiniciar o servidor, a aplicação não está no ar.

**Diagnóstico:**

```powershell
Get-ScheduledTask -TaskName sispatrimoniopro | Select-Object State    # Ready = ok, parada
Get-ScheduledTaskInfo -TaskName sispatrimoniopro                      # LastTaskResult, NumberOfMissedRuns
```

**Soluções:**

```powershell
Start-ScheduledTask -TaskName sispatrimoniopro        # sobe manualmente agora
```

- `LastTaskResult` diferente de 0: rode a app em primeiro plano (T8) para ver o erro real.
- O disparo é `AtStartup` com atraso de 30s e reinicia até 3x em falha (intervalo 1 min). Se a máquina demora a subir a rede/banco, o delay costuma cobrir; aumente o atraso no **Agendador de Tarefas** GUI se necessário.
- A tarefa roda como **SYSTEM**: confirme que o usuário não removeu a tarefa ou que política de domínio não desativa tarefas de terceiros.

### T16. Desinstalação preservou itens

**Comportamento esperado** — nada é apagado sem confirmação:

| Item | Por que foi preservado | Como remover de fato |
|---|---|---|
| Banco / volume do banco | exige **digitar o nome do banco** (mesmo com `-Yes`) — proteção contra perda de dados | reexecute o desinstalador e digite o nome quando pedido |
| Volume `app-data` (Docker) | confirmação própria, separada da do banco | aceite o prompt próprio no desinstalador |
| MariaDB inteiro | só sai com `-PurgeMariaDb` + dupla confirmação (`PURGAR-MARIADB`) | reexecute com `-PurgeMariaDb` |
| Imagens Docker | só saem com `-PurgeDocker` + `PURGAR-IMAGENS`; Docker Engine **nunca** é removido | reexecute com `-PurgeDocker` |
| "Docker daemon indisponivel — volume PRESERVADO" | sem o Docker ativo não há como remover o volume com segurança | inicie o Docker Desktop e reexecute o desinstalador (idempotente) |

Todos os desinstaladores podem ser reexecutados quantas vezes quiser — itens já removidos são apenas reportados como "nada a fazer".

---

## Ambiente

### T17. Proxy ou rede restrita

**Sintomas:** falha em `git ls-remote` (`Nao foi possivel acessar <repo>`), `pip install` com timeout de rede, winget sem catálogo.

**Solução:** exporte o proxy na sessão antes de executar (git, pip e winget o respeitam):

```powershell
$env:HTTPS_PROXY = 'http://proxy.empresa:3128'
$env:HTTP_PROXY  = 'http://proxy.empresa:3128'
```

Limitações conhecidas: a variante **Windows não tem suporte a air-gapped** (`--wheel-dir` existe só no instalador Linux nativo); winget exige acesso ao catálogo da Microsoft. Ambientes 100% isolados: pré-instale Python/Git/MariaDB e prepare um mirror de PyPI (`pip config set global.index-url ...`), então reexecute o instalador.

### Arquivo de log e ACL do .env

```powershell
# Log do instalador (as credenciais NUNCA vão para o log — o instalador audita isso ao final)
Get-Content "$env:ProgramData\sispatrimonio-install.log" -Tail 50

# ACL restrita do .env (apenas SYSTEM/Administradores/usuario — equivale ao 0600 do Linux)
icacls C:\SisPatrimonioPro\.env
```

### Coleta de diagnóstico para chamado de suporte

```powershell
# (Admin) Gera %TEMP%\sispat-diag\ — SEM credenciais; revise antes de enviar
$d = "$env:TEMP\sispat-diag"; New-Item -ItemType Directory -Force $d | Out-Null
Get-ScheduledTask -TaskName sispatrimoniopro -ErrorAction SilentlyContinue | Out-File "$d\tarefa.txt"
Get-ScheduledTaskInfo -TaskName sispatrimoniopro -ErrorAction SilentlyContinue | Out-File "$d\tarefa-info.txt"
Get-Service | Where-Object { $_.Name -match '^(MariaDB|MySQL)' } | Out-File "$d\servico-bd.txt"
Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Out-File "$d\porta.txt"
Select-String -Path C:\SisPatrimonioPro\.env -Pattern '^(APP_HOST|APP_PORT|MYSQLDUMP_PATH)=' -ErrorAction SilentlyContinue | Out-File "$d\env-sem-credenciais.txt"
Copy-Item "$env:ProgramData\sispatrimonio-install*.log" $d -ErrorAction SilentlyContinue
Get-ChildItem C:\SisPatrimonioPro\data\logs -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime | Out-File "$d\logs-app.txt"
Write-Host "Diagnostico em: $d"
```

> O log do instalador e o `env-sem-credenciais.txt` não contêm senhas (o instalador audita o log ao final — SR-001). Os arquivos de `data\logs` são da aplicação; revise antes de enviar externamente.
