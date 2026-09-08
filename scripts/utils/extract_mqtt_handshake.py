#!/usr/bin/env python3
"""
extract_mqtt_handshake.py — extrai a conversa MQTT câmera<->cloud de um pcap de
captura na rede real, pra descobrir o que o servidor responde quando a câmera
publica Status/Info pós-bind (o "ping-pong" que falta no fake server).

Contexto: no lab fake server, a câmera conecta no broker e publica
  Naxclow/P2P/Users/Device/Status  {"device":...,"token":...,"status":1}
  Naxclow/P2P/Users/Device/Info    {...}
e o fake server NÃO responde nada (não tem lado MQTT) — por isso o app mostra
"provisionamento de rede encerrou" e nunca libera o viewer (e o P2P :6123 nunca
abre). Este script revela o que o cloud REAL responde nesse momento.

Uso:
    python3 extract_mqtt_handshake.py captura.pcap [--broker-ip IP] [--camera-mac AA:BB:..]
    # --broker-ip: filtra só o tráfego do broker (ex.: 39.108.132.112)
    # --camera-mac: marca quem é a câmera (pra separar câmera->cloud de cloud->câmera)
"""
import argparse, sys
from collections import OrderedDict

try:
    from scapy.all import rdpcap, TCP, Raw
except ImportError:
    sys.exit("scapy faltando: pip3 install scapy")


def parse_varlen(b, i):
    mult, val, n = 1, 0, 0
    while True:
        if i + n >= len(b):
            return None, i
        d = b[i + n]
        val += (d & 0x7F) * mult
        n += 1
        if not (d & 0x80):
            break
        mult *= 128
        if n > 4:
            return None, i
    return val, i + n


def rd_str(b, i):
    if i + 2 > len(b):
        return None, i
    ln = (b[i] << 8) | b[i + 1]
    i += 2
    if i + ln > len(b):
        return None, i
    return b[i:i + ln], i + ln


def parse_publish(b):
    """Retorna (topic, payload, qos) se for um PUBLISH."""
    if not b or b[0] >> 4 != 3:
        return None
    qos = (b[0] >> 1) & 0x03
    rl, i = parse_varlen(b, 1)
    if rl is None:
        return None
    end = i + rl
    topic, i = rd_str(b, i)
    if topic is None:
        return None
    if qos > 0:
        i += 2
    return topic.decode(errors="replace"), bytes(b[i:end]), qos


def parse_subscribe(b):
    if not b or b[0] >> 4 != 8:
        return None
    rl, i = parse_varlen(b, 1)
    if rl is None:
        return None
    end = i + rl
    if i + 2 > end:
        return None
    i += 2  # packet id
    out = []
    while i < end:
        t, i = rd_str(b, i)
        if t is None:
            break
        out.append(t.decode(errors="replace"))
        i += 1  # qos byte
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--broker-ip", help="IP do broker MQTT (filtra só ele)")
    ap.add_argument("--camera-mac", help="MAC da câmera (pra marcar direção)")
    args = ap.parse_args()

    cam_mac = (args.camera_mac or "").lower()

    pkts = rdpcap(args.pcap)
    events = []  # (time, src_mac, direcao, desc, topic, payload)

    for pk in pkts:
        if TCP not in pk or Raw not in pk:
            continue
        if args.broker_ip and args.broker_ip not in (pk[0].src, pk[0].dst):
            continue
        b = bytes(pk[Raw].load)
        src_mac = ""
        if cam_mac and pk.haslayer("Ether"):
            src_mac = pk["Ether"].src.lower()
        t = b[0] >> 4 if b else 0
        ts = float(pk.time)
        if t == 3:  # PUBLISH
            pub = parse_publish(b)
            if pub and pub[0].startswith("Naxclow/"):
                topic, payload, qos = pub
                direcao = "CAMERA->" if (cam_mac and src_mac == cam_mac) else ("cloud->" if cam_mac else "?")
                events.append((ts, direcao, "PUB", topic, payload))
        elif t == 8:  # SUBSCRIBE
            subs = parse_subscribe(b)
            if subs:
                direcao = "CAMERA->" if (cam_mac and src_mac == cam_mac) else ("cloud->" if cam_mac else "?")
                for s in subs:
                    events.append((ts, direcao, "SUB", s, b""))

    if not events:
        print("Nenhum PUBLISH/SUBSCRIBE Naxclow/ encontrado no pcap.")
        print("  - confere o IP do broker (--broker-ip) ou se a captura pegou o tráfego.")
        sys.exit(1)

    events.sort(key=lambda e: e[0])
    print("=" * 70)
    print(f"Conversa MQTT Naxclow/ ({len(events)} eventos)")
    print("=" * 70)
    for ts, direcao, kind, topic, payload in events:
        tstr = __import__("datetime").datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]
        print(f"\n[{tstr}] {direcao:>10} {kind} {topic}")
        if payload:
            txt = payload.decode(errors="replace")
            print(f"    {txt[:400]}")

    print("\n" + "=" * 70)
    print("O que procurar: as mensagens 'cloud->' (respostas do servidor) que")
    print("vem DEPOIS do Status/Info da câmera. São elas que o fake server precisa")
    print("replicar (provável tópico Device/sub/<DEV> ou Device/req com code 301).")
    print("=" * 70)


if __name__ == "__main__":
    main()
