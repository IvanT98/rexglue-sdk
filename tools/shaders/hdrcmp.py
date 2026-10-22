"""Compare the binary payload of two shader headers (DXBC BYTE arrays or SPIR-V uint32 arrays).

hdrcmp.py a.h b.h -> prints sizes and whether the payloads are identical
(for DXBC, also ignoring the 16-byte checksum at offset 4).
"""
import re
import sys


def payload(path):
    text = open(path, encoding="utf8", errors="replace").read()
    body = text[text.index("#endif"):]
    body = body[body.index("{") + 1:body.rindex("}")]
    if "0x" in body:
        words = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]+)", body)]
        return b"".join(w.to_bytes(4, "little") for w in words)
    return bytes(int(x) for x in re.findall(r"\d+", body))


a, b = payload(sys.argv[1]), payload(sys.argv[2])
print(f"{len(a)} vs {len(b)} bytes; identical={a == b}", end="")
if a[:4] == b"DXBC":
    print(f"; identical without checksum={a[:4] + a[20:] == b[:4] + b[20:]}")
else:
    print()
