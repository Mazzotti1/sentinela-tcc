from __future__ import annotations
from json import dumps, loads, decoder

from dataclasses import dataclass, asdict, field

import cmd_udp
from prot_udp import prot_udp


@dataclass
class prot_json_udp(prot_udp):
    DEFAULT_DEV_TARGET = "deadbeef"
    DEFAULT_DEVICE_TOKEN = "This is TEST token"

    json: dict = field(default_factory=dict)

    def req(self) -> bytes:
        self.cmd = cmd_udp.P2P_UDP_CMD_JSON
        self.payload = dumps(self.json,
                             default=self.__dumps_bytes__).encode('ascii')
        return super().req()

    @staticmethod
    def resp(income: bytes) -> prot_json_udp:
        r = prot_udp.resp(income)
        if r is not None and (r.cmd == cmd_udp.P2P_UDP_CMD_JSON or r.cmd == cmd_udp.P2P_UDP_CMD_DIRECT_MOTION):
            try:
                return prot_json_udp(**asdict(r),
                                     json=loads(r.payload.decode('ascii')))
            except (UnicodeDecodeError, decoder.JSONDecodeError):
                print(f'---Exception with: {r.payload}')

        return None

    def __str__(self) -> str:
        return dumps(self.json, default=self.__dumps_bytes__, indent=4)

    def __repr__(self) -> str:
        return f'JSON: {self.json}'
