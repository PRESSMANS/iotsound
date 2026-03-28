FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    mpd \
    mpc \
    cifs-utils \
    inotify-tools \
    libavcodec58 \
    libavformat58 \
    && rm -rf /var/lib/apt/lists/*

COPY mpd.conf /etc/mpd.conf
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

CMD ["/usr/local/bin/start.sh"]
