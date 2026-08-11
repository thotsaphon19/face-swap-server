FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ffmpeg libsm6 libxext6 libxrender1 libgl1 build-essential nginx \
 && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip setuptools wheel
RUN pip install -r /tmp/requirements.txt

COPY backend /app/backend
COPY frontend /app/frontend
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY deploy/start_container.sh /app/start_container.sh
RUN chmod +x /app/start_container.sh

ENV APP_ROLE=control-plane
ENV ENABLE_NGINX=true
ENV WORKER_PORT=8000
ENV UVICORN_WORKERS=1

EXPOSE 80
EXPOSE 8000

CMD ["/app/start_container.sh"]