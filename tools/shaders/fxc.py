"""Minimal FXC (/T cs_5_1 /Fh) replacement over d3dcompiler_47.dll.

fxc.py <d3dcompiler_47.dll> <source> <target e.g. cs_5_1> <variable name> <out.h> [NAME=VALUE ...]

Same call FXC makes for `xb buildshaders`: D3DCompileFromFile with the standard file
include handler, entry point "main", flags 0 (FXC's default optimization level 1),
then D3DDisassemble for the `#if 0` comment block. The byte array is written in the
clang-formatted layout the SDK fork keeps (12 bytes per line).
"""
import ctypes
import sys
from ctypes import wintypes


class Macro(ctypes.Structure):
    _fields_ = [("Name", ctypes.c_char_p), ("Definition", ctypes.c_char_p)]


def blob_bytes(blob):
    vtbl = ctypes.cast(blob, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    get_ptr = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)(vtbl[3])
    get_size = ctypes.WINFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p)(vtbl[4])
    return ctypes.string_at(get_ptr(blob), get_size(blob))


def main():
    dll_path, src, target, var, out = sys.argv[1:6]
    defines = [("SHADING_LANGUAGE_HLSL_XE", "1")]
    for d in sys.argv[6:]:
        k, _, v = d.partition("=")
        defines.append((k, v or "1"))
    dll = ctypes.WinDLL(dll_path)
    macros = (Macro * (len(defines) + 1))()
    for i, (k, v) in enumerate(defines):
        macros[i].Name = k.encode()
        macros[i].Definition = v.encode()
    code = ctypes.c_void_p()
    errors = ctypes.c_void_p()
    compile_fn = dll.D3DCompileFromFile
    compile_fn.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p,
                           ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint,
                           ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)]
    compile_fn.restype = ctypes.c_long
    hr = compile_fn(src, macros, ctypes.c_void_p(1), b"main", target.encode(), 0, 0,
                    ctypes.byref(code), ctypes.byref(errors))
    if errors.value:
        sys.stderr.write(blob_bytes(errors).decode("utf8", "replace"))
    if hr < 0:
        sys.exit(f"D3DCompileFromFile failed: 0x{hr & 0xFFFFFFFF:08X}")
    data = blob_bytes(code)
    dis = ctypes.c_void_p()
    dis_fn = dll.D3DDisassemble
    dis_fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint, ctypes.c_char_p,
                       ctypes.POINTER(ctypes.c_void_p)]
    dis_fn.restype = ctypes.c_long
    hr = dis_fn(data, len(data), 0, None, ctypes.byref(dis))
    if hr < 0:
        sys.exit(f"D3DDisassemble failed: 0x{hr & 0xFFFFFFFF:08X}")
    text = blob_bytes(dis).decode("utf8", "replace").rstrip("\x00")
    lines = ["#if 0"]
    lines.extend(text.splitlines())
    lines.append("#endif")
    lines.append("")
    lines.append(f"const BYTE {var}[] = {{")
    for i in range(0, len(data), 12):
        lines.append("    " + ", ".join(f"{b:3d}" for b in data[i:i + 12]) + ",")
    lines.append("};")
    with open(out, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{out}: {len(data)} bytes")


main()
