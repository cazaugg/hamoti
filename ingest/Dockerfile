FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY matter_ingest ./matter_ingest

CMD ["python", "-m", "matter_ingest.main"]
