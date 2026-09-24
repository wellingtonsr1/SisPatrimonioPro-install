PS C:\WINDOWS\system32> powershell -ExecutionPolicy Bypass -File "D:\IA\SisPatrimonioPro-install\install no windows\docker\install-docker.ps1"
[OK   ] Executando com privilegios de administrador.

==============================================================
[INFO ] SisPatrimonio Pro - Instalador WINDOWS via DOCKER v2.1.0-docker-win (2026-09-24 13:18:02)
==============================================================

[OK   ] Docker CLI detectado: Docker version 29.6.2, build dfc4efb
[OK   ] Docker Compose v2 detectado.

-- [1/10] Docker, Compose v2 e pacotes base
[OK   ] Git disponivel.
[OK   ] Daemon do Docker em execucao.
[OK   ] Docker Compose v2 pronto (5.3.1).

-- [2/10] Codigo-fonte (clone)
[OK   ] Clone valido em C:\SisPatrimonioPro - reutilizado (HEAD: 5f31ab4).
[AVISO] O clone possui alteracoes locais (git status nao vazio). NADA sera revertido - revise antes de atualizar.

-- [3/10] docker-compose.yml do repo (analise)
[INFO ] Volume do banco 'sispatrimoniopro_db-data' nao existe (primeira instalacao do banco).
[OK   ] Compose analisado: containers sispat-app/sispat-db - banco sispatrimonio_pro (usuario sispatrimonio) - volume sispatrimoniopro_db-data.
Senha do banco (min. 12 caracteres; ENTER vazio nas duas = gerar automaticamente): : **************
Confirme a senha (vazio nas duas = gerar automaticamente):: **************
[OK   ] SECRET_KEY e senha de root do MariaDB geradas (gravadas apenas no .env).

  RESUMO DA INSTALACAO (DOCKER - compose do repositorio)
    Diretorio    : C:\SisPatrimonioPro
    Repositorio  : https://github.com/wellingtonsr1/SisPatrimonioPro.git (branch main)
    Compose      : C:\SisPatrimonioPro\docker-compose.yml (versionado no repo - nao alterado)
    Imagem app   : build local do Dockerfile do repo (servico 'app')
    Banco        : sispatrimonio_pro (usuario sispatrimonio) - container sispat-db
    Volume bd    : sispatrimoniopro_db-data (app-data de backups/logs preservado)
    Porta host   : 0.0.0.0:8000 -> container 8000
    Fuso (TZ)    : America/Sao_Paulo

  Confirmar e iniciar a instalacao? (s/N): : s
[OK   ] Confirmado.

-- [4/10] Arquivo de configuracao .env
[OK   ] .env gerado com ACL restrita (SR-002).
[OK   ] docker-compose.yml validado com o .env (docker compose config OK).

-- [5/10] Build da imagem da aplicacao
[INFO ] Construindo a imagem do servico 'app' (pode levar varios minutos na primeira vez)...
#1 [internal] load local bake definitions
#1 reading from stdin 499B 0.0s done
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 950B 0.0s done
#2 DONE 0.1s

#3 [internal] load metadata for docker.io/library/python:3.12-slim
#3 DONE 2.2s

#4 [internal] load .dockerignore
#4 transferring context: 2B done
#4 DONE 0.0s

#5 [1/9] FROM docker.io/library/python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9
#5 resolve docker.io/library/python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9 0.0s done
#5 sha256:06ad939ed42b51caafb25b14810875d14e0ee0c441d3e2e5e46475fb8c150bca 0B / 249B 0.2s
#5 ...

#6 [internal] load build context
#6 transferring context: 2.21MB 0.4s done
#6 DONE 0.5s

#5 [1/9] FROM docker.io/library/python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9
#5 sha256:06ad939ed42b51caafb25b14810875d14e0ee0c441d3e2e5e46475fb8c150bca 249B / 249B 0.2s done
#5 sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 0B / 12.12MB 0.3s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 0B / 29.83MB 0.2s
#5 sha256:3764a9a7d1e8a98213ab2201a41dbf3da9c60240ea35a5ea96ab994555070a70 0B / 1.29MB 0.2s
#5 sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 1.05MB / 12.12MB 0.8s
#5 sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 3.15MB / 12.12MB 0.9s
#5 sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 7.34MB / 12.12MB 1.1s
#5 sha256:3764a9a7d1e8a98213ab2201a41dbf3da9c60240ea35a5ea96ab994555070a70 1.29MB / 1.29MB 1.2s done
#5 sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 12.12MB / 12.12MB 1.4s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 2.10MB / 29.83MB 1.2s
#5 sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 12.12MB / 12.12MB 1.4s done
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 9.44MB / 29.83MB 1.5s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 13.63MB / 29.83MB 1.7s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 18.87MB / 29.83MB 1.8s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 23.07MB / 29.83MB 2.0s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 27.26MB / 29.83MB 2.1s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 29.83MB / 29.83MB 2.3s
#5 sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 29.83MB / 29.83MB 2.3s done
#5 extracting sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8
#5 extracting sha256:6b37362b3da78869050b894b799ad4df04f1f3b52774087db0d81151570244c8 1.0s done
#5 extracting sha256:3764a9a7d1e8a98213ab2201a41dbf3da9c60240ea35a5ea96ab994555070a70
#5 extracting sha256:3764a9a7d1e8a98213ab2201a41dbf3da9c60240ea35a5ea96ab994555070a70 0.1s done
#5 DONE 3.7s

#5 [1/9] FROM docker.io/library/python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9
#5 extracting sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0
#5 extracting sha256:b0dc7f87bef15c2536cb182d6c48b52f90a0522884ec9eb222f833fa97ffebf0 0.6s done
#5 DONE 4.3s

#5 [1/9] FROM docker.io/library/python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9
#5 extracting sha256:06ad939ed42b51caafb25b14810875d14e0ee0c441d3e2e5e46475fb8c150bca 0.0s done
#5 DONE 4.3s

#7 [2/9] RUN apt-get update     && apt-get install -y --no-install-recommends default-mysql-client tzdata     && rm -rf /var/lib/apt/lists/*
#7 0.514 Hit:1 http://deb.debian.org/debian trixie InRelease
#7 0.571 Get:2 http://deb.debian.org/debian trixie-updates InRelease [47.3 kB]
#7 0.725 Get:3 http://deb.debian.org/debian-security trixie-security InRelease [43.4 kB]
#7 0.812 Get:4 http://deb.debian.org/debian trixie/main amd64 Packages [9678 kB]
#7 1.483 Get:5 http://deb.debian.org/debian trixie-updates/main amd64 Packages [4412 B]
#7 1.560 Get:6 http://deb.debian.org/debian-security trixie-security/main amd64 Packages [263 kB]
#7 2.378 Fetched 10.0 MB in 2s (4740 kB/s)
#7 2.378 Reading package lists...
#7 3.039 Reading package lists...
#7 3.693 Building dependency tree...
#7 3.832 Reading state information...
#7 4.045 tzdata is already the newest version (2026c-0+deb13u1).
#7 4.045 The following additional packages will be installed:
#7 4.045   libconfig-inifiles-perl libedit2 libgdbm-compat4t64 libmariadb3 libncurses6
#7 4.046   libpcre2-posix3 libperl5.40 mariadb-client mariadb-client-compat
#7 4.047   mariadb-client-core mariadb-common mysql-common perl perl-modules-5.40
#7 4.050 Suggested packages:
#7 4.050   sensible-utils perl-doc libterm-readline-gnu-perl
#7 4.050   | libterm-readline-perl-perl make libtap-harness-archive-perl
#7 4.050 Recommended packages:
#7 4.050   libgpm2 libdbd-mariadb-perl | libdbd-mysql-perl libdbi-perl
#7 4.050   libterm-readkey-perl
#7 4.175 The following NEW packages will be installed:
#7 4.175   default-mysql-client libconfig-inifiles-perl libedit2 libgdbm-compat4t64
#7 4.176   libmariadb3 libncurses6 libpcre2-posix3 libperl5.40 mariadb-client
#7 4.176   mariadb-client-compat mariadb-client-core mariadb-common mysql-common perl
#7 4.176   perl-modules-5.40
#7 4.364 0 upgraded, 15 newly installed, 0 to remove and 0 not upgraded.
#7 4.364 Need to get 12.3 MB of archives.
#7 4.364 After this operation, 135 MB of additional disk space will be used.
#7 4.364 Get:1 http://deb.debian.org/debian trixie/main amd64 perl-modules-5.40 all 5.40.1-6+deb13u1 [3014 kB]
#7 4.931 Get:2 http://deb.debian.org/debian trixie/main amd64 libgdbm-compat4t64 amd64 1.24-2 [50.3 kB]
#7 4.938 Get:3 http://deb.debian.org/debian trixie/main amd64 libperl5.40 amd64 5.40.1-6+deb13u1 [4326 kB]
#7 5.140 Get:4 http://deb.debian.org/debian trixie/main amd64 perl amd64 5.40.1-6+deb13u1 [268 kB]
#7 5.148 Get:5 http://deb.debian.org/debian trixie/main amd64 libconfig-inifiles-perl all 3.000003-3+deb13u1 [45.0 kB]
#7 5.149 Get:6 http://deb.debian.org/debian trixie/main amd64 mysql-common all 5.8+1.1.1 [6784 B]
#7 5.150 Get:7 http://deb.debian.org/debian trixie/main amd64 mariadb-common all 1:11.8.6-0+deb13u1 [29.5 kB]
#7 5.150 Get:8 http://deb.debian.org/debian trixie/main amd64 libmariadb3 amd64 1:11.8.6-0+deb13u1 [187 kB]
#7 5.157 Get:9 http://deb.debian.org/debian trixie/main amd64 libedit2 amd64 3.1-20250104-1 [93.8 kB]
#7 5.201 Get:10 http://deb.debian.org/debian trixie/main amd64 libncurses6 amd64 6.5+20250216-2 [105 kB]
#7 5.208 Get:11 http://deb.debian.org/debian trixie/main amd64 mariadb-client-core amd64 1:11.8.6-0+deb13u1 [919 kB]
#7 5.239 Get:12 http://deb.debian.org/debian trixie/main amd64 libpcre2-posix3 amd64 10.46-1~deb13u2 [64.0 kB]
#7 5.296 Get:13 http://deb.debian.org/debian trixie/main amd64 mariadb-client amd64 1:11.8.6-0+deb13u1 [3164 kB]
#7 5.424 Get:14 http://deb.debian.org/debian trixie/main amd64 mariadb-client-compat all 1:11.8.6-0+deb13u1 [29.7 kB]
#7 5.424 Get:15 http://deb.debian.org/debian trixie/main amd64 default-mysql-client all 1.1.1 [3028 B]
#7 5.596 debconf: unable to initialize frontend: Dialog
#7 5.596 debconf: (TERM is not set, so the dialog frontend is not usable.)
#7 5.596 debconf: falling back to frontend: Readline
#7 5.597 debconf: unable to initialize frontend: Readline
#7 5.597 debconf: (Can't locate Term/ReadLine.pm in @INC (you may need to install the Term::ReadLine module) (@INC entries checked: /etc/perl /usr/local/lib/x86_64-linux-gnu/perl/5.40.1 /usr/local/share/perl/5.40.1 /usr/lib/x86_64-linux-gnu/perl5/5.40 /usr/share/perl5 /usr/lib/x86_64-linux-gnu/perl-base /usr/lib/x86_64-linux-gnu/perl/5.40 /usr/share/perl/5.40 /usr/local/lib/site_perl) at /usr/share/perl5/Debconf/FrontEnd/Readline.pm line 8, <STDIN> line 15.)
#7 5.597 debconf: falling back to frontend: Teletype
#7 5.604 debconf: unable to initialize frontend: Teletype
#7 5.604 debconf: (This frontend requires a controlling tty.)
#7 5.604 debconf: falling back to frontend: Noninteractive
#7 6.299 Fetched 12.3 MB in 1s (9966 kB/s)
#7 6.327 Selecting previously unselected package perl-modules-5.40.
(Reading database ... 5660 files and directories currently installed.)
#7 6.334 Preparing to unpack .../00-perl-modules-5.40_5.40.1-6+deb13u1_all.deb ...
#7 6.341 Unpacking perl-modules-5.40 (5.40.1-6+deb13u1) ...
#7 6.644 Selecting previously unselected package libgdbm-compat4t64:amd64.
#7 6.645 Preparing to unpack .../01-libgdbm-compat4t64_1.24-2_amd64.deb ...
#7 6.657 Unpacking libgdbm-compat4t64:amd64 (1.24-2) ...
#7 6.706 Selecting previously unselected package libperl5.40:amd64.
#7 6.708 Preparing to unpack .../02-libperl5.40_5.40.1-6+deb13u1_amd64.deb ...
#7 6.714 Unpacking libperl5.40:amd64 (5.40.1-6+deb13u1) ...
#7 7.025 Selecting previously unselected package perl.
#7 7.027 Preparing to unpack .../03-perl_5.40.1-6+deb13u1_amd64.deb ...
#7 7.035 Unpacking perl (5.40.1-6+deb13u1) ...
#7 7.087 Selecting previously unselected package libconfig-inifiles-perl.
#7 7.089 Preparing to unpack .../04-libconfig-inifiles-perl_3.000003-3+deb13u1_all.deb ...
#7 7.095 Unpacking libconfig-inifiles-perl (3.000003-3+deb13u1) ...
#7 7.159 Selecting previously unselected package mysql-common.
#7 7.161 Preparing to unpack .../05-mysql-common_5.8+1.1.1_all.deb ...
#7 7.181 Unpacking mysql-common (5.8+1.1.1) ...
#7 7.232 Selecting previously unselected package mariadb-common.
#7 7.233 Preparing to unpack .../06-mariadb-common_1%3a11.8.6-0+deb13u1_all.deb ...
#7 7.260 Unpacking mariadb-common (1:11.8.6-0+deb13u1) ...
#7 7.307 Selecting previously unselected package libmariadb3:amd64.
#7 7.309 Preparing to unpack .../07-libmariadb3_1%3a11.8.6-0+deb13u1_amd64.deb ...
#7 7.315 Unpacking libmariadb3:amd64 (1:11.8.6-0+deb13u1) ...
#7 7.370 Selecting previously unselected package libedit2:amd64.
#7 7.372 Preparing to unpack .../08-libedit2_3.1-20250104-1_amd64.deb ...
#7 7.378 Unpacking libedit2:amd64 (3.1-20250104-1) ...
#7 7.430 Selecting previously unselected package libncurses6:amd64.
#7 7.432 Preparing to unpack .../09-libncurses6_6.5+20250216-2_amd64.deb ...
#7 7.438 Unpacking libncurses6:amd64 (6.5+20250216-2) ...
#7 7.480 Selecting previously unselected package mariadb-client-core.
#7 7.481 Preparing to unpack .../10-mariadb-client-core_1%3a11.8.6-0+deb13u1_amd64.deb ...
#7 7.487 Unpacking mariadb-client-core (1:11.8.6-0+deb13u1) ...
#7 7.630 Selecting previously unselected package libpcre2-posix3:amd64.
#7 7.631 Preparing to unpack .../11-libpcre2-posix3_10.46-1~deb13u2_amd64.deb ...
#7 7.637 Unpacking libpcre2-posix3:amd64 (10.46-1~deb13u2) ...
#7 7.684 Selecting previously unselected package mariadb-client.
#7 7.686 Preparing to unpack .../12-mariadb-client_1%3a11.8.6-0+deb13u1_amd64.deb ...
#7 7.692 Unpacking mariadb-client (1:11.8.6-0+deb13u1) ...
#7 8.013 Selecting previously unselected package mariadb-client-compat.
#7 8.015 Preparing to unpack .../13-mariadb-client-compat_1%3a11.8.6-0+deb13u1_all.deb ...
#7 8.020 Unpacking mariadb-client-compat (1:11.8.6-0+deb13u1) ...
#7 8.060 Selecting previously unselected package default-mysql-client.
#7 8.062 Preparing to unpack .../14-default-mysql-client_1.1.1_all.deb ...
#7 8.068 Unpacking default-mysql-client (1.1.1) ...
#7 8.113 Setting up libconfig-inifiles-perl (3.000003-3+deb13u1) ...
#7 8.132 Setting up mysql-common (5.8+1.1.1) ...
#7 8.174 update-alternatives: using /etc/mysql/my.cnf.fallback to provide /etc/mysql/my.cnf (my.cnf) in auto mode
#7 8.184 Setting up libgdbm-compat4t64:amd64 (1.24-2) ...
#7 8.200 Setting up libedit2:amd64 (3.1-20250104-1) ...
#7 8.217 Setting up mariadb-common (1:11.8.6-0+deb13u1) ...
#7 8.237 update-alternatives: using /etc/mysql/mariadb.cnf to provide /etc/mysql/my.cnf (my.cnf) in auto mode
#7 8.270 Setting up libncurses6:amd64 (6.5+20250216-2) ...
#7 8.286 Setting up libmariadb3:amd64 (1:11.8.6-0+deb13u1) ...
#7 8.303 Setting up libpcre2-posix3:amd64 (10.46-1~deb13u2) ...
#7 8.320 Setting up perl-modules-5.40 (5.40.1-6+deb13u1) ...
#7 8.338 Setting up mariadb-client-core (1:11.8.6-0+deb13u1) ...
#7 8.354 Setting up libperl5.40:amd64 (5.40.1-6+deb13u1) ...
#7 8.372 Setting up perl (5.40.1-6+deb13u1) ...
#7 8.399 Setting up mariadb-client (1:11.8.6-0+deb13u1) ...
#7 8.435 Setting up mariadb-client-compat (1:11.8.6-0+deb13u1) ...
#7 8.452 Setting up default-mysql-client (1.1.1) ...
#7 8.470 Processing triggers for libc-bin (2.41-12+deb13u4) ...
#7 DONE 9.9s

#8 [3/9] WORKDIR /app
#8 DONE 0.1s

#9 [4/9] COPY requirements.txt .
#9 DONE 0.1s

#10 [5/9] RUN pip install --no-cache-dir -r requirements.txt
#10 2.128 Collecting fastapi>=0.110.0 (from -r requirements.txt (line 1))
#10 2.381   Downloading fastapi-0.141.1-py3-none-any.whl.metadata (27 kB)
#10 2.515 Collecting uvicorn>=0.28.0 (from uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 2.588   Downloading uvicorn-0.53.0-py3-none-any.whl.metadata (6.6 kB)
#10 3.133 Collecting sqlalchemy>=2.0.0 (from -r requirements.txt (line 3))
#10 3.207   Downloading sqlalchemy-2.0.54-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl.metadata (9.7 kB)
#10 3.410 Collecting pydantic>=2.6.0 (from -r requirements.txt (line 4))
#10 3.489   Downloading pydantic-2.13.5-py3-none-any.whl.metadata (110 kB)
#10 3.679 Collecting jinja2>=3.1.3 (from -r requirements.txt (line 5))
#10 3.758   Downloading jinja2-3.1.6-py3-none-any.whl.metadata (2.9 kB)
#10 3.843 Collecting python-multipart>=0.0.9 (from -r requirements.txt (line 6))
#10 3.919   Downloading python_multipart-0.0.32-py3-none-any.whl.metadata (2.1 kB)
#10 4.034 Collecting pytest>=8.0.0 (from -r requirements.txt (line 7))
#10 4.109   Downloading pytest-9.1.1-py3-none-any.whl.metadata (7.6 kB)
#10 4.217 Collecting requests>=2.31.0 (from -r requirements.txt (line 8))
#10 4.300   Downloading requests-2.34.2-py3-none-any.whl.metadata (4.8 kB)
#10 4.396 Collecting ldap3>=2.9.1 (from -r requirements.txt (line 9))
#10 4.476   Downloading ldap3-2.9.1-py2.py3-none-any.whl.metadata (5.4 kB)
#10 4.570 Collecting pymysql>=1.1.0 (from -r requirements.txt (line 14))
#10 4.645   Downloading pymysql-1.2.3-py3-none-any.whl.metadata (4.2 kB)
#10 4.737 Collecting python-dotenv>=1.0.0 (from -r requirements.txt (line 16))
#10 4.811   Downloading python_dotenv-1.2.3-py3-none-any.whl.metadata (29 kB)
#10 4.906 Collecting openpyxl>=3.1.0 (from -r requirements.txt (line 17))
#10 4.986   Downloading openpyxl-3.1.5-py2.py3-none-any.whl.metadata (2.5 kB)
#10 5.278 Collecting reportlab>=4.0.0 (from -r requirements.txt (line 18))
#10 5.356   Downloading reportlab-5.0.1-py3-none-any.whl.metadata (1.6 kB)
#10 5.465 Collecting starlette>=0.46.0 (from fastapi>=0.110.0->-r requirements.txt (line 1))
#10 5.538   Downloading starlette-1.7.0-py3-none-any.whl.metadata (6.6 kB)
#10 5.663 Collecting typing-extensions>=4.8.0 (from fastapi>=0.110.0->-r requirements.txt (line 1))
#10 5.738   Downloading typing_extensions-4.16.0-py3-none-any.whl.metadata (3.3 kB)
#10 5.822 Collecting typing-inspection>=0.4.2 (from fastapi>=0.110.0->-r requirements.txt (line 1))
#10 5.898   Downloading typing_inspection-0.4.4-py3-none-any.whl.metadata (2.6 kB)
#10 5.990 Collecting annotated-doc>=0.0.2 (from fastapi>=0.110.0->-r requirements.txt (line 1))
#10 6.064   Downloading annotated_doc-0.0.5-py3-none-any.whl.metadata (6.5 kB)
#10 6.178 Collecting click>=7.0 (from uvicorn>=0.28.0->uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 6.256   Downloading click-8.5.0-py3-none-any.whl.metadata (2.6 kB)
#10 6.351 Collecting h11>=0.8 (from uvicorn>=0.28.0->uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 6.431   Downloading h11-0.16.0-py3-none-any.whl.metadata (8.3 kB)
#10 6.656 Collecting greenlet>=1 (from sqlalchemy>=2.0.0->-r requirements.txt (line 3))
#10 6.730   Downloading greenlet-3.5.6-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl.metadata (3.8 kB)
#10 6.816 Collecting annotated-types>=0.6.0 (from pydantic>=2.6.0->-r requirements.txt (line 4))
#10 6.894   Downloading annotated_types-0.8.0-py3-none-any.whl.metadata (15 kB)
#10 7.746 Collecting pydantic-core==2.46.5 (from pydantic>=2.6.0->-r requirements.txt (line 4))
#10 7.820   Downloading pydantic_core-2.46.5-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl.metadata (6.6 kB)
#10 7.976 Collecting MarkupSafe>=2.0 (from jinja2>=3.1.3->-r requirements.txt (line 5))
#10 8.049   Downloading markupsafe-3.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl.metadata (2.7 kB)
#10 8.132 Collecting iniconfig>=1.0.1 (from pytest>=8.0.0->-r requirements.txt (line 7))
#10 8.208   Downloading iniconfig-2.3.0-py3-none-any.whl.metadata (2.5 kB)
#10 8.308 Collecting packaging>=22 (from pytest>=8.0.0->-r requirements.txt (line 7))
#10 8.385   Downloading packaging-26.3-py3-none-any.whl.metadata (3.5 kB)
#10 8.496 Collecting pluggy<2,>=1.5 (from pytest>=8.0.0->-r requirements.txt (line 7))
#10 8.574   Downloading pluggy-1.6.0-py3-none-any.whl.metadata (4.8 kB)
#10 8.668 Collecting pygments>=2.7.2 (from pytest>=8.0.0->-r requirements.txt (line 7))
#10 8.744   Downloading pygments-2.21.0-py3-none-any.whl.metadata (2.5 kB)
#10 8.937 Collecting charset_normalizer<4,>=2 (from requests>=2.31.0->-r requirements.txt (line 8))
#10 9.013   Downloading charset_normalizer-3.5.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl.metadata (45 kB)
#10 9.132 Collecting idna<4,>=2.5 (from requests>=2.31.0->-r requirements.txt (line 8))
#10 9.206   Downloading idna-3.20-py3-none-any.whl.metadata (7.2 kB)
#10 9.309 Collecting urllib3<3,>=1.26 (from requests>=2.31.0->-r requirements.txt (line 8))
#10 9.389   Downloading urllib3-2.8.0-py3-none-any.whl.metadata (7.4 kB)
#10 9.494 Collecting certifi>=2023.5.7 (from requests>=2.31.0->-r requirements.txt (line 8))
#10 9.567   Downloading certifi-2026.7.22-py3-none-any.whl.metadata (2.5 kB)
#10 9.666 Collecting pyasn1>=0.4.6 (from ldap3>=2.9.1->-r requirements.txt (line 9))
#10 9.745   Downloading pyasn1-0.6.4-py3-none-any.whl.metadata (8.4 kB)
#10 9.829 Collecting et-xmlfile (from openpyxl>=3.1.0->-r requirements.txt (line 17))
#10 9.906   Downloading et_xmlfile-2.0.0-py3-none-any.whl.metadata (2.7 kB)
#10 10.17 Collecting pillow>=9.0.0 (from reportlab>=4.0.0->-r requirements.txt (line 18))
#10 10.24   Downloading pillow-12.3.0-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl.metadata (9.1 kB)
#10 10.35 Collecting httptools>=0.8.0 (from uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 10.43   Downloading httptools-0.8.0-cp312-cp312-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl.metadata (3.5 kB)
#10 10.56 Collecting pyyaml>=5.1 (from uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 10.64   Downloading pyyaml-6.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl.metadata (2.4 kB)
#10 10.75 Collecting uvloop>=0.15.1 (from uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 10.82   Downloading uvloop-0.22.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl.metadata (4.9 kB)
#10 10.98 Collecting watchfiles>=0.20 (from uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 11.05   Downloading watchfiles-1.3.0-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl.metadata (4.9 kB)
#10 11.24 Collecting websockets>=13.0 (from uvicorn[standard]>=0.28.0->-r requirements.txt (line 2))
#10 11.31   Downloading websockets-17.1-cp312-cp312-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl.metadata (6.3 kB)
#10 11.44 Collecting anyio<5,>=4.0.0 (from starlette>=0.46.0->fastapi>=0.110.0->-r requirements.txt (line 1))
#10 11.51   Downloading anyio-4.15.1-py3-none-any.whl.metadata (4.7 kB)
#10 11.63 Downloading fastapi-0.141.1-py3-none-any.whl (131 kB)
#10 11.78 Downloading uvicorn-0.53.0-py3-none-any.whl (87 kB)
#10 11.86 Downloading sqlalchemy-2.0.54-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (3.5 MB)
#10 12.15    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 3.5/3.5 MB 14.4 MB/s eta 0:00:00
#10 12.23 Downloading pydantic-2.13.5-py3-none-any.whl (472 kB)
#10 12.36 Downloading pydantic_core-2.46.5-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl (2.1 MB)
#10 12.47    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 2.1/2.1 MB 27.8 MB/s eta 0:00:00
#10 12.55 Downloading jinja2-3.1.6-py3-none-any.whl (134 kB)
#10 12.65 Downloading python_multipart-0.0.32-py3-none-any.whl (30 kB)
#10 12.74 Downloading pytest-9.1.1-py3-none-any.whl (386 kB)
#10 12.85 Downloading requests-2.34.2-py3-none-any.whl (73 kB)
#10 12.94 Downloading ldap3-2.9.1-py2.py3-none-any.whl (432 kB)
#10 13.03 Downloading pymysql-1.2.3-py3-none-any.whl (46 kB)
#10 13.12 Downloading python_dotenv-1.2.3-py3-none-any.whl (22 kB)
#10 13.20 Downloading openpyxl-3.1.5-py2.py3-none-any.whl (250 kB)
#10 13.31 Downloading reportlab-5.0.1-py3-none-any.whl (2.0 MB)
#10 13.38    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 2.0/2.0 MB 31.9 MB/s eta 0:00:00
#10 13.45 Downloading annotated_doc-0.0.5-py3-none-any.whl (5.3 kB)
#10 13.54 Downloading annotated_types-0.8.0-py3-none-any.whl (13 kB)
#10 13.62 Downloading certifi-2026.7.22-py3-none-any.whl (136 kB)
#10 13.70 Downloading charset_normalizer-3.5.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (248 kB)
#10 13.81 Downloading click-8.5.0-py3-none-any.whl (125 kB)
#10 13.91 Downloading greenlet-3.5.6-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl (621 kB)
#10 13.97    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 621.4/621.4 kB 20.2 MB/s eta 0:00:00
#10 14.04 Downloading h11-0.16.0-py3-none-any.whl (37 kB)
#10 14.13 Downloading httptools-0.8.0-cp312-cp312-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl (523 kB)
#10 14.27 Downloading idna-3.20-py3-none-any.whl (69 kB)
#10 14.36 Downloading iniconfig-2.3.0-py3-none-any.whl (7.5 kB)
#10 14.44 Downloading markupsafe-3.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (22 kB)
#10 14.52 Downloading packaging-26.3-py3-none-any.whl (129 kB)
#10 14.63 Downloading pillow-12.3.0-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl (6.9 MB)
#10 14.91    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 6.9/6.9 MB 29.6 MB/s eta 0:00:00
#10 14.99 Downloading pluggy-1.6.0-py3-none-any.whl (20 kB)
#10 15.07 Downloading pyasn1-0.6.4-py3-none-any.whl (84 kB)
#10 15.16 Downloading pygments-2.21.0-py3-none-any.whl (1.3 MB)
#10 15.25    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 1.3/1.3 MB 18.2 MB/s eta 0:00:00
#10 15.33 Downloading pyyaml-6.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (807 kB)
#10 15.36    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 807.9/807.9 kB 34.0 MB/s eta 0:00:00
#10 15.44 Downloading starlette-1.7.0-py3-none-any.whl (78 kB)
#10 15.53 Downloading typing_extensions-4.16.0-py3-none-any.whl (45 kB)
#10 15.62 Downloading typing_inspection-0.4.4-py3-none-any.whl (14 kB)
#10 15.70 Downloading urllib3-2.8.0-py3-none-any.whl (135 kB)
#10 15.81 Downloading uvloop-0.22.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (4.4 MB)
#10 15.97    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 4.4/4.4 MB 29.6 MB/s eta 0:00:00
#10 16.05 Downloading watchfiles-1.3.0-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl (458 kB)
#10 16.15 Downloading websockets-17.1-cp312-cp312-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl (224 kB)
#10 16.25 Downloading et_xmlfile-2.0.0-py3-none-any.whl (18 kB)
#10 16.32 Downloading anyio-4.15.1-py3-none-any.whl (132 kB)
#10 16.57 Installing collected packages: websockets, uvloop, urllib3, typing-extensions, pyyaml, python-multipart, python-dotenv, pymysql, pygments, pyasn1, pluggy, pillow, packaging, MarkupSafe, iniconfig, idna, httptools, h11, greenlet, et-xmlfile, click, charset_normalizer, certifi, annotated-types, annotated-doc, uvicorn, typing-inspection, sqlalchemy, requests, reportlab, pytest, pydantic-core, openpyxl, ldap3, jinja2, anyio, watchfiles, starlette, pydantic, fastapi
#10 22.70 Successfully installed MarkupSafe-3.0.3 annotated-doc-0.0.5 annotated-types-0.8.0 anyio-4.15.1 certifi-2026.7.22 charset_normalizer-3.5.1 click-8.5.0 et-xmlfile-2.0.0 fastapi-0.141.1 greenlet-3.5.6 h11-0.16.0 httptools-0.8.0 idna-3.20 iniconfig-2.3.0 jinja2-3.1.6 ldap3-2.9.1 openpyxl-3.1.5 packaging-26.3 pillow-12.3.0 pluggy-1.6.0 pyasn1-0.6.4 pydantic-2.13.5 pydantic-core-2.46.5 pygments-2.21.0 pymysql-1.2.3 pytest-9.1.1 python-dotenv-1.2.3 python-multipart-0.0.32 pyyaml-6.0.3 reportlab-5.0.1 requests-2.34.2 sqlalchemy-2.0.54 starlette-1.7.0 typing-extensions-4.16.0 typing-inspection-0.4.4 urllib3-2.8.0 uvicorn-0.53.0 uvloop-0.22.1 watchfiles-1.3.0 websockets-17.1
#10 22.70 WARNING: Running pip as the 'root' user can result in broken permissions and conflicting behaviour with the system package manager, possibly rendering your system unusable. It is recommended to use a virtual environment instead: https://pip.pypa.io/warnings/venv. Use the --root-user-action option if you know what you are doing and want to suppress this warning.
#10 23.06
#10 23.06 [notice] A new release of pip is available: 25.0.1 -> 26.2.1
#10 23.06 [notice] To update, run: pip install --upgrade pip
#10 DONE 24.3s

#11 [6/9] COPY app/ ./app/
#11 DONE 0.1s

#12 [7/9] COPY docs/ ./docs/
#12 DONE 0.1s

#13 [8/9] COPY run.py seed_demo.py requirements.txt README.md ./
#13 DONE 0.1s

#14 [9/9] RUN mkdir -p data/backups data/logs
#14 DONE 0.2s

#15 exporting to image
#15 exporting layers
#15 exporting layers 6.5s done
#15 exporting manifest sha256:a2165e2cce1f2eff6031064d003b48bfe00ce4e821131adf21d78ea46f1c867b 0.0s done
#15 exporting config sha256:a7e9d0b564126b1e166b4483556884e2979dcdc0f07584806ee7654b0579d21c 0.0s done
#15 exporting attestation manifest sha256:1f81972b49f09ed515539ab0ec39bb8a2959d8c9e8b8e33def402bee35014511 0.0s done
#15 exporting manifest list sha256:bb17e553eb9d1a7a53fcd48f2a973f3ec08601a270262607063c0efa739df4a6
#15 exporting manifest list sha256:bb17e553eb9d1a7a53fcd48f2a973f3ec08601a270262607063c0efa739df4a6 0.0s done
#15 naming to docker.io/library/sispatrimoniopro-app:latest done
#15 unpacking to docker.io/library/sispatrimoniopro-app:latest
#15 unpacking to docker.io/library/sispatrimoniopro-app:latest 3.1s done
#15 DONE 9.8s

#16 resolving provenance for metadata file
#16 DONE 0.1s
[+] build 1/1
 ✔ Image sispatrimoniopro-app Built                                                                                52.3s
[OK   ] Imagem construida.
[OK   ] mysqldump presente na imagem: /usr/bin/mysqldump (backups da app OK).

-- [6/10] Banco de dados (container MariaDB)
[INFO ] Subindo o container do banco...
[+] up 12/12
 ✔ Image mariadb:11    Pulled                                                                                       9.9s
 ✔ Container sispat-db Started                                                                                      8.2s
[INFO ] Aguardando o container do banco ficar saudavel (ate 240s; primeira inicializacao pode demorar)...
[OK   ] Container do banco saudavel.
[OK   ] Banco 'sispatrimonio_pro' e usuario 'sispatrimonio' criados pelo entrypoint do MariaDB.

-- [7/10] Inicializacao do schema (init_db)
[INFO ] Executando init_db() do projeto em container efemero (create_all idempotente)...
Container sispatrimoniopro-app-run-14ab552ab652 Creating
Container sispatrimoniopro-app-run-14ab552ab652 Created
[OK   ] Schema verificado/criado via init_db() do projeto.

-- [8/10] Start + health check
[+] up 2/2
 ✔ Container sispat-db  Healthy                                                                                     0.6s
 ✔ Container sispat-app Started                                                                                     1.0s
[INFO ] Aguardando /health em http://127.0.0.1:8000 (ate 180s)...
[OK   ] Aplicacao saudavel: /health -> healthy

-- [9/10] Bateria pos-instalacao
[OK   ] Docker daemon: OK
[OK   ] Container da app em execucao: OK
[OK   ] Container do banco saudavel: OK
[OK   ] Tabela base (users) existente: OK
[OK   ] HTTP /health (host): OK
[OK   ] .env com ACL restrita (SR-002): OK
[OK   ] Bateria completa: todas as verificacoes passaram.

-- [10/10] Auditoria de seguranca
[OK   ] Auto-check: nenhuma credencial no log (SR-001).
[OK   ] .env com ACL restrita (SR-002).
[OK   ] DB_ROOT_PASSWORD definido no .env (default 'changeme-root' do compose nao esta em vigor).
[INFO ] Processo da app roda como: root (default da imagem) no container (definido pela imagem do repositorio).
[OK   ] Regra de firewall de entrada criada para a porta 8000 (acesso via rede).

  ==============================================================
[OK   ] SisPatrimonio Pro instalado com sucesso (DOCKER)!
  ==============================================================

  ACESSO
    Aplicacao    : http://172.22.208.1:8000
    Swagger API  : http://172.22.208.1:8000/docs
    Health check : http://172.22.208.1:8000/health

  INSTALACAO
    Diretorio    : C:\SisPatrimonioPro
    Compose      : C:\SisPatrimonioPro\docker-compose.yml (versionado no repo - nao alterado)
    Containers   : sispat-app | sispat-db
    Volumes      : sispatrimoniopro_db-data (banco) | dados da app: backups/logs
    Configuracao : C:\SisPatrimonioPro\.env (ACL restrita - contem credenciais)
    Log          : C:\ProgramData\sispatrimonio-install-docker.log

  GERENCIAR OS CONTAINERS (cd C:\SisPatrimonioPro)
    docker compose ps          # estado
    docker compose logs -f app # logs da aplicacao
    docker compose restart app # reiniciar aplicacao
    docker compose stop        # parar tudo (persistencia mantida)
    docker compose up -d       # subir novamente

  BACKUP DO BANCO (exemplo - senha em C:\SisPatrimonioPro\.env)
    cd "C:\SisPatrimonioPro"
    $root = (Get-Content .env | Where-Object { $_ -match '^DB_ROOT_PASSWORD=' }) -replace '^DB_ROOT_PASSWORD=',''
    $env:MYSQL_PWD = $root
    docker compose exec -T -e MYSQL_PWD=$root db mariadb-dump -uroot sispatrimonio_pro > backup-$(Get-Date -Format yyyy-MM-dd).sql

  PRIMEIRO ADMINISTRADOR (escolha um caminho - nunca exibimos senhas)
    A) CLI (recomendado):
       cd "C:\SisPatrimonioPro"
       docker compose exec app python3 -m app.cli create-user --username admin --name "Administrador" --admin
       (a senha e solicitada de forma oculta; minimo 8 caracteres)
    B) Primeiro acesso: abra a aplicacao e use a pagina /setup
       (disponivel enquanto nao existir nenhum usuario)
    C) Variaveis de ambiente: AUTH_ADMIN_USERNAME/AUTH_ADMIN_PASSWORD
       no .env antes do primeiro start (remova apos o primeiro login)

  As senhas do banco NAO aparecem neste resumo nem no log - estao
  apenas no .env (DB_PASSWORD, DB_ROOT_PASSWORD e SECRET_KEY), com ACL restrita.
  ==============================================================
[OK   ] Concluido.
PS C:\WINDOWS\system32>