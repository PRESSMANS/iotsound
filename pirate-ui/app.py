#!/usr/bin/env python3
"""
Pirate Audio Line-out 接続状態表示
- ST7789 240x240 ディスプレイに接続状態を表示
- Snapcast JSON-RPC API (port 1780) でサーバー接続状態を取得
"""

import ST7789
import RPi.GPIO as GPIO
from PIL import Image, ImageDraw, ImageFont
import requests
import socket
import time
import os
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log = logging.getLogger(__name__)

# --- 設定 ---
SERVER_HOST  = os.getenv('SERVER_HOST',  'master1.local')
DEVICE_NAME  = os.getenv('DEVICE_NAME',  'satelite01')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '5'))   # 秒

# --- ディスプレイ初期化 ---
disp = ST7789.ST7789(
    rotation=90,
    port=0,
    cs=1,
    dc=9,
    backlight=13,
    spi_speed_hz=80 * 1000 * 1000
)
W, H = disp.width, disp.height   # 240 x 240

# --- フォント ---
try:
    FONT_L = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 22)
    FONT_M = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 18)
    FONT_S = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 14)
except IOError:
    FONT_L = ImageFont.load_default()
    FONT_M = FONT_L
    FONT_S = FONT_L

# --- カラー定義 ---
BLACK   = (0,   0,   0)
WHITE   = (255, 255, 255)
GREEN   = (0,   220, 80)
RED     = (220, 50,  50)
GRAY    = (160, 160, 160)
CYAN    = (80,  200, 255)
YELLOW  = (255, 220, 0)


def get_local_ip() -> str:
    """自デバイスのIPアドレスを取得"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return 'no network'


def get_snapcast_status() -> dict:
    """
    Snapcast JSON-RPC API で接続状態を取得
    戻り値: {
        'server_reachable': bool,
        'self_connected': bool,
        'client_count': int,
        'volume': int or None,
    }
    """
    result = {
        'server_reachable': False,
        'self_connected': False,
        'client_count': 0,
        'volume': None,
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
        result['client_count'] = sum(1 for c in all_clients if c.get('connected'))

        for c in all_clients:
            host = c.get('host', {})
            # ホスト名またはIPで自分を特定
            if host.get('name') == DEVICE_NAME or host.get('ip') == get_local_ip():
                result['self_connected'] = c.get('connected', False)
                vol = c.get('config', {}).get('volume', {})
                result['volume'] = vol.get('percent')
                break

    except requests.exceptions.ConnectionError:
        log.warning('Snapcast server not reachable: %s', SERVER_HOST)
    except Exception as e:
        log.warning('Snapcast API error: %s', e)

    return result


def draw_screen(status: dict, ip: str):
    """ディスプレイに状態を描画"""
    img  = Image.new('RGB', (W, H), BLACK)
    draw = ImageDraw.Draw(img)

    # ---- ヘッダー ----
    draw.rectangle([(0, 0), (W, 34)], fill=(30, 30, 60))
    draw.text((8, 6), DEVICE_NAME, font=FONT_L, fill=WHITE)

    y = 44

    # ---- サーバー到達性 ----
    if status['server_reachable']:
        dot_color = GREEN
        label     = 'Server: OK'
    else:
        dot_color = RED
        label     = 'Server: unreachable'

    draw.ellipse([(8, y+2), (22, y+16)], fill=dot_color)
    draw.text((30, y), label, font=FONT_M, fill=dot_color)
    y += 28

    # ---- 自分の接続状態 ----
    if status['server_reachable']:
        if status['self_connected']:
            sc = GREEN
            sl = 'Connected'
        else:
            sc = YELLOW
            sl = 'Disconnected'
        draw.ellipse([(8, y+2), (22, y+16)], fill=sc)
        draw.text((30, y), sl, font=FONT_M, fill=sc)
    y += 28

    # ---- クライアント数 ----
    draw.text((8, y), f'Clients: {status["client_count"]}', font=FONT_M, fill=GRAY)
    y += 28

    # ---- 音量 ----
    vol = status['volume']
    if vol is not None:
        bar_w = int((W - 16) * vol / 100)
        draw.text((8, y), f'Volume: {vol}%', font=FONT_M, fill=WHITE)
        y += 22
        draw.rectangle([(8, y), (W-8, y+10)], outline=GRAY)
        draw.rectangle([(8, y), (8+bar_w, y+10)], fill=CYAN)
        y += 18
    y += 4

    # ---- サーバーホスト ----
    draw.text((8, y), f'{SERVER_HOST}', font=FONT_S, fill=GRAY)
    y += 20

    # ---- 自分のIP ----
    draw.text((8, y), f'IP: {ip}', font=FONT_S, fill=CYAN)

    disp.display(img)


def show_boot_screen():
    """起動時の初期画面"""
    img  = Image.new('RGB', (W, H), (20, 20, 40))
    draw = ImageDraw.Draw(img)
    draw.text((W//2 - 60, H//2 - 20), 'Starting...', font=FONT_L, fill=WHITE)
    draw.text((8, H - 24), DEVICE_NAME, font=FONT_S, fill=GRAY)
    disp.display(img)


# --- メインループ ---
if __name__ == '__main__':
    log.info('pirate-ui starting. device=%s server=%s', DEVICE_NAME, SERVER_HOST)
    show_boot_screen()
    time.sleep(2)

    ip = get_local_ip()

    while True:
        try:
            status = get_snapcast_status()
            # IPは変わることがあるので毎回取得
            ip = get_local_ip()
            draw_screen(status, ip)
            log.info('status=%s ip=%s', status, ip)
        except Exception as e:
            log.error('Unexpected error: %s', e)
        time.sleep(POLL_INTERVAL)