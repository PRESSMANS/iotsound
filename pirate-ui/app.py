#!/usr/bin/env python3
import os, sys
if os.environ.get("SOUND_DISABLE_PIRATE_UI"):
    print("Pirate UI is disabled, exiting...")
    sys.exit(0)

import ST7789
import RPi.GPIO as GPIO
from PIL import Image, ImageDraw, ImageFont
import requests
import socket
import time
import datetime
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log = logging.getLogger(__name__)

SERVER_HOST   = os.getenv('SERVER_HOST',   'master1.local')
DEVICE_NAME   = os.getenv('DEVICE_NAME',   'satelite01')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '5'))
MPD_PORT      = int(os.getenv('MPD_PORT', '6600'))

disp = ST7789.ST7789(
    rotation=90, port=0, cs=1, dc=9,
    backlight=13, spi_speed_hz=80 * 1000 * 1000
)
W, H = disp.width, disp.height  # 240 x 240

FOOTER_H  = 22
CONTENT_H = H - FOOTER_H

# フォント（日本語対応）
NOTO = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
DEJA_BOLD = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
DEJA      = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
DEJA_SB   = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'

def load_font(path, size, fallback=None):
    try:
        return ImageFont.truetype(path, size)
    except IOError:
        if fallback:
            try:
                return ImageFont.truetype(fallback, size)
            except IOError:
                pass
        return ImageFont.load_default()

FONT_DATE   = load_font(DEJA_BOLD, 16)
FONT_TIME   = load_font(DEJA_BOLD, 28)
FONT_IP     = load_font(DEJA, 13)
FONT_STATUS = load_font(DEJA, 16)
FONT_TITLE  = load_font(NOTO, 16, DEJA_BOLD)
FONT_ARTIST = load_font(NOTO, 14, DEJA)
FONT_S      = load_font(DEJA, 13)
FONT_SB     = load_font(DEJA_SB, 13)

BLACK     = (0,   0,   0)
WHITE     = (255, 255, 255)
GREEN     = (0,   220, 80)
RED       = (220, 50,  50)
GRAY      = (160, 160, 160)
CYAN      = (80,  200, 255)
YELLOW    = (255, 220, 0)
FOOTER_BG = (20,  20,  50)
FOOTER_FG = (255, 200, 50)
TITLE_COLOR  = (255, 255, 100)
ARTIST_COLOR = (180, 220, 255)


def get_local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return 'no network'


def get_mpd_current_song() -> dict:
    result = {'title': None, 'artist': None, 'filename': None}
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect((SERVER_HOST, MPD_PORT))
        s.recv(256)
        s.send(b'currentsong\n')
        data = s.recv(4096).decode('utf-8', errors='replace')
        s.send(b'close\n')
        s.close()
        for line in data.splitlines():
            if ':' in line:
                key, _, val = line.partition(':')
                key = key.strip().lower()
                val = val.strip()
                if key == 'title':
                    result['title'] = val
                elif key == 'artist':
                    result['artist'] = val
                elif key == 'file':
                    result['filename'] = os.path.basename(val)
    except Exception as e:
        log.debug('MPD error: %s', e)
    return result


def get_snapcast_status() -> dict:
    result = {
        'server_reachable': False,
        'self_connected': False,
        'title': None,
        'artist': None,
        'filename': None,
    }
    try:
        resp = requests.post(
            f'http://{SERVER_HOST}:1780/jsonrpc',
            json={'id': 1, 'jsonrpc': '2.0', 'method': 'Server.GetStatus'},
            timeout=3
        )
        data = resp.json()
        result['server_reachable'] = True
        groups = data.get('result', {}).get('server', {}).get('groups', [])
        all_clients = [c for g in groups for c in g.get('clients', [])]
        local_ip = get_local_ip()
        for c in all_clients:
            host = c.get('host', {})
            if host.get('name') == DEVICE_NAME or host.get('ip') == local_ip:
                result['self_connected'] = c.get('connected', False)
                break
    except requests.exceptions.ConnectionError:
        log.warning('Snapcast server not reachable: %s', SERVER_HOST)
    except Exception as e:
        log.warning('Snapcast API error: %s', e)

    if result['server_reachable']:
        mpd_info = get_mpd_current_song()
        result.update(mpd_info)

    return result


class Scroller:
    def __init__(self, speed=2):
        self.speed = speed
        self._text = ''
        self._offset = 0
        self._text_w = 0
        self._pause = 0

    def set_text(self, text: str, draw: ImageDraw, font):
        if text != self._text:
            self._text = text
            bbox = draw.textbbox((0, 0), text, font=font)
            self._text_w = bbox[2] - bbox[0]
            self._offset = 0
            self._pause = 30

    def draw_scrolled(self, draw, font, y, color, margin=8):
        text_area = W - margin * 2
        if self._text_w <= text_area:
            draw.text((margin, y), self._text, font=font, fill=color)
            return
        if self._pause > 0:
            self._pause -= 1
            draw.text((margin, y), self._text, font=font, fill=color)
            return
        x = margin - self._offset
        draw.text((x, y), self._text, font=font, fill=color)
        self._offset += self.speed
        if self._offset > self._text_w + text_area:
            self._offset = 0
            self._pause = 30


title_scroller  = Scroller(speed=2)
artist_scroller = Scroller(speed=2)


def draw_screen(status: dict, ip: str):
    img  = Image.new('RGB', (W, H), BLACK)
    draw = ImageDraw.Draw(img)

    now = datetime.datetime.now()
    # AM/PM 形式
    hour = now.hour
    ampm = 'am' if hour < 12 else 'pm'
    hour12 = hour % 12 or 12
    date_str = now.strftime('%Y-%m-%d')
    time_str = f'{ampm} {hour12:02d}:{now.strftime("%M")}'

    y = 4

    # 日付（小さめ）
    draw.text((8, y), date_str, font=FONT_DATE, fill=GRAY)
    y += 20

    # 時刻（大きめ）
    draw.text((8, y), time_str, font=FONT_TIME, fill=WHITE)
    y += 36

    # 区切り線
    draw.line([(0, y), (W, y)], fill=(40, 40, 60), width=1)
    y += 6

    # サーバーIP と 自身のIP
    draw.text((8, y), f'Server: {SERVER_HOST}', font=FONT_IP, fill=GRAY)
    y += 18
    draw.text((8, y), f'IP: {ip}', font=FONT_IP, fill=CYAN)
    y += 18

    # 区切り線
    draw.line([(0, y), (W, y)], fill=(40, 40, 60), width=1)
    y += 6

    # サーバー到達性・接続状態
    if status['server_reachable']:
        dot_color, label = GREEN, 'Server: OK'
    else:
        dot_color, label = RED, 'Server: unreachable'
    draw.ellipse([(8, y+2), (20, y+14)], fill=dot_color)
    draw.text((26, y), label, font=FONT_STATUS, fill=dot_color)
    y += 22

    if status['server_reachable']:
        if status['self_connected']:
            sc, sl = GREEN, 'Connected'
        else:
            sc, sl = YELLOW, 'Disconnected'
        draw.ellipse([(8, y+2), (20, y+14)], fill=sc)
        draw.text((26, y), sl, font=FONT_STATUS, fill=sc)
    y += 22

    # 区切り線
    draw.line([(0, y), (W, y)], fill=(40, 40, 60), width=1)
    y += 6

    # 曲名・アーティスト（スクロール）Powered by の直上
    title   = status.get('title')
    artist  = status.get('artist')
    fname   = status.get('filename')

    display_title  = title or fname or '-- No track info --'
    display_artist = artist or ''

    title_scroller.set_text(display_title, draw, FONT_TITLE)
    artist_scroller.set_text(display_artist, draw, FONT_ARTIST)

    # Powered by の直上に配置（下から逆算）
    track_y = CONTENT_H - 42
    title_scroller.draw_scrolled(draw, FONT_TITLE, track_y, TITLE_COLOR)
    artist_scroller.draw_scrolled(draw, FONT_ARTIST, track_y + 20, ARTIST_COLOR)

    # フッター
    draw.rectangle([(0, CONTENT_H), (W, H)], fill=FOOTER_BG)
    text1 = 'Powered by '
    text2 = 'PRESSMANS'
    bbox1 = draw.textbbox((0, 0), text1, font=FONT_S)
    bbox2 = draw.textbbox((0, 0), text2, font=FONT_SB)
    total_w = (bbox1[2] - bbox1[0]) + (bbox2[2] - bbox2[0])
    x_start = W - total_w - 8
    fy = CONTENT_H + 4
    draw.text((x_start, fy), text1, font=FONT_S,  fill=FOOTER_FG)
    draw.text((x_start + (bbox1[2] - bbox1[0]), fy), text2, font=FONT_SB, fill=WHITE)

    disp.display(img)


def show_boot_screen():
    img  = Image.new('RGB', (W, H), (20, 20, 40))
    draw = ImageDraw.Draw(img)
    draw.text((W//2 - 60, H//2 - 20), 'Starting...', font=FONT_TIME, fill=WHITE)
    draw.text((8, H - 24), DEVICE_NAME, font=FONT_S, fill=GRAY)
    disp.display(img)


if __name__ == '__main__':
    log.info('pirate-ui starting. device=%s server=%s', DEVICE_NAME, SERVER_HOST)
    show_boot_screen()
    time.sleep(2)

    ip = get_local_ip()
    last_status_time = 0
    status = {
        'server_reachable': False,
        'self_connected': False,
        'title': None,
        'artist': None,
        'filename': None,
    }

    while True:
        try:
            now = time.time()
            if now - last_status_time >= POLL_INTERVAL:
                status = get_snapcast_status()
                ip = get_local_ip()
                last_status_time = now
                log.info('status=%s ip=%s', status, ip)
            draw_screen(status, ip)
        except Exception as e:
            log.error('Unexpected error: %s', e)
        time.sleep(0.1)
