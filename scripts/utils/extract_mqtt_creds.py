#!/usr/bin/env python3
"""
extract_mqtt_creds.py — extrai o CONNECT do MQTT (user/pass/client-id) e os
PUBLISH (tópico/payload) de um pcap de captura MITM contra a câmera.

Prova, ou desmente, se o broker 1883 usa credencial estática ou por-device.
O 1883 é sem TLS, então user/pass viajam em CLARO no pacote CONNECT.

Uso:
    python3 extract_mqtt_creds.py resultados/capture.pcap
    python3 extract_mqtt_creds.py resultados/capture.pcap --host 39.108.132.112
"""
import argparse, sys
try:
    from scapy.all import rdpcap, TCP, Raw
except ImportError:
    sys.exit("scapy faltando: pip3 install scapy")

def parse_varlen(b, i):
    # MQTT remaining-length: varint, 1-4 bytes
    mult, val, n = 1, 0, 0
    while True:
        if i + n >= len(b): return None, i
        d = b[i + n]; val += (d & 0x7f) * mult; n += 1
        if not (d & 0x80): break
        mult *= 128
        if n > 4: return None, i
    return val, i + n

def rd_str(b, i):
    # MQTT UTF-8 string: 2-byte len prefix + bytes
    if i + 2 > len(b): return None, i
    ln = (b[i] << 8) | b[i+1]; i += 2
    if i + ln > len(b): return None, i
    return b[i:i+ln], i + ln

def parse_connect(b):
    # b starts at fixed header byte (0x10)
    if not b or b[0] >> 4 != 1: return None
    rl, i = parse_varlen(b, 1)
    if rl is None: return None
    proto, i = rd_str(b, i)          # "MQTT" / "MQIsdp"
    if proto is None: return None
    if i + 2 > len(b): return None
    i += 1                            # protocol level
    flags = b[i]; i += 1
    i += 2                            # keepalive
    cid, i = rd_str(b, i)             # client id
    if cid is None: return None
    out = {"proto": proto.decode(errors='replace'),
           "client_id": cid.decode(errors='replace')}
    if flags & 0x04:                  # will
        wt, i = rd_str(b, i);  wm, i = rd_str(b, i)
    if flags & 0x80:                  # username
        u, i = rd_str(b, i)
        if u is not None: out["username"] = u.decode(errors='replace')
    if flags & 0x40:                  # password
        p, i = rd_str(b, i)
        if p is not None: out["password"] = p.decode(errors='replace')
    return out

def parse_publish(b):
    # returns (topic, payload) for a PUBLISH (0x3x)
    if not b or b[0] >> 4 != 3: return None
    qos = (b[0] >> 1) & 0x03
    rl, i = parse_varlen(b, 1)
    if rl is None: return None
    end = i + rl
    topic, i = rd_str(b, i)
    if topic is None: return None
    if qos > 0: i += 2                 # packet id
    payload = b[i:end]
    return topic.decode(errors='replace'), payload

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--host", help="filtra só tráfego deste broker IP")
    args = ap.parse_args()

    pkts = rdpcap(args.pcap)
    connects, pubs = [], []
    for pk in pkts:
        if TCP not in pk or Raw not in pk: continue
        if args.host and args.host not in (pk[0].src, pk[0].dst): continue
        b = bytes(pk[Raw].load)
        # um segmento pode ter vários pacotes MQTT colados; varre por tipo no 1o byte
        t = b[0] >> 4 if b else 0
        if t == 1:
            c = parse_connect(b)
            if c: connects.append(c)
        elif t == 3:
            p = parse_publish(b)
            if p: pubs.append(p)

    print("=" * 60)
    print(f"CONNECT capturados: {len(connects)}")
    for c in connects:
        print("  client_id:", c.get("client_id"))
        print("  username :", c.get("username", "<nenhum>"))
        print("  password :", c.get("password", "<nenhum>"))
        print("  -")
    print("=" * 60)
    print(f"PUBLISH capturados: {len(pubs)}")
    seen = set()
    for topic, pl in pubs:
        key = topic
        if key in seen: continue
        seen.add(key)
        txt = pl.decode(errors='replace')
        print("  topic  :", topic)
        print("  payload:", txt[:200])
        print("  -")

if __name__ == "__main__":
    main()
