FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY matter_ingest ./matter_ingest
# The schema and cluster registry are applied by the ingest at startup (see
# store.py) so they do not depend on TimescaleDB's init dir or the repository
# being present at deploy.
COPY schema.sql ./schema.sql
COPY cluster_seed.sql ./cluster_seed.sql

CMD ["python", "-m", "matter_ingest.main"]
