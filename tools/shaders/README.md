# Rebuilding the resolve shaders

The D3D12 resolve shaders in `src/graphics/shaders/bytecode/d3d12_5_1/resolve_*_cs.h` are
compiled from the XESL sources in `src/graphics/shaders/source/gpu/shaders/` (Xenia canary
0b2ffa314, plus the `XE_RESOLVE_DEST_NUMBER_FORMAT` variants behind the
`resolve_dest_number_format` cvar). The Vulkan SPIR-V headers are not rebuilt here.

Compiler: `d3dcompiler_47.dll` 10.0.26100.7705, the entry `c/Redist/D3D/x64/d3dcompiler_47.dll`
of the NuGet package `Microsoft.Windows.SDK.CPP` 10.0.26100.7705
(https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/10.0.26100.7705/microsoft.windows.sdk.cpp.10.0.26100.7705.nupkg),
sha256 `a05f99734f7c4822fefc12b367af21fd0976ed6608752fb1e1e80b6ece7ecbbb`. Windows 10's
`System32\d3dcompiler_47.dll` (10.0.19041) gives the same bytecode. No `fxc.exe` ships in a NuGet
package: `fxc.py` makes FXC's call (`D3DCompileFromFile`, entry `main`, flags 0,
`SHADING_LANGUAGE_HLSL_XE=1`) and writes the header with `D3DDisassemble`'s listing.

```
python -I tools/shaders/build_resolve_dxbc.py <d3dcompiler_47.dll> src/graphics/shaders/source/gpu/shaders <out dir> [src/graphics/shaders/bytecode/d3d12_5_1]
```

With the last argument it compares each header with the committed one (`hdrcmp.py`); all 30
compare identical. Copy changed headers into `bytecode/d3d12_5_1/`.
