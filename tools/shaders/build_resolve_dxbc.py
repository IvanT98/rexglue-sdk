"""Compile resolve_*.cs.xesl in a shader dir to DXBC headers and compare with a reference dir.

build_resolve_dxbc.py <d3dcompiler_47.dll> <shader src dir> <out dir> [<reference header dir>] [glob]
"""
import fnmatch
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
dll, src_dir, out_dir = sys.argv[1:4]
ref_dir = sys.argv[4] if len(sys.argv) > 4 else None
pattern = sys.argv[5] if len(sys.argv) > 5 else "resolve_*.cs.xesl"
os.makedirs(out_dir, exist_ok=True)
for name in sorted(os.listdir(src_dir)):
    if not fnmatch.fnmatch(name, pattern):
        continue
    ident = name[:-5].replace(".", "_")
    out = os.path.join(out_dir, ident + ".h")
    r = subprocess.run([sys.executable, "-I", os.path.join(here, "fxc.py"), dll,
                        os.path.join(src_dir, name), "cs_5_1", ident, out],
                       capture_output=True, text=True)
    if r.returncode:
        print(f"{ident}: FAILED\n{r.stderr}")
        continue
    line = ident
    if ref_dir and os.path.exists(os.path.join(ref_dir, ident + ".h")):
        c = subprocess.run([sys.executable, "-I", os.path.join(here, "hdrcmp.py"), out,
                            os.path.join(ref_dir, ident + ".h")], capture_output=True, text=True)
        line += ": " + c.stdout.strip()
    print(line)
