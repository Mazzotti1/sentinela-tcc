from __future__ import annotations
import xmltodict
import xml

from dataclasses import dataclass, asdict, field
from json import dumps

import cmd_udp
from prot_udp import prot_udp


@dataclass
class prot_xml_udp(prot_udp):
    xml: dict = field(default_factory=dict)

    def req(self) -> bytes:
        raise NotImplementedError('Camera does not support XML requests')

    @staticmethod
    def resp(income: bytes) -> prot_xml_udp:
        r = prot_udp.resp(income)
        if r is not None and r.cmd == cmd_udp.P2P_UDP_CMD_XML:
            try:
                return prot_xml_udp(**asdict(r),
                                    xml=xmltodict.parse(r.payload.decode('ascii')))
            except (UnicodeDecodeError, xml.parsers.expat.ExpatError):
                print(f'---Exception with: {r.payload}')
        return None

    def __str__(self) -> str:
        return dumps(self.xml, default=self.__dumps_bytes__, indent=4)

    def __repr__(self) -> str:
        return f'XML(as dict): {self.xml}'
