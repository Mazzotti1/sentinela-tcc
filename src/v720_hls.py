"""Transcodifica os frames JPEG que o fake server extrai do device em HLS (H.264).

Fluxo: device (callback de frame JPEG) -> stdin do ffmpeg -> HLS (.m3u8 + .ts).
O HTTP (v720_http) serve os arquivos em /tmp/hls_<uid>/ e a pagina player.

Sem isso, o /live entrega MJPEG (sequencia de JPEGs), que o Firefox renderiza
com jitter. Com HLS o navegador tem buffer e toca continuo.
"""
from __future__ import annotations
import os
import shutil
import subprocess
import threading


class v720_hls:
    _lock = threading.Lock()
    _insts = {}

    FFMPEG = os.environ.get('FFMPEG_BIN', 'ffmpeg')
    FRAMERATE = os.environ.get('HLS_FPS', '20')
    SEG_TIME = os.environ.get('HLS_SEG', '1')
    LIST_SIZE = os.environ.get('HLS_LIST', '5')

    @staticmethod
    def root(uid: str) -> str:
        return os.path.join('/tmp', f'hls_{uid}')

    @staticmethod
    def get(dev, uid: str) -> 'v720_hls':
        """Devolve a instancia viva pro uid (recria se o ffmpeg morreu)."""
        with v720_hls._lock:
            inst = v720_hls._insts.get(uid)
            if inst is None or not inst.alive():
                inst = v720_hls(dev, uid)
                v720_hls._insts[uid] = inst
            return inst

    def __init__(self, dev, uid: str) -> None:
        self.uid = uid
        self.dev = dev
        self.dir = v720_hls.root(uid)
        if os.path.isdir(self.dir):
            shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir, exist_ok=True)
        self.playlist = os.path.join(self.dir, 'index.m3u8')
        self.frames = 0

        cmd = [
            v720_hls.FFMPEG, '-hide_banner', '-loglevel', os.environ.get('HLS_LOGLEVEL', 'warning'),
            '-f', os.environ.get('HLS_INFMT', 'image2pipe'),
            '-vcodec', os.environ.get('HLS_INCODEC', 'mjpeg'),
            '-framerate', v720_hls.FRAMERATE,
            '-probesize', os.environ.get('HLS_PROBESIZE', '10M'),
            '-analyzeduration', os.environ.get('HLS_ANALYZE', '10M'),
            '-i', 'pipe:0',
            '-an',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
            '-pix_fmt', 'yuv420p', '-g', '40', '-sc_threshold', '0',
            '-f', 'hls',
            '-hls_time', v720_hls.SEG_TIME,
            '-hls_list_size', v720_hls.LIST_SIZE,
            '-hls_flags', 'delete_segments+omit_endlist',
            self.playlist,
        ]
        self.cmd = cmd
        self._err = open(os.path.join(self.dir, 'ffmpeg.log'), 'wb')
        self._proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=self._err)
        self._cb = self._on_frame
        dev.set_vframe_cb(self._cb)
        # cap_live dispara o NAT probe e mantem o canal UDP de dados associado —
        # sem ele o callback nunca recebe frame (mesmo caminho do /live).
        try:
            dev.cap_live()
        except Exception:
            pass

    def alive(self) -> bool:
        return self._proc.poll() is None

    def _on_frame(self, dev, frame) -> None:
        self.frames += 1
        if not self.alive():
            return
        try:
            self._proc.stdin.write(bytes(frame))
        except (BrokenPipeError, ValueError, OSError):
            pass

    def stop(self) -> None:
        try:
            self.dev.unset_vframe_cb(self._cb)
        except (ValueError, AttributeError):
            pass
        try:
            self.dev.cap_stop()
        except Exception:
            pass
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            self._proc.terminate()
        except OSError:
            pass
        with v720_hls._lock:
            if v720_hls._insts.get(self.uid) is self:
                del v720_hls._insts[self.uid]
