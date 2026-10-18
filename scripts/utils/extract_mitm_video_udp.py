#!/usr/bin/env python3
"""
Remonta vídeo (JPEG) e áudio (PCM/G711) do stream UDP da câmera Naxclow/V720
capturado em modo STA (câmera -> relay/cloud).

Protocolo (little-endian), header de 20 bytes por datagrama UDP:
    len(4) cmd(2) msg_flag(1) deal_flag(1) forward_id(8) pkg_id(4) | payload

cmd:       1 = JPEG, 6 = PCM, 4 = G711, 0 = JSON, 100 = heartbeat
msg_flag:  250 HEAD, 251 BODY, 252 END, 255 FINISH (frame inteiro)

Uso:
    python3 extract_mitm_video_udp.py <pcap> --out <dir> --cam-ip <ip>
"""
import struct
import sys
import os
import glob

from scapy.all import rdpcap, UDP, IP

HDR_FMT = '<LHBB8sL'
HDR_LEN = struct.calcsize(HDR_FMT)

CMD_JPEG = 1
CMD_PCM = 6
CMD_G711 = 4
FLAG_HEAD, FLAG_BODY, FLAG_END, FLAG_FINISH = 250, 251, 252, 255


def parse_udp(pkts, cam_ip):
    """Remonta frames JPEG por msg_flag, em ordem de chegada dos datagramas."""
    jpegs, audio = [], []
    cur = bytearray()
    seen = set()
    for p in pkts:
        if not (p.haslayer(UDP) and p.haslayer(IP)):
            continue
        ip, udp = p[IP], p[UDP]
        if ip.src != cam_ip:
            continue
        data = bytes(udp.payload)
        if len(data) < HDR_LEN:
            continue
        plen, cmd, msg, deal, fwd, pkg = struct.unpack(HDR_FMT, data[:HDR_LEN])
        if plen <= 0 or HDR_LEN + plen > len(data):
            continue
        body = data[HDR_LEN:HDR_LEN + plen]
        if cmd in (CMD_PCM, CMD_G711):
            audio.append(body)
            continue
        if cmd != CMD_JPEG:
            continue
        if msg == FLAG_HEAD:
            if cur:
                jpegs.append(bytes(cur))
            cur = bytearray(body)
            seen = {pkg}
        elif msg == FLAG_BODY:
            if pkg not in seen:
                cur.extend(body)
                seen.add(pkg)
        elif msg == FLAG_END:
            if pkg not in seen:
                body = body[:-5] if len(body) >= 5 else body
                cur.extend(body)
                seen.add(pkg)
            jpegs.append(bytes(cur))
            cur = bytearray()
            seen = set()
        elif msg == FLAG_FINISH:
            jpegs.append(bytes(body))
            cur = bytearray()
            seen = set()
    if cur:
        jpegs.append(bytes(cur))
    return jpegs, audio


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    pcap = sys.argv[1]
    out = 'mitm_out_udp'
    cam_ip = '192.168.0.17'
    if '--out' in sys.argv:
        out = sys.argv[sys.argv.index('--out') + 1]
    if '--cam-ip' in sys.argv:
        cam_ip = sys.argv[sys.argv.index('--cam-ip') + 1]

    print(f'[*] a ler {pcap} ...')
    pkts = rdpcap(pcap)
    print(f'[*] {len(pkts)} pacotes')

    jpegs, audio = parse_udp(pkts, cam_ip)
    print(f'[*] {len(jpegs)} frames JPEG, {len(audio)} chunks de audio')

    frames_dir = os.path.join(out, 'frames')
    os.makedirs(frames_dir, exist_ok=True)
    for f in glob.glob(os.path.join(frames_dir, '*.jpg')):
        os.remove(f)

    good = 0
    for fr in jpegs:
        if fr[:2] != b'\xff\xd8':
            continue
        with open(os.path.join(frames_dir, f'frame_{good:05d}.jpg'), 'wb') as fp:
            fp.write(fr)
        good += 1
    print(f'[+] {good} frames JPEG gravados em {frames_dir}/')

    if audio:
        raw = os.path.join(out, 'audio_pcm.raw')
        with open(raw, 'wb') as fp:
            for c in audio:
                fp.write(c)
        print(f'[+] audio em {raw} ({sum(len(c) for c in audio)} bytes)')

    try:
        import cv2
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
        print(f'[i] cv2 ausente: junta com '
              f'`ffmpeg -framerate 15 -i {frames_dir}/frame_%05d.jpg {out}/video.mp4`')


if __name__ == '__main__':
    main()
