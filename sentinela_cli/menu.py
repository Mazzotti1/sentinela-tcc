"""Menu interativo com navegacao por setas (sem dependencias externas)."""

import os
import sys

from .ui import Theme


class MenuItem:
    def __init__(self, key, title, desc, danger=False, platform=""):
        self.key = key
        self.title = title
        self.desc = desc
        self.danger = danger
        self.platform = platform


def _read_key(fd):
    """Le uma tecla. Retorna 'up','down','enter','quit' ou None."""
    ch = os.read(fd, 1)
    if ch in (b"q", b"Q", b"\x03", b"\x1b"):
        if ch == b"\x1b":
            # seta = ESC [ A/B ; ESC sozinho = sair
            rest = os.read(fd, 2) if _has_input(fd) else b""
            if rest == b"[A":
                return "up"
            if rest == b"[B":
                return "down"
            return "quit"
        return "quit"
    if ch in (b"\r", b"\n"):
        return "enter"
    if ch in (b"k", b"K"):
        return "up"
    if ch in (b"j", b"J"):
        return "down"
    return None


def _has_input(fd, timeout=0.05):
    import select
    try:
        r, _, _ = select.select([fd], [], [], timeout)
        return bool(r)
    except OSError:
        return False


def _render(theme, items, sel, first=False):
    """Desenha a lista: um item por linha.

    Em modo raw, "\\n" (LF) apenas desce a linha — NAO volta a coluna 0. Por
    isso toda quebra de linha aqui e "\\r\\n". Este foi o bug que deixava o menu
    em escada na tela.
    """
    parts = []
    if not first:
        parts.append(f"\033[{_render.last_lines}A")   # sobe para o topo do bloco

    for i, it in enumerate(items):
        active = i == sel
        marker = theme.gold("> ") if active else "  "
        name = f"{it.title:<10}"          # pad antes de colorir (ANSI nao conta)
        if active:
            name = theme.bold(theme.cyan(name))
        elif it.danger:
            name = theme.yellow(name)
        else:
            name = theme.bold(name)

        line = f"  {marker}{name} {theme.dim(it.desc)}"
        if it.danger:
            line += theme.red("  [ativo]")
        parts.append(line + "\033[K\n")

    parts.append(theme.dim("  ↑↓ navegar · enter escolher · q sair") + "\033[K\n")

    body = "".join(parts)
    sys.stdout.write(body)
    sys.stdout.flush()
    _render.last_lines = body.count("\n")


_render.last_lines = 0


def choose(theme, items, prompt="Selecione um cenario:"):
    """Menu de setas. Retorna o item escolhido ou None."""
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        return _choose_plain(theme, items, prompt)

    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    sel = 0

    print()
    print(f"  {theme.bold(prompt)}")
    print()
    try:
        # Modo "cbreak" com eco desligado: le tecla a tecla sem esperar ENTER,
        # mas MANTEM o processamento de saida (ONLCR). Com setraw puro, "\n"
        # so desce e nao volta a coluna 0 — foi o que deixou o menu em escada.
        tty.setcbreak(fd)
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~(termios.ECHO)          # lflag: sem eco das teclas
        termios.tcsetattr(fd, termios.TCSADRAIN, attrs)

        _render(theme, items, sel, first=True)
        while True:
            key = _read_key(fd)
            if key == "up":
                sel = (sel - 1) % len(items)
                _render(theme, items, sel)
            elif key == "down":
                sel = (sel + 1) % len(items)
                _render(theme, items, sel)
            elif key == "enter":
                return items[sel]
            elif key == "quit":
                return None
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        print()


def _choose_plain(theme, items, prompt):
    """Fallback sem TTY: lista numerada."""
    print(f"  {theme.bold(prompt)}")
    print()
    for i, it in enumerate(items, 1):
        tag = f"  {theme.red('[ativo]')}" if it.danger else ""
        print(f"   {i}) {it.title}{tag}")
        print(f"      {theme.dim(it.desc)}")
    print()
    try:
        ans = input(f"  numero (enter vazio = sair): ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return None
    if not ans:
        return None
    try:
        idx = int(ans) - 1
    except ValueError:
        return None
    return items[idx] if 0 <= idx < len(items) else None
