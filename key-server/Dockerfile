FROM python:3.11-slim

WORKDIR /app

# Install requirements first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code.
COPY key_server.py keymgr.py ./

# Create data directory with restricted permissions.
RUN mkdir -p /data && chmod 700 /data

EXPOSE 7443

CMD ["uvicorn", "key_server:app", "--host", "0.0.0.0", "--port", "7443"]