FROM python:3.11-slim-bullseye

# システムパッケージ
RUN apt-get update && apt-get install -y \
    gcc \
    python3-dev \
    libgpiod2 \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Pythonパッケージ
RUN pip install --no-cache-dir \
    pillow \
    st7789==0.0.4 \
    RPi.GPIO \
    requests

WORKDIR /app
COPY app.py .

CMD ["python", "-u", "app.py"]
