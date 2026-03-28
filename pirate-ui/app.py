#!/usr/bin/env python3
"""
Pirate Audio Line-out 接続状態表示
- ST7789 240x240 ディスプレイに接続状態を表示
- Snapcast JSON-RPC API (port 1780) でサーバー接続状態を取得
- 下部にスクロールテキストを表示
"""

import ST7789
import RPi.GPIO as GPIO
from PIL import Image, ImageDraw, ImageFont
import requests
import socket
import time
import os
import logging
import threading

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log = logging.getLogger(__name__)

# --- 設定 ---
SERVER_HOST   = os.getenv('SERVER_HOST',   'master1.local')
DEVICE_NAME   = os.getenv('DEVICE_NAME',   'satelite01')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '5'))
SCROLL_TEXT   = os.getenv('SCROLL_TEXT',   'Powered by PRESSMANS')
SCROLL_SPEED  = int(os.getenv('SCROLL_SPEED', '3'))   # ピクセル/フレーム

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

SCROLL_H  = 22              # スクロール行の高さ
CONTENT_H = H - SCROLL_H   # コンテンツエリアの高さ

# --- フォント ---
try:
    FONT_L  = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 22)
    FONT_M  = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 18)
    FONT_S  = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 14)
    FONT_SC = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 14)
except IOError:
    FONT_L = ImageFont.load_default()
    FONT_M = FONT_SC = FONT_S = FONT_L

# --- カラー定義 ---
BLACK     = (0,   0,   0)
WHITE     = (255, 255, 255)
GREEN     = (0,   220, 80)
RED       = (220, 50,  50)
GRAY      = (160, 160, 160)
CYAN      = (80,  200, 255)
YELLOW    = (255, 220, 0)
SCROLL_BG = (20,  20,  50)
SCROLL_FG = (255, 200, 50)

# --- 共有状態 ---
current_status = {
    'server_reachable': False,
    'self_connected': False,
    'client_count': 0,
    'volume': None,
}
current_ip  = 'no network'
status_lock = threading.Lock()


def get_local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return 'no network'


def get_snapcast_status() -> dict:
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

        local_ip = get_local_ip()
        for c in all_clients:
            host = c.get('host', {})
            if host.get('name') == DEVICE_NAME or host.get('ip') == local_ip:
                result['self_connected'] = c.get('connected', False)
                vol = c.get('config', {}).get('volume', {})
                result['volume'] = vol.get('percent')
                break

    except requests.exceptions.ConnectionError:
        log.warning('Snapcast server not reachable: %s', SERVER_HOST)
    except Exception as e:
        log.warning('Snapcast API error: %s', e)

    return result


def draw_content(status: dict, ip: str) -> Image.Image:
    """コンテンツエリア（スクロール行を除く上部）を描画"""
    img  = Image.new('RGB', (W, CONTENT_H), BLACK)
    draw = ImageDraw.Draw(img)

    # ヘッダー
    draw.rectangle([(0, 0), (W, 34)], fill=(30, 30, 60))
    draw.text((8, 6), DEVICE_NAME, font=FONT_L, fill=WHITE)

    y = 44

    # サーバー到達性
    if status['server_reachable']:
        dot_color, label = GREEN, 'Server: OK'
    else:
        dot_color, label = RED, 'Server: unreachable'

    draw.ellipse([(8, y+2), (22, y+16)], fill=dot_color)
    draw.text((30, y), label, font=FONT_M, fill=dot_color)
    y += 28

    # 接続状態
    if status['server_reachable']:
        if status['self_connected']:
            sc, sl = GREEN, 'Connected'
        else:
            sc, sl = YELLOW, 'Disconnected'
        draw.ellipse([(8, y+2), (22, y+16)], fill=sc)
        draw.text((30, y), sl, font=FONT_M, fill=sc)
    y += 28

    # クライアント数
    draw.text((8, y), f'Clients: {status["client_count"]}', font=FONT_M, fill=GRAY)
    y += 28

    # 音量バー
    vol = status['volume']
    if vol is not None:
        bar_w = int((W - 16) * vol / 100)
        draw.text((8, y), f'Volume: {vol}%', font=FONT_M, fill=WHITE)
        y += 22
        draw.rectangle([(8, y), (W-8, y+10)], outline=GRAY)
        draw.rectangle([(8, y), (8+bar_w, y+10)], fill=CYAN)
        y += 18
    y += 4

    # サーバーホスト・IP
    draw.text((8, y), f'{SERVER_HOST}', font=FONT_S, fill=GRAY)
    y += 20
    draw.text((8, y), f'IP: {ip}', font=FONT_S, fill=CYAN)

    return img


def draw_scroll_bar(offset: int, unit_width: int) -> Image.Image:
    """スクロールテキストバーを描画"""
    padded = SCROLL_TEXT + '     ' + SCROLL_TEXT + '     '
    img  = Image.new('RGB', (W, SCROLL_H), SCROLL_BG)
    draw = ImageDraw.Draw(img)
    draw.text((-offset, 4), padded, font=FONT_SC, fill=SCROLL_FG)
    return img


def status_updater():
    """別スレッドで定期的にステータスを更新"""
    global current_status, current_ip
    while True:
        try:
            s  = get_snapcast_status()
            ip = get_local_ip()
            with status_lock:
                current_status = s
                current_ip     = ip
            log.info('status=%s ip=%s', s, ip)
        except Exception as e:
            log.error('Status update error: %s', e)
        time.sleep(POLL_INTERVAL)


def show_boot_screen():
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

    # スクロールテキスト1ループ分の幅を計算
    tmp_img  = Image.new('RGB', (2000, SCROLL_H))
    tmp_draw = ImageDraw.Draw(tmp_img)
    bbox = tmp_draw.textbbox((0, 0), SCROLL_TEXT + '     ', font=FONT_SC)
    unit_width = bbox[2]

    # ステータス更新スレッド起動
    t = threading.Thread(target=status_updater, daemon=True)
    t.start()

    offset = 0

    while True:
        try:
            with status_lock:
                s  = current_status.copy()
                ip = current_ip

            content_img = draw_content(s, ip)
            scroll_img  = draw_scroll_bar(offset, unit_width)

            full_img = Image.new('RGB', (W, H), BLACK)
            full_img.paste(content_img, (0, 0))
            full_img.paste(scroll_img,  (0, CONTENT_H))

            disp.display(full_img)

            offset = (offset + SCROLL_SPEED) % unit_width

        except Exception as e:
            log.error('Display error: %s', e)

        time.sleep(0.05)   # 約20fps