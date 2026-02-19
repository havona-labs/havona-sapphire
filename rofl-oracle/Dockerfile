FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY oracle.py .

# ROFL runtime injects secrets as env vars at container start.
CMD ["python", "oracle.py"]
