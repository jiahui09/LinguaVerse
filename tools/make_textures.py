#!/usr/bin/env python3
"""P3 批次4 — 街景贴图管线（stdlib 零下载、确定性合成）

产出（godot-project/assets/textures/，与 make_ambience 同款「生成器直写」白名单例外）：
  cobble_*.png   街道路面石块       512² albedo/normal/rough
  paving_*.png   人行道石板         512² albedo/normal/rough
  granite_*.png  路缘石带           512² albedo/normal/rough
  manhole_*.png  井盖贴片           256² albedo/normal（RGBA 带透明边）

同时更新 godot-project/data/assets_manifest.json 的 `textures` 段
（bytes/sha256/宽高/族别）——该段唯一写入者，手改即被校验判漂移。
校验由 tools/check_glb.py 承担（PNG 解码 / 非纯色 / 尺寸 ≤2048 / 哈希交叉核对 /
族别齐全：cobble·paving·granite 需 albedo+normal+rough，manhole 需 albedo+normal）。

设计约束：
  * 全部贴图周期性可平铺（噪声/晶格环面取模，边界无缝）→ 三平面平铺采样不断缝
  * 颜色全部由固定种子的 random.Random 生成 → 同脚本同种子字节级可复现
  * 法线贴图由高度场 Sobel 求导编码（OpenGL 约定 +Z 朝外）

用法：
  python3 tools/make_textures.py                # 合成 + 刷新 manifest.textures
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import struct
import sys
import zlib
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "godot-project/assets/textures"
DEFAULT_MANIFEST = ROOT / "godot-project/data/assets_manifest.json"

GENERATOR_SHA = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


# ─────────────────────────────── PNG 写出 ───────────────────────────────

def write_png(path: Path, w: int, h: int, rgba: bytearray) -> None:
    """最小 PNG 写出：RGBA8 / filter0 / zlib-9（无第三方库）。"""
    assert len(rgba) == w * h * 4, "RGBA 缓冲长度不符"

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)  # filter: None
        raw += rgba[y * stride : (y + 1) * stride]

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # RGBA8
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)


# ─────────────────────────── 可平铺噪声工具 ───────────────────────────

def vnoise(w: int, h: int, n: int, seed: int) -> list[float]:
    """n×n 晶格值噪声（双线性 + smoothstep），环面取模 → 周期等于画布。"""
    rnd = random.Random(seed)
    g = [rnd.random() for _ in range(n * n)]
    out = [0.0] * (w * h)
    step_x = n / w
    step_y = n / h
    for y in range(h):
        fy = y * step_y
        j = int(fy) % n
        ty = fy - int(fy)
        sy = ty * ty * (3.0 - 2.0 * ty)
        j2 = (j + 1) % n
        row_a = j * n
        row_b = j2 * n
        base = y * w
        for x in range(w):
            fx = x * step_x
            i = int(fx) % n
            tx = fx - int(fx)
            sx = tx * tx * (3.0 - 2.0 * tx)
            i2 = (i + 1) % n
            a = g[row_a + i]
            b = g[row_a + i2]
            c = g[row_b + i]
            d = g[row_b + i2]
            top = a + (b - a) * sx
            bot = c + (d - c) * sx
            out[base + x] = top + (bot - top) * sy
    return out


def fbm(w: int, h: int, base_n: int, octaves: int, seed: int) -> list[float]:
    """分形叠加（0..1 归一），各倍频仍取模可平铺。"""
    out = [0.0] * (w * h)
    amp_total = 0.0
    amp = 1.0
    n = base_n
    for o in range(octaves):
        layer = vnoise(w, h, n, seed + o * 101)
        for i in range(w * h):
            out[i] += layer[i] * amp
        amp_total += amp
        amp *= 0.5
        n *= 2
    inv = 1.0 / amp_total
    for i in range(w * h):
        out[i] *= inv
    return out


def smooth01(edge0: float, edge1: float, x: float) -> float:
    if edge1 <= edge0:
        return 0.0 if x < edge0 else 1.0
    t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def normal_from_height(hgt: list[float], w: int, h: int, strength: float) -> bytearray:
    """高度场 Sobel 求导 → OpenGL 法线（RGB，+Z=255），取模平铺。"""
    out = bytearray(w * h * 4)
    for y in range(h):
        ym = (y - 1) % h
        yp = (y + 1) % h
        base = y * w
        for x in range(w):
            xm = (x - 1) % w
            xp = (x + 1) % w
            dx = (hgt[base + xp] - hgt[base + xm]) * strength
            dy = (hgt[yp * w + x] - hgt[ym * w + x]) * strength
            nx, ny, nz = -dx, -dy, 1.0
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
            o = (base + x) * 4
            out[o] = int(clamp01(nx * inv * 0.5 + 0.5) * 255 + 0.5)
            out[o + 1] = int(clamp01(ny * inv * 0.5 + 0.5) * 255 + 0.5)
            out[o + 2] = int(clamp01(nz * inv * 0.5 + 0.5) * 255 + 0.5)
            out[o + 3] = 255
    return out


# ─────────────────────────── 四族贴图合成 ───────────────────────────

def gen_cobble(size: int, seed: int) -> tuple[bytearray, bytearray, bytearray]:
    """街面石块：环面 Voronoi 卵石 + 灰缝 + 高度穹顶 → albedo/normal/rough。"""
    w = h = size
    rnd = random.Random(seed)
    n = 18  # 晶格数（512/18 ≈ 28px 一格）
    cell = size / n
    # 每格随机抖动种子（格号取模 → 跨画布边界同一颗石子）
    seeds: dict[tuple[int, int], tuple[float, float]] = {}
    for j in range(n):
        for i in range(n):
            seeds[(i, j)] = (
                (i + 0.5 + (rnd.random() - 0.5) * 0.6) * cell,
                (j + 0.5 + (rnd.random() - 0.5) * 0.6) * cell,
            )
    rnd2 = random.Random(seed + 17)
    cell_tone = [0.34 + rnd2.random() * 0.22 for _ in range(n * n)]
    cell_warm = [(rnd2.random() - 0.5) * 0.05 for _ in range(n * n)]
    joint_wob = vnoise(w, h, 9, seed + 31)      # 灰缝宽度起伏
    grain = fbm(w, h, 32, 3, seed + 51)          # 细颗粒
    grit = vnoise(w, h, 64, seed + 71)           # 粗砂

    albedo = bytearray(w * h * 4)
    height = [0.0] * (w * h)
    rough = bytearray(w * h * 4)

    for y in range(h):
        for x in range(w):
            # 环面距离取最近两颗石子
            px, py = x + 0.5, y + 0.5
            gi = int(px / cell) % n
            gj = int(py / cell) % n
            d1 = 1e9
            d2 = 1e9
            best = (gi, gj)
            for dj in (-1, 0, 1):
                jj = (gj + dj) % n
                for di in (-1, 0, 1):
                    ii = (gi + di) % n
                    sxp, syp = seeds[(ii, jj)]
                    dx = px - sxp
                    dy = py - syp
                    # 邻格镜像（晶格周期 = cell*n = size → 用环绕偏移）
                    if dx > size / 2:
                        dx -= size
                    elif dx < -size / 2:
                        dx += size
                    if dy > size / 2:
                        dy -= size
                    elif dy < -size / 2:
                        dy += size
                    dd = dx * dx + dy * dy
                    if dd < d1:
                        d2 = d1
                        d1 = dd
                        best = (ii, jj)
                    elif dd < d2:
                        d2 = dd
            d1 = math.sqrt(d1)
            d2 = math.sqrt(d2)
            border = d2 - d1                       # 0 = 石子边缘
            idx = y * w + x
            t = joint_wob[idx]
            joint_px = 1.1 + t * 2.0              # 灰缝宽 1.1~3.1px
            stone = smooth01(joint_px, joint_px + 6.0, border)  # 0=缝 1=石面

            bi, bj = best
            bidx = bj * n + bi
            tone = cell_tone[bidx]
            warm = cell_warm[bidx]

            # 高度：石面穹顶 + 细颗粒；缝内粗砂
            dome = stone * (0.72 + 0.28 * stone)
            hh = 0.08 + dome * 0.8 + grain[idx] * 0.12
            if stone < 0.5:
                hh = 0.06 + grit[idx] * 0.10
            height[idx] = hh

            # 颜色：石面暖灰逐石变化 + 接缝阴影 AO + 颗粒
            v = tone * (0.78 + 0.22 * stone) + (grain[idx] - 0.5) * 0.07
            if stone < 0.5:
                v = 0.17 + (grit[idx] - 0.5) * 0.09
            r = clamp01(v * (1.05 + warm))
            g = clamp01(v * 1.0)
            b = clamp01(v * (0.93 - warm))
            o = idx * 4
            albedo[o] = int(r * 255 + 0.5)
            albedo[o + 1] = int(g * 255 + 0.5)
            albedo[o + 2] = int(b * 255 + 0.5)
            albedo[o + 3] = 255

            rv = (0.76 + (bidx * 37 % 11) * 0.012 + grain[idx] * 0.08)
            if stone < 0.5:
                rv = 0.94 + grit[idx] * 0.05
            rv = clamp01(rv)
            rvb = int(rv * 255 + 0.5)
            rough[o] = rvb
            rough[o + 1] = rvb
            rough[o + 2] = rvb
            rough[o + 3] = 255
    return albedo, normal_from_height(height, w, h, 3.0), rough


def gen_paving(size: int, seed: int) -> tuple[bytearray, bytearray, bytearray]:
    """人行道石板：4×4 错缝石板 + 污渍 + 崩边 + 浅穹顶 → albedo/normal/rough。"""
    w = h = size
    n = 4
    cell = size / n
    rnd = random.Random(seed)
    ladder = [0.47 + i / (n * n) * 0.21 for i in range(n * n)]
    rnd.shuffle(ladder)
    slab_tone = ladder                                # 分层色阶：相邻石板不撞调
    slab_warm = [(rnd.random() - 0.5) * 0.05 for _ in range(n * n)]
    joint_wob = vnoise(w, h, 12, seed + 13)
    stain = fbm(w, h, 3, 3, seed + 29)
    grain = fbm(w, h, 40, 3, seed + 47)
    chip = vnoise(w, h, 48, seed + 67)

    albedo = bytearray(w * h * 4)
    height = [0.0] * (w * h)
    rough = bytearray(w * h * 4)

    for y in range(h):
        py = y + 0.5
        gj = int(py / cell) % n
        row_shift = (cell * 0.5) if (gj % 2 == 1) else 0.0   # 半格错缝（周期=2行，512 可整除 → 仍平铺）
        ty = py - gj * cell
        for x in range(w):
            px = x + 0.5
            sxp = px - row_shift
            cell_i = int(math.floor(sxp / cell))   # 未取模：错位行 sxp<0，mod 后再减会算出负 tx
            gi = cell_i % n
            tx = sxp - cell_i * cell
            # 到最近横缝/竖缝的距离（带抖动缝宽）
            idx = y * w + x
            jw = 2.0 + joint_wob[idx] * 2.0
            d_edge = min(tx, cell - tx, ty, cell - ty)
            # 崩边：缝口处噪声侵蚀
            chip_t = chip[idx]
            jw_local = jw + (0.0 if chip_t < 0.62 else (chip_t - 0.62) * 14.0)
            slab = smooth01(jw_local, jw_local + 5.0, d_edge)

            sidx = gj * n + gi
            tone = slab_tone[sidx]
            warm = slab_warm[sidx]

            hh = 0.10 + slab * (0.72 + 0.28 * slab) * 0.8 + grain[idx] * 0.10
            if slab < 0.4:
                hh = 0.05 + grain[idx] * 0.08
            height[idx] = hh

            st = 0.92 + stain[idx] * 0.12
            ao = 0.84 + 0.16 * smooth01(0.0, 7.0, d_edge)   # 沿缝暗影=凹缝深度感
            v = tone * (0.80 + 0.20 * slab) * st * ao + (grain[idx] - 0.5) * 0.045
            if slab < 0.4:
                v = 0.25 + (grain[idx] - 0.5) * 0.10
            r = clamp01(v * (1.03 + warm))
            g = clamp01(v * 1.0)
            b = clamp01(v * (0.96 - warm))
            o = idx * 4
            albedo[o] = int(r * 255 + 0.5)
            albedo[o + 1] = int(g * 255 + 0.5)
            albedo[o + 2] = int(b * 255 + 0.5)
            albedo[o + 3] = 255

            rv = clamp01(0.66 + (sidx * 13 % 9) * 0.014 + grain[idx] * 0.07 + (0.06 if slab < 0.4 else 0.0))
            rvb = int(rv * 255 + 0.5)
            rough[o] = rvb
            rough[o + 1] = rvb
            rough[o + 2] = rvb
            rough[o + 3] = 255
    return albedo, normal_from_height(height, w, h, 2.4), rough


def gen_granite(size: int, seed: int) -> tuple[bytearray, bytearray, bytearray]:
    """路缘石：花岗岩盐胡椒斑晶 + 中性底色 → albedo/normal/rough。"""
    w = h = size
    grain = fbm(w, h, 16, 4, seed + 5)
    speck_d = vnoise(w, h, 156, seed + 23)  # 暗斑晶（高频=更细）
    speck_l = vnoise(w, h, 172, seed + 37)  # 亮石英
    pit = vnoise(w, h, 48, seed + 53)

    albedo = bytearray(w * h * 4)
    height = [0.0] * (w * h)
    rough = bytearray(w * h * 4)

    for i in range(w * h):
        g0 = grain[i]
        base = 0.42 + (g0 - 0.5) * 0.09
        td = smooth01(0.79, 0.90, speck_d[i])
        tl = smooth01(0.81, 0.92, speck_l[i])
        v_dark = base * 0.58
        v_lite = 0.84
        v = base * (1 - td) + v_dark * td
        v = v * (1 - tl) + v_lite * tl
        hh = 0.45 + (g0 - 0.5) * 0.30 - td * 0.34 + tl * 0.26
        if pit[i] > 0.82:
            hh -= (pit[i] - 0.82) * 1.8
        height[i] = hh
        r = clamp01(v * 1.01)
        gg = clamp01(v * 1.0)
        b = clamp01(v * 0.99)
        o = i * 4
        albedo[o] = int(r * 255 + 0.5)
        albedo[o + 1] = int(gg * 255 + 0.5)
        albedo[o + 2] = int(b * 255 + 0.5)
        albedo[o + 3] = 255
        rv = clamp01(0.70 + (g0 - 0.5) * 0.14 - tl * 0.12 + td * 0.10)
        rvb = int(rv * 255 + 0.5)
        rough[o] = rvb
        rough[o + 1] = rvb
        rough[o + 2] = rvb
        rough[o + 3] = 255
    return albedo, normal_from_height(height, w, h, 2.0), rough


def gen_manhole(size: int, seed: int) -> tuple[bytearray, bytearray]:
    """井盖贴片：同心环 + 菱形防滑纹 + 螺栓 + 锈斑，圆形透明边 → albedo/normal。"""
    w = h = size
    cx = cy = (size - 1) / 2.0
    radius = size * 0.453        # 256 → 116px
    grain = fbm(w, h, 32, 3, seed + 9)
    rust = fbm(w, h, 6, 3, seed + 19)
    wob = vnoise(w, h, 24, seed + 27)

    albedo = bytearray(w * h * 4)
    height = [0.0] * (w * h)

    bolts = []
    bolt_ring = radius - 7.5
    for k in range(10):
        a = k * 2.0 * math.pi / 10.0 + 0.31
        bolts.append((cx + math.cos(a) * bolt_ring, cy + math.sin(a) * bolt_ring))

    for y in range(h):
        for x in range(w):
            idx = y * w + x
            dx = (x + 0.5) - (cx + 0.5)
            dy = (y + 0.5) - (cy + 0.5)
            r = math.sqrt(dx * dx + dy * dy)
            o = idx * 4
            if r > radius + 1.0:
                albedo[o + 3] = 0
                continue
            # 透明边 AA
            alpha = clamp01((radius + 1.0 - r) / 2.0)
            g0 = grain[idx]
            base = 0.30 + (g0 - 0.5) * 0.05
            hh = 0.55 + (g0 - 0.5) * 0.10

            if r > radius - 15.0:
                # 外缘亮环
                base = 0.34 + (g0 - 0.5) * 0.05
                hh = 0.70 + (g0 - 0.5) * 0.08
                if abs(r - (radius - 15.0)) < 1.6:
                    base = 0.17           # 环槽
                    hh = 0.30
            else:
                # 菱形防滑纹：45° 旋转晶格
                ax = ((x + y) % 24) - 12
                ay = ((x - y) % 24) - 12
                dd = ax * ax + ay * ay
                if dd < 46.0:             # 凸点
                    base = 0.38 + (g0 - 0.5) * 0.05
                    hh = 0.78
                else:                     # 底面
                    base = 0.20 + (g0 - 0.5) * 0.04
                    hh = 0.34
                # 同心环槽
                for rr in (34.0, 58.0):
                    if abs(r - rr) < 1.5 + wob[idx] * 0.8:
                        base = 0.15
                        hh = 0.22
                # 中心徽章
                if r < 24.0:
                    base = 0.33 + (g0 - 0.5) * 0.04
                    hh = 0.72
                    if abs(r - 16.0) < 1.4:
                        base = 0.18
                        hh = 0.35

            # 螺栓
            for bx, by in bolts:
                bdd = math.sqrt((x + 0.5 - bx) ** 2 + (y + 0.5 - by) ** 2)
                if bdd < 4.2:
                    base = 0.44
                    hh = 0.85 + (4.2 - bdd) * 0.03

            # 锈斑（暖棕偏移）
            rt = smooth01(0.66, 0.82, rust[idx])
            rc = base * (1.0 + 0.16 * rt)
            gc = base * (1.0 - 0.06 * rt)
            bc = base * (1.0 - 0.30 * rt)
            albedo[o] = int(clamp01(rc) * 255 + 0.5)
            albedo[o + 1] = int(clamp01(gc) * 255 + 0.5)
            albedo[o + 2] = int(clamp01(bc) * 255 + 0.5)
            albedo[o + 3] = int(alpha * 255 + 0.5)
            height[idx] = hh

    return albedo, normal_from_height(height, w, h, 2.6)


# ─────────────────────────── 主流程 ───────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    jobs: list[tuple[str, str, str, int, str, int]] = [
        # (文件名, 族, 角色, 尺寸, 输出通道, seed)
        ("cobble_albedo.png", "cobble", "albedo", 512, "albedo", 20261004),
        ("cobble_normal.png", "cobble", "normal", 512, "normal", 20261004),
        ("cobble_rough.png", "cobble", "rough", 512, "rough", 20261004),
        ("paving_albedo.png", "paving", "albedo", 512, "albedo", 20261005),
        ("paving_normal.png", "paving", "normal", 512, "normal", 20261005),
        ("paving_rough.png", "paving", "rough", 512, "rough", 20261005),
        ("granite_albedo.png", "granite", "albedo", 512, "albedo", 20261006),
        ("granite_normal.png", "granite", "normal", 512, "normal", 20261006),
        ("granite_rough.png", "granite", "rough", 512, "rough", 20261006),
        ("manhole_albedo.png", "manhole", "albedo", 256, "albedo", 20261007),
        ("manhole_normal.png", "manhole", "normal", 256, "normal", 20261007),
    ]

    textures: dict[str, dict] = {}
    for fname, family, role, size, kind, seed in jobs:
        if family == "cobble":
            a, n, r = gen_cobble(size, int(seed))
            buf = {"albedo": a, "normal": n, "rough": r}[kind]
        elif family == "paving":
            a, n, r = gen_paving(size, int(seed))
            buf = {"albedo": a, "normal": n, "rough": r}[kind]
        elif family == "granite":
            a, n, r = gen_granite(size, int(seed))
            buf = {"albedo": a, "normal": n, "rough": r}[kind]
        else:  # manhole
            a, n = gen_manhole(size, int(seed))
            buf = {"albedo": a, "normal": n}[kind]
        path = args.out / fname
        write_png(path, size, size, buf)
        data = path.read_bytes()
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        textures[rel] = {
            "path": rel,  # check_layout 三方核对要 path 字段（与 audio/assets 同款）
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "width": size,
            "height": size,
            "channels": 4,
            "family": family,
            "role": role,
            "generator_sha256": GENERATOR_SHA,
        }
        print(f"OK {fname} {size}x{size} {len(data)}B sha={textures[rel]['sha256'][:12]}")

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    manifest["textures"] = dict(sorted(textures.items()))
    manifest["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    args.manifest.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"manifest.textures 已更新: {len(textures)} 条（校验走 tools/check_glb.py）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
