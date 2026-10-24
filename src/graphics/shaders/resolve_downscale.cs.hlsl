/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2025 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// Compute shader to downscale scaled resolve buffer data back to 1x resolution
// for CPU readback. Each thread produces one 1x guest element; a group covers
// 1024 consecutive guest elements (one 32x32 tile).
//
// Layout of the scaled data (as the resolve shaders write it, see
// XeTextureScaledTiledOffset in texture_address.xesli): guest memory is split
// into units of N consecutive elements (N = 8 for 8bpp and 16bpp, 4 for 32bpp,
// 2 for 64bpp). Each unit occupies scale_x * scale_y times its guest size in
// the scaled buffer, as host sub-units of N host pixels, column-major: sub-unit
// (sx, sy) at index sx * scale_y + sy, holding host row sy and host columns
// [sx * N, sx * N + N) of the unit's scale_x * N host columns. Guest element e
// of a unit covers host columns [e * scale_x, e * scale_x + scale_x) and host
// rows [0, scale_y) of that unit.
//
// With xe_downscale_flags bit 1 (average), the result is the per-byte average
// of the scale_x * scale_y host pixels (for formats whose channels are unsigned
// normalized bytes). Otherwise one host pixel is copied: the top-left one, or
// with bit 0 (half-pixel offset) the one at (scale_x / 2, scale_y / 2).

cbuffer XeResolveDownscaleConstants : register(b0) {
  uint xe_downscale_scale_x;         // 1 to kMaxDrawResolutionScaleAlongAxis
  uint xe_downscale_scale_y;         // 1 to kMaxDrawResolutionScaleAlongAxis
  uint xe_downscale_pixel_size_log2; // 0=8bit, 1=16bit, 2=32bit, 3=64bit
  uint xe_downscale_tile_count;      // Number of 32x32 tiles to process
  // Bit 0: sample the centre host pixel instead of the top-left one.
  // Bit 1: average all host pixels per byte.
  uint xe_downscale_flags;
};

ByteAddressBuffer xe_resolve_source : register(t0);
RWByteAddressBuffer xe_resolve_dest : register(u0);

// Groupshared memory for coalescing sub-32-bit writes
groupshared uint gs_tile_data[32 * 32];

// Byte offset in the scaled source of host pixel (host_x, host_y) of guest
// element element_index (counted from the start of the source).
uint XeDownscaleHostOffset(uint element_index, uint host_x, uint host_y) {
  uint pixel_size_log2 = xe_downscale_pixel_size_log2;
  uint unit_log2 = min(4u - pixel_size_log2, 3u);
  uint unit_mask = (1u << unit_log2) - 1u;
  uint scale_xy = xe_downscale_scale_x * xe_downscale_scale_y;
  uint unit_index = element_index >> unit_log2;
  uint column = (element_index & unit_mask) * xe_downscale_scale_x + host_x;
  uint subunit = (column >> unit_log2) * xe_downscale_scale_y + host_y;
  return ((unit_index * scale_xy) << (unit_log2 + pixel_size_log2)) +
         (((subunit << unit_log2) + (column & unit_mask)) << pixel_size_log2);
}

// The element's bits (8, 16 or 32 bits, zero-extended).
uint XeDownscaleLoadElement(uint offset) {
  uint pixel_size_log2 = xe_downscale_pixel_size_log2;
  uint value = xe_resolve_source.Load(offset & ~3u);
  if (pixel_size_log2 == 0u) {
    value = (value >> ((offset & 3u) * 8u)) & 0xFFu;
  } else if (pixel_size_log2 == 1u) {
    value = (value >> ((offset & 2u) * 8u)) & 0xFFFFu;
  }
  return value;
}

[numthreads(32, 32, 1)]
void main(uint3 xe_group_id : SV_GroupID,
          uint3 xe_thread_id_in_group : SV_GroupThreadID,
          uint xe_group_thread_index : SV_GroupIndex) {
  uint tile_index = xe_group_id.x;

  // Early out if beyond tile count
  [branch] if (tile_index >= xe_downscale_tile_count) {
    return;
  }

  uint row = xe_thread_id_in_group.y;
  uint column = xe_thread_id_in_group.x;
  uint pixel_index = row * 32 + column;  // 0-1023
  uint element_index = tile_index * (32 * 32) + pixel_index;

  uint pixel_size = 1u << xe_downscale_pixel_size_log2;
  uint dst_offset = element_index * pixel_size;

  uint sample_x = 0u;
  uint sample_y = 0u;
  [branch] if ((xe_downscale_flags & 1u) != 0u) {
    sample_x = xe_downscale_scale_x >> 1u;
    sample_y = xe_downscale_scale_y >> 1u;
  }

  [branch] if (xe_downscale_pixel_size_log2 == 3u) {
    // 64-bit - copy one host pixel.
    xe_resolve_dest.Store2(
        dst_offset,
        xe_resolve_source.Load2(
            XeDownscaleHostOffset(element_index, sample_x, sample_y)));
    return;
  }

  uint value;
  [branch] if ((xe_downscale_flags & 2u) != 0u) {
    // Per-byte average of all host pixels, rounded to nearest.
    uint4 sums = uint4(0u, 0u, 0u, 0u);
    for (uint y = 0u; y < xe_downscale_scale_y; ++y) {
      for (uint x = 0u; x < xe_downscale_scale_x; ++x) {
        uint v = XeDownscaleLoadElement(
            XeDownscaleHostOffset(element_index, x, y));
        sums += (uint4(v, v, v, v) >> uint4(0u, 8u, 16u, 24u)) & 0xFFu;
      }
    }
    uint count = xe_downscale_scale_x * xe_downscale_scale_y;
    uint4 averages = (sums + (count >> 1u)) / count;
    value = averages.x | (averages.y << 8u) | (averages.z << 16u) |
            (averages.w << 24u);
  } else {
    value = XeDownscaleLoadElement(
        XeDownscaleHostOffset(element_index, sample_x, sample_y));
  }

  [branch] switch (xe_downscale_pixel_size_log2) {
    case 0: {  // 8-bit - use groupshared to coalesce 4 bytes into 32-bit writes
      uint pack_index = pixel_index >> 2;   // Which uint (0-255)
      uint byte_pos = pixel_index & 3u;     // Which byte in uint (0-3)
      uint contribution = (value & 0xFFu) << (byte_pos * 8u);
      if (byte_pos == 0u) {
        gs_tile_data[pack_index] = contribution;
      }
      GroupMemoryBarrierWithGroupSync();
      if (byte_pos != 0u) {
        InterlockedOr(gs_tile_data[pack_index], contribution);
      }
      GroupMemoryBarrierWithGroupSync();
      if (byte_pos == 0u) {
        xe_resolve_dest.Store(tile_index * (32 * 32) + pack_index * 4,
                              gs_tile_data[pack_index]);
      }
      break;
    }
    case 1: {  // 16-bit - use groupshared to coalesce 2 shorts into 32-bit writes
      uint pack_index = pixel_index >> 1;   // Which uint (0-511)
      uint short_pos = pixel_index & 1u;    // Which short in uint (0-1)
      uint contribution = (value & 0xFFFFu) << (short_pos * 16u);
      if (short_pos == 0u) {
        gs_tile_data[pack_index] = contribution;
      }
      GroupMemoryBarrierWithGroupSync();
      if (short_pos != 0u) {
        InterlockedOr(gs_tile_data[pack_index], contribution);
      }
      GroupMemoryBarrierWithGroupSync();
      if (short_pos == 0u) {
        xe_resolve_dest.Store(tile_index * (32 * 32 * 2) + pack_index * 4,
                              gs_tile_data[pack_index]);
      }
      break;
    }
    default: {  // 32-bit
      xe_resolve_dest.Store(dst_offset, value);
      break;
    }
  }
}
