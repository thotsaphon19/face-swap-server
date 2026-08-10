FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libsm6 libxext6 libxrender1 libgl1 build-essential nginx \
 && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt /app/backend/requirements.txt
RUN pip install --upgrade pip setuptools wheel
RUN pip install -r /app/backend/requirements.txt

# copy code
COPY backend /app/backend
COPY frontend /app/frontend

# nginx config will be mounted/copied later via docker-compose
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf

# expose ports
EXPOSE 80
EXPOSE 8000

# Start: run uvicorn + nginx via simple supervisor-ish script
COPY deploy/start_container.sh /app/start_container.sh
RUN chmod +x /app/start_container.sh

CMD ["/app/start_container.sh"]