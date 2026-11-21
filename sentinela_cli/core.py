"""Infraestrutura comum: execucao, rede, evidencia e pausas fisicas."""

import os
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from .ui import Theme

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
DEV = os.environ.get("DEV", "5c001502B330")
CAM_OUI = "5c:f1:50"
AP_IP = "192.168.169.1"
AP_PORT = 6123
IS_MAC = sys.platform == "darwin"
IFACE = os.environ.get("IFACE", "en0" if IS_MAC else "wlan0")

THEME = Theme()


class Abort(Exception):
    """Falha de pre-requisito: encerra o cenario e vai para o relatorio."""


def say(msg=""):
    print(msg)


def hdr(title):
    t = THEME
    say()
    say(t.blue("─" * 68))
    say("  " + t.bold(title))
    say(t.blue("─" * 68))


def step(n, msg):
    say(f"\n  {THEME.gold(f'[{n}]')} {THEME.bold(msg)}")


def ok(msg):
    say(f"      {THEME.green('✓')} {msg}")


def warn(msg):
    say(f"      {THEME.yellow('!')} {msg}")


def bad(msg):
    say(f"      {THEME.red('✗')} {msg}")


def dim(msg):
    say(f"      {THEME.dim(msg)}")


def die(msg):
    bad(msg)
    raise Abort(msg)


# ---------------------------------------------------------------- execucao
def run(cmd, sudo=False, check=True, timeout=None, capture=None):
    """Roda um comando. Com sudo nao capturamos: o prompt de senha precisa do TTY."""
    if isinstance(cmd, str):
        cmd = cmd.split()
    full = (["sudo"] if sudo else []) + list(cmd)
    if capture is None:
        capture = not sudo
    if sudo:
        say(f"      {THEME.dim('$ sudo ' + ' '.join(cmd))}")
    try:
        p = subprocess.run(
            full, cwd=str(ROOT), timeout=timeout,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
            text=True,
        )
    except FileNotFoundError:
        bad(f"comando nao encontrado: {full[0]}")
        if check:
            raise Abort(f"falta o binario '{full[0]}'")
        return 1, ""
    except subprocess.TimeoutExpired:
        bad(f"timeout apos {timeout}s")
        if check:
            raise Abort(f"timeout: {' '.join(full)}")
        return 124, ""
    out = p.stdout or ""
    if p.returncode != 0 and check:
        bad(f"falhou (exit {p.returncode}): {' '.join(full)}")
        if out.strip():
            dim(out.strip()[-600:])
        raise Abort(f"{full[0]} falhou")
    return p.returncode, out


def require(binary, hint):
    if shutil.which(binary) is None:
        die(f"falta '{binary}' — {hint}")


def ask_physical(title, lines):
    """Pausa para a acao fisica — unico ponto onde o roteiro para."""
    t = THEME
    say()
    say(t.yellow("  ┌─ ACAO FISICA " + "─" * 52))
    say(t.yellow("  │ ") + t.bold(title))
    for ln in lines:
        say(t.yellow("  │ ") + ln)
    say(t.yellow("  └" + "─" * 66))
    try:
        input(f"  {t.bold('ENTER quando terminar')} ")
    except EOFError:
        say()
        die("sem terminal interativo — rode num terminal de verdade")
    except KeyboardInterrupt:
        say()
        die("interrompido")


def confirm(question, auto=False):
    if auto:
        ok(f"{question} (auto)")
        return
    try:
        ans = input(f"  {THEME.bold(question)} [s/N] ").strip().lower()
    except EOFError:
        say()
        die("sem terminal interativo — rode num terminal de verdade")
    except KeyboardInterrupt:
        say()
        die("interrompido")
    if ans not in ("s", "sim", "y", "yes"):
        die("abortado pelo operador")


# ---------------------------------------------------------------- rede
def my_ip():
    if IS_MAC:
        out = subprocess.run(["ipconfig", "getifaddr", IFACE], capture_output=True, text=True).stdout
    else:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show", IFACE], capture_output=True, text=True).stdout
    m = re.search(r"(\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else None


def gateway():
    if IS_MAC:
        out = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True).stdout
        m = re.search(r"gateway:\s*(\d+\.\d+\.\d+\.\d+)", out)
    else:
        out = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True).stdout
        m = re.search(r"via\s+(\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else None


def wifi_ssid():
    if IS_MAC:
        out = subprocess.run(["networksetup", "-getairportnetwork", IFACE], capture_output=True, text=True).stdout
        m = re.search(r"Current Wi-Fi Network:\s*(.+)", out)
        return m.group(1).strip() if m else None
    out = subprocess.run(["iwgetid", "-r"], capture_output=True, text=True).stdout.strip()
    return out or None


def arp_camera():
    out = subprocess.run(["arp", "-a", "-n"], capture_output=True, text=True).stdout
    for ln in out.splitlines():
        if CAM_OUI in ln.lower():
            m = re.search(r"(\d+\.\d+\.\d+\.\d+)", ln)
            if m:
                return m.group(1)
    return None


def discover_camera(sweep=True):
    ip = arp_camera()
    if ip or not sweep:
        return ip
    base = my_ip()
    if not base:
        return None
    net = ".".join(base.split(".")[:3])
    dim(f"varrendo {net}.0/24 atras do OUI {CAM_OUI}...")
    procs = []
    for i in range(1, 255):
        procs.append(subprocess.Popen(
            ["ping", "-c", "1", "-W", "100" if IS_MAC else "1", f"{net}.{i}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for p in procs:
        p.wait()
    time.sleep(1)
    return arp_camera()


def tcp_open(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


# ---------------------------------------------------------------- evidencia
class Evidence:
    def __init__(self, scenario, out_dir=None):
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.dir = Path(out_dir) if out_dir else ROOT / "results" / f"{scenario}_{ts}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.scenario = scenario
        self.checks = []

    def add(self, name, status, detail="", artifact=None):
        self.checks.append((name, status, detail, artifact))
        icon = {"OK": THEME.green("✓"), "FAIL": THEME.red("✗"),
                "SKIP": THEME.yellow("–"), "N/A": THEME.yellow("–")}.get(status, "?")
        tail = f" {THEME.dim('(' + artifact + ')')}" if artifact else ""
        say(f"      {icon} {name}{tail}")
        if detail:
            dim(detail)

    def save_text(self, name, text):
        p = self.dir / name
        p.write_text(text, encoding="utf-8")
        return p.name

    def report(self):
        hdr(f"RELATORIO — {self.scenario}")
        say(f"  evidencia: {THEME.cyan(str(self.dir))}")
        say()
        width = max((len(c[0]) for c in self.checks), default=10)
        counts = {}
        for name, status, detail, artifact in self.checks:
            counts[status] = counts.get(status, 0) + 1
            color = {"OK": THEME.green, "FAIL": THEME.red}.get(status, THEME.yellow)
            say(f"  {name:<{width}}  {color(status):<6}  {THEME.dim(detail)}")
        say()
        parts = [f"{k}={v}" for k, v in sorted(counts.items())]
        say(f"  {THEME.bold('resumo:')} " + (", ".join(parts) or "nada testado"))

        md = [f"# Relatorio — {self.scenario}", "",
              f"Gerado: {datetime.now().isoformat(timespec='seconds')}", "",
              "| Teste | Resultado | Detalhe | Evidencia |", "|---|---|---|---|"]
        for name, status, detail, artifact in self.checks:
            md.append(f"| {name} | {status} | {detail or '-'} | {artifact or '-'} |")
        (self.dir / "report.md").write_text("\n".join(md) + "\n", encoding="utf-8")
        say(f"  relatorio: {THEME.cyan(str(self.dir / 'report.md'))}")
        return counts
