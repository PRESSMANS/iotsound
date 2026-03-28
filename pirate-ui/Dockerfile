FROM python:3.11-slim-bullseye

RUN apt-get update && apt-get install -y \
    gcc \
    python3-dev \
    libgpiod2 \
    fonts-dejavu-core \
    libjpeg-dev \
    zlib1g-dev \
    libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    "pillow>=10.0.0" \
    st7789==0.0.4 \
    RPi.GPIO \
    requests

WORKDIR /app
COPY app.py .

CMD ["python", "-u", "app.py"]
