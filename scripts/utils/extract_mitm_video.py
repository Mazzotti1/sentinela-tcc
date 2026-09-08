#!/usr/bin/env python3
"""
Remonta o vídeo (MJPG) e o áudio (G711) a partir de uma captura pcap do
stream da câmera Naxclow/V720.

Protocolo (little-endian), header de 20 bytes por pacote:
    len(4) cmd(2) msg_flag(1) deal_flag(1) forward_id(8) pkg_id(4) | payload

cmd:       1 = JPEG (vídeo), 4 = G711 (áudio), 0 = JSON, 100 = heartbeat
msg_flag:  250 HEAD, 251 BODY, 252 END, 255 FINISH (frame completo num só pacote)

Um frame JPEG completo = concatenar payloads HEAD..BODY..END. No END os
últimos 5 bytes são trailer (1 flag + 4 tamanho LE), descartados.

Uso:
    python3 extract_mitm_video.py live-tcp.pcapng [--out saida]
Requer: scapy. Gera <out>/frames/*.jpg, <out>/video.avi (se cv2), audio_g711.raw
"""
import struct
import sys
import os
import glob

from scapy.all import rdpcap, TCP, IP

HDR_FMT = '<LHBB8sL'
HDR_LEN = struct.calcsize(HDR_FMT)  # 20

CMD_JPEG = 1
CMD_G711 = 4
FLAG_HEAD, FLAG_BODY, FLAG_END, FLAG_FINISH = 250, 251, 252, 255

CAM_IP = '192.168.169.1'   # câmera em modo AP
CAM_PORT = 6123


def reassemble_tcp(pkts, cam_ip=CAM_IP):
    """Remonta os byte-streams TCP em que `cam_ip` é a ORIGEM e devolve o
    stream (concatenado, ordenado por seq) que contém frames JPEG.

    Em AP a câmera emite na porta 6123; em STA ela fala com o cloud em portas
    variáveis (29942, 1883, ...). Por isso não filtramos por porta: agrupamos
    por fluxo TCP (5-tupla com a câmera como origem), remontamos cada fluxo e
    escolhemos o(s) que carregam o marcador SOI JPEG (FF D8 FF).
    """
    flows = {}   # (sport, dst, dport) -> {seq: payload}
    for p in pkts:
        if not (p.haslayer(TCP) and p.haslayer(IP)):
            continue
        ip, tcp = p[IP], p[TCP]
        if ip.src != cam_ip:              # só o sentido câmera -> cliente/cloud
            continue
        payload = bytes(tcp.payload)
        if not payload:
            continue
        key = (tcp.sport, ip.dst, tcp.dport)
        flows.setdefault(key, {})[tcp.seq] = payload

    out = bytearray()
    for key, segs in flows.items():
        stream = bytearray()
        for seq in sorted(segs):
            stream.extend(segs[seq])
        if b'\xff\xd8\xff' in stream:     # fluxo com vídeo
            out.extend(stream)
    if out:
        return bytes(out)
    # nenhum fluxo com JPEG: devolve tudo (control channel) para inspeção
    for key, segs in flows.items():
        for seq in sorted(segs):
            out.extend(segs[seq])
    return bytes(out)


def parse_frames(stream):
    """Percorre o stream, devolve (jpeg_frames, g711_chunks).

    Firmware AP (202601081657): cada frame JPEG chega fragmentado em N chunks
    TCP. Cada chunk leva o header de 20 bytes com cmd=1 e len<=1400. O byte
    FFD8FFD8 (SOI JPEG) só aparece no primeiro chunk de cada frame, por isso
    usamos o SOI como fronteira de frame: fecha o anterior, começa o novo.
    (O msg_flag 250/252 documentado no path STA não aparece neste firmware AP.)
    """
    jpegs, g711 = [], []
    cur = bytearray()
    off, n = 0, len(stream)
    while off + HDR_LEN <= n:
        plen, cmd = struct.unpack('<LH', stream[off:off + 6])
        if cmd == CMD_JPEG and 0 < plen <= 1400 and off + HDR_LEN + plen <= n:
            body = stream[off + HDR_LEN:off + HDR_LEN + plen]
            if body[:3] == b'\xff\xd8\xff':      # início de um novo frame
                if cur:
                    jpegs.append(bytes(cur))
                cur = bytearray(body)
            else:
                cur.extend(body)
            off += HDR_LEN + plen
        elif cmd == CMD_G711 and 0 < plen <= 1400 and off + HDR_LEN + plen <= n:
            g711.append(bytes(stream[off + HDR_LEN:off + HDR_LEN + plen]))
            off += HDR_LEN + plen
        else:
            # header dessincronizado (perda de pacote no ar); avança 1 byte
            off += 1
    if cur:
        jpegs.append(bytes(cur))
    return jpegs, g711


def salvage_jpegs(stream):
    """Fallback: extrai JPEGs por marcadores FFD8..FFD9, ignora protocolo."""
    frames = []
    i = 0
    while True:
        start = stream.find(b'\xff\xd8\xff', i)
        if start == -1:
            break
        end = stream.find(b'\xff\xd9', start + 3)
        if end == -1:
            break
        frames.append(stream[start:end + 2])
        i = end + 2
    return frames


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    pcap = sys.argv[1]
    out = 'mitm_out'
    if '--out' in sys.argv:
        out = sys.argv[sys.argv.index('--out') + 1]
    cam_ip = CAM_IP
    if '--cam-ip' in sys.argv:
        cam_ip = sys.argv[sys.argv.index('--cam-ip') + 1]

    print(f'[*] a ler {pcap} ...')
    pkts = rdpcap(pcap)
    print(f'[*] {len(pkts)} pacotes')

    stream = reassemble_tcp(pkts, cam_ip)
    print(f'[*] stream TCP camera->cliente: {len(stream)} bytes')

    jpegs, g711 = parse_frames(stream)
    if not jpegs:
        print('[!] parse por protocolo achou 0 frames; a tentar salvage FFD8/FFD9')
        jpegs = salvage_jpegs(stream)

    frames_dir = os.path.join(out, 'frames')
    os.makedirs(frames_dir, exist_ok=True)
    # limpa frames antigos
    for f in glob.glob(os.path.join(frames_dir, '*.jpg')):
        os.remove(f)

    good = 0
    for idx, fr in enumerate(jpegs):
        if fr[:2] != b'\xff\xd8':          # só JPEGs válidos
            continue
        with open(os.path.join(frames_dir, f'frame_{good:05d}.jpg'), 'wb') as fp:
            fp.write(fr)
        good += 1
    print(f'[+] {good} frames JPEG gravados em {frames_dir}/')

    if g711:
        raw = os.path.join(out, 'audio_g711.raw')
        with open(raw, 'wb') as fp:
            for c in g711:
                fp.write(c)
        print(f'[+] audio G711 (u-law) em {raw} '
              f'({sum(len(c) for c in g711)} bytes) '
              f'-> ffmpeg -f mulaw -ar 8000 -ac 1 -i {raw} audio.wav')

    # monta AVI se cv2 disponível
    try:
        import cv2
        import numpy as np
        files = sorted(glob.glob(os.path.join(frames_dir, '*.jpg')))
        if files:
            img0 = cv2.imread(files[0])
            h, w = img0.shape[:2]
            vid = os.path.join(out, 'video.avi')
            vw = cv2.VideoWriter(vid, cv2.VideoWriter_fourcc(*'MJPG'), 15, (w, h))
            for f in files:
                im = cv2.imread(f)
                if im is not None:
                    vw.write(im)
            vw.release()
            print(f'[+] video remontado: {vid} ({w}x{h}, {len(files)} frames @15fps)')
    except ImportError:
        print('[i] cv2 ausente: frames JPG prontos; junta com '
              f'`ffmpeg -framerate 15 -i {frames_dir}/frame_%05d.jpg {out}/video.mp4`')


if __name__ == '__main__':
    main()
