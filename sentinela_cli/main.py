"""sentinela — verificacao de seguranca de cameras IP Naxclow/V720."""

import argparse
import sys

from .core import Abort, Evidence, ROOT, SCRIPTS, THEME as T, run, say
from .menu import MenuItem, choose
from .scenarios import SCENARIOS
from .ui import show_banner

VERSION = "1.0"


def build_items():
    items = []
    for key, (fn, desc, danger, platform) in SCENARIOS.items():
        items.append(MenuItem(key, key, desc, danger=danger, platform=platform))
    return items


def run_scenario(key, args):
    fn, desc, _, _ = SCENARIOS[key]
    ev = Evidence(key, args.out)
    say()
    say(f"  {T.bold(key)} {T.dim('· ' + desc)}")
    say(f"  {T.dim('evidencia: ' + str(ev.dir))}")
    code = 0
    try:
        fn(ev)
    except Abort as e:
        ev.add("pre-requisito", "FAIL", str(e))
        code = 1
    except KeyboardInterrupt:
        say()
        ev.add("execucao", "FAIL", "interrompido pelo operador")
        code = 130
    finally:
        counts = ev.report()
        if code == 0 and (counts.get("FAIL") or counts.get("N/A")):
            code = 0 if key == "info" else 1
    return code


def cmd_down(args):
    """Derruba o lab (ARP/DNS/DNAT)."""
    from .core import hdr, ok, warn
    hdr("DERRUBAR O LAB")
    run([str(SCRIPTS / "mitm_dns" / "ota_up.sh"), "down"], sudo=True, check=False, timeout=180)
    say()
    ok("lab derrubado (ARP/DNS/DNAT restaurados)")
    say(f"      confira com {T.cyan('./sentinela info')}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="sentinela",
        description="Verificacao de seguranca de cameras IP Naxclow/V720.",
        epilog="Ambiente controlado / equipamento proprio. Nao use contra terceiros.",
    )
    ap.add_argument("scenario", nargs="?", help="cenario a rodar (vazio = menu)")
    ap.add_argument("-l", "--list", action="store_true", help="lista os cenarios e sai")
    ap.add_argument("-y", "--yes", action="store_true", help="pula confirmacoes (fisicas continuam)")
    ap.add_argument("-o", "--out", help="pasta de evidencia")
    ap.add_argument("--no-banner", action="store_true", help="nao mostra o banner")
    args = ap.parse_args(argv)

    # ---- modos sem banner
    if args.list:
        for key, (_, desc, danger, platform) in SCENARIOS.items():
            tag = T.red(" [ativo]") if danger else ""
            say(f"  {T.bold(f'{key:<10}')} {desc}{T.dim(f'  ({platform})')}{tag}")
        return 0

    if args.scenario == "down":
        return cmd_down(args)

    if args.scenario and args.scenario not in SCENARIOS:
        say(f"{T.red('cenario desconhecido:')} {args.scenario}")
        say(f"{T.dim('use --list para ver as opcoes')}")
        return 2

    show_banner(T, VERSION)

    # ---- cenario direto
    if args.scenario:
        return run_scenario(args.scenario, args)

    # ---- menu interativo
    say()
    item = choose(T, build_items())
    if item is None:
        say(f"  {T.dim('saiu.')}")
        return 0
    return run_scenario(item.key, args)


if __name__ == "__main__":
    sys.exit(main())
