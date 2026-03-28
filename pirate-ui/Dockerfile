FROM python:3.11-slim-bullseye

RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    python3-dev \
    libgpiod2 \
    fonts-dejavu-core \
    libjpeg-dev \
    zlib1g-dev \
    libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    "numpy<2.0" \
    "pillow>=10.0.0" \
    spidev \
    st7789==0.0.4 \
    RPi.GPIO \
    requests

WORKDIR /app
COPY app.py .

CMD ["python", "-u", "app.py"]
