FROM python:3.12-slim

# mysqldump (default-mysql-client) e necessario para backup/restauracao dentro do container
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-mysql-client tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Camada de dependencias separada (cache efetivo em rebuilds)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Codigo da aplicacao (whitelist igual ao snapshot de producao)
COPY app/ ./app/
COPY docs/ ./docs/
COPY run.py seed_demo.py requirements.txt README.md ./

# Runtime: estrutura de pastas (backups/logs vivos ficam no volume)
RUN mkdir -p data/backups data/logs

# .env nao entra na imagem: configuracao 100% via ambiente (docker-compose/-e)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_HOST=0.0.0.0 \
    APP_PORT=8000

EXPOSE 8000

CMD ["python", "run.py"]
