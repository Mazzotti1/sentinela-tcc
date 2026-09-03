from __future__ import annotations
from json import dumps

from dataclasses import dataclass, asdict, field

import cmd_udp
from prot_json_udp import prot_json_udp


@dataclass
class prot_ap(prot_json_udp):
    content: dict = field(default_factory=dict)

    def req(self) -> bytes:
        self.json = {
            "code": cmd_udp.CODE_AP_COMMAND,
            "content": self.content
        }
        return super().req()

    @staticmethod
    def resp(income: bytes) -> prot_ap:
        r = prot_json_udp.resp(income)
        if r is not None:
            content = r.json.get('content', r.json)
            return prot_ap(**asdict(r), content=content)
        return None

    def __str__(self) -> str:
        return dumps(self.content, default=self.__dumps_bytes__, indent=4)

    def __repr__(self) -> str:
        return f'CONTENT: {self.content}'
