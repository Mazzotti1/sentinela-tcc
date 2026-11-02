#!/usr/bin/env python3

from netcl_tcp import netcl_tcp
import time
import os
import argparse
from datetime import datetime
from tqdm.auto import tqdm
from log import log
import logging

from v720_ap import v720_ap
from v720_sta import start_srv

from a9_live import show_live


HOST = "192.168.169.1"
PORT = 6123


def print_filelist(cam):
    dates = cam.sdcard_datelist()
    if not dates:
        print('Nenhuma data/listagem recebida do SD card')
        return
    for date in dates:
        time.sleep(0.5)
        print(f'Files @ {date}:')
        for file in cam.filename_list(date):
            finfo = cam.avi_file_info(date, file[0], file[1])
            if finfo is not None:
                print(
                    f'\t\t-{file[0]:02d}:{file[1]:02d}: Filename: {finfo.get("fileName")}, Size: {finfo.get("fileSize")}')
            else:
                print(
                    f'\t\t-{file[0]:02d}:{file[1]:02d}: Could not get file info')


def download(cam, file, date, hour, min, total_sz=0):
    _pb = tqdm(range(0, total_sz), unit='B',
               unit_scale=True, unit_divisor=1024)

    def _on_rcv(id, sz):
        _pb.update(sz)

    ret = cam.get_file(date, hour, min, _on_rcv, expected_sz=total_sz or None)
    if ret is None or ret[1] is None:
        msg = ret[0] if ret is not None else None
        print(f'Download failed. Response: {msg}')
        return (0, msg)
    data = bytes(ret[1])
    if total_sz and len(data) > total_sz:
        data = data[:total_sz]
    with open(file, 'wb') as avi:
        avi.write(data)
    return(len(data), ret[0])


def dump_all(cam, outdir):
    dates = cam.sdcard_datelist()
    if not dates:
        print('Nenhuma data/listagem recebida do SD card')
        return
    os.makedirs(outdir, exist_ok=True)
    n_ok = 0
    n_empty = 0
    n_fail = 0
    total = 0
    for date in dates:
        entries = cam.filename_list(date) or ()
        print(f'[{date}] {len(entries)} segmento(s)')
        for hour, minute in entries:
            info = cam.avi_file_info(date, hour, minute) or {}
            size = info.get('fileSize')
            name = info.get('fileName') or f'{date}{hour:02d}{minute:02d}'
            if size is None or size <= 1:
                print(f'  {hour:02d}:{minute:02d} vazio (fileSize={size}) - pulando')
                n_empty += 1
                continue
            dest = os.path.join(outdir, f'{name}.avi')
            print(f'  {hour:02d}:{minute:02d} -> {dest} ({size} bytes)')
            got, _ = download(cam, dest, date, hour, minute, size)
            if got > 0:
                n_ok += 1
                total += got
            else:
                n_fail += 1
            time.sleep(0.3)
    print(f'Dump concluido: {n_ok} ok, {n_fail} falha(s), {n_empty} vazio(s), {total} bytes em {outdir}')


def parse_dt(s: str):
    if s is None:
        raise AttributeError('Empty date')
    s = s.split('-', 3)
    if len(s) == 0:
        raise AttributeError('Wrong date')

    if len(s) == 1 and len(s[0]) == len("202302101314"):
        return (int(s[0][:8]),
                int(s[0][8:10]),
                int(s[0][10:]))
    else:
        return (
            int(s[0]),
            int(s[1]) if len(s) > 1 else datetime.now().hour,
            int(s[2]) if len(s) > 2 else datetime.now().minute - 2
        )


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    arg_gr = parser.add_mutually_exclusive_group(required=True)
    arg_gr.add_argument('-d', '--download', type=str, help='Download file with provided datetime. Format: [date]-[hour]-[miute], example: 20230131-22-29')
    arg_gr.add_argument('-f', '--filelist', action="store_true", help='List available files (recorded date\'s and time\'s)')
    arg_gr.add_argument('--dump', action="store_true", help='Download ALL recorded video segments from the SD card into a folder (-o or results/sdcard_dump)')
    arg_gr.add_argument('-l', '--live', action="store_true", help='Show live stream')
    arg_gr.add_argument('-s', '--server', action='store_true', help='Start a fake-server', default=False)
    arg_gr.add_argument('--set-wifi', nargs=2, help='Try to connect to specified AP (--set-wifi AP PWD)')
    parser.add_argument('-o', '--output', type=str, help='Output filename', default=None)
    parser.add_argument('-i', '--irled', action='store_true', help='Enable IR led(lens)', default=False)
    parser.add_argument('-r', '--flip', action='store_true', help='Flip camera', default=False)
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable debug logs', default=False)
    parser.add_argument('--proxy-port', type=int, help='HTTP server port, use for proxying it via NGINX, etc', default=80)
    parser.add_argument('-c', '--host', type=str, help='Host and port (192.168.169.1:6123)', default=f"{HOST}:{PORT}")

    args = parser.parse_args()

    if not args.verbose:
        log.set_log_lvl(logging.WARN)

    if args.server:
        print(f'''-------- A9 V720 fake-server starting. --------
\033[92mDevice list: http://127.0.0.1:{args.proxy_port}/dev/list
Live capture: http://127.0.0.1:{args.proxy_port}/dev/[CAM-ID]/live
Audio capture: http://127.0.0.1:{args.proxy_port}/dev/[CAM-ID]/audio
Snapshot: http://127.0.0.1:{args.proxy_port}/dev/[CAM-ID]/snapshot\033[0m
''')
        start_srv(args.proxy_port)
    else:
        host = args.host.split(':', 2)
        port = PORT if len(host) == 1 else int(host[1])

        with netcl_tcp(host[0], port) as sock:
            cam = v720_ap(sock)
            cam.init_live_motion()

            sd_status = cam.sdcard_status()
            if sd_status is None:
                print('AVISO: status do SD desconhecido (resposta de firmware diferente) - seguindo mesmo assim')
            elif sd_status is False:
                print('Camera reporta: sem SD card')

            if args.filelist:
                print_filelist(cam)
            elif args.dump:
                dump_all(cam, args.output or 'results/sdcard_dump')
            elif args.download:
                dt = parse_dt(args.download)
                file_info = cam.avi_file_info(dt[0], dt[1], dt[2])
                if file_info is None or file_info.get('fileSize', -1) == -1:
                    print(f'File {dt[0]}-{dt[1]}-{dt[2]} not found')
                    exit(1)

                output = args.output
                if output is None:
                    output = f"{file_info.get('fileName', f'{dt[0]}-{dt[1]}-{dt[2]}')}.avi"

                print('Found file @', dt[0], dt[1], dt[2], ':',
                      file_info.get('fileName'), ' with size:', file_info.get('fileSize'))
                download(cam, output, dt[0],
                         dt[1], dt[2], file_info.get('fileSize', 0))
            elif args.live:
                cam.ir_led(args.irled)
                cam.flip(args.flip)
                show_live(cam, args.output)
            elif args.set_wifi:
                print(f'Try to connect: SSID: {args.set_wifi[0]}, pwd: {args.set_wifi[1]}')
                if cam.set_wifi(*args.set_wifi) is not None:
                    print('Set successful, rebooting camera')
                    cam.reboot()
                else:
                    print('Camera not respond')

            else:
                print('Camera doesn\'t have a SD Card')
