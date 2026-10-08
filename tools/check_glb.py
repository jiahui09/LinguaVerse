#!/usr/bin/env python3
"""GLB 资产校验（P0-B2）+ 贴图校验（P3 批次4）

- 从 GLB 真实结构统计：字节数 / SHA256 / 三角形 / primitive / 材质 / 贴图尺寸
- 与 godot-project/data/assets_manifest.json 交叉核对：任何漂移 = 验收失效
- 预算（面数/体积/贴图）来自 manifest，超预算即失败
- 贴图段（manifest.textures，由 tools/make_textures.py 唯一写入）：
    · PNG 完整解码（zlib + 逐行反滤波）→ 尺寸/哈希/体积交叉核对
    · ≤2048² 且 2 的幂；非纯色（RGB 人口标准差 ≥ 阈值）
    · 法线贴图 +Z 约定（B 通道均值 ≥ 200）；井盖 alpha 含透明边
    · 族别齐全：cobble/paving/granite 需 albedo+normal+rough；manhole 需 albedo+normal
    · 目录孤儿文件（存在但未入清单）= 漂移

用法：
  python3 tools/check_glb.py                 # 校验（写 artifacts/glb-report.json）
  python3 tools/check_glb.py --update        # 用当前实测值重建 GLB 基线（人工确认后执行）
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "godot-project/data/assets_manifest.json"
DEFAULT_REPORT = ROOT / "artifacts/glb-report.json"

DEFAULT_BUDGETS = {
    "max_glb_bytes": 8 * 1024 * 1024,   # 单 GLB ≤ 8 MiB
    "max_texture_px": 2048,             # 贴图边长 ≤ 2048
    "max_cafe_faces": 20000,            # 室内精模 ≤ 20k 面
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def texture_size(data: bytes) -> tuple[int, int] | tuple[None, None]:
    """从嵌入的图片字节解析尺寸（PNG / JPEG）。"""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        w, h = struct.unpack(">II", data[16:24])
        return w, h
    if data[:2] == b"\xff\xd8":  # JPEG：扫描 SOF 段
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", data[i + 5 : i + 9])
                return w, h
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg_len = struct.unpack(">H", data[i + 2 : i + 4])[0]
            i += 2 + seg_len
    return None, None


def measure(glb_path: Path) -> dict:
    raw = glb_path.read_bytes()
    magic, version, _length = struct.unpack("<III", raw[:12])
    if magic != 0x46546C67:
        raise ValueError(f"{glb_path} 不是 GLB 文件")

    off, gltf = 12, None
    while off < len(raw):
        clen, ctype = struct.unpack("<II", raw[off : off + 8])
        off += 8
        chunk = raw[off : off + clen]
        off += clen
        if ctype == 0x4E4F534A:  # JSON
            gltf = json.loads(chunk)
        elif ctype == 0x004E4942:  # BIN
            bin_chunk = chunk
    if gltf is None:
        raise ValueError(f"{glb_path} 缺少 JSON chunk")

    triangles = primitives = 0
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            primitives += 1
            pos = gltf["accessors"][prim["attributes"]["POSITION"]]
            if "indices" in prim:
                count = gltf["accessors"][prim["indices"]]["count"]
            else:
                count = pos["count"]
            triangles += count // 3

    # 贴图尺寸（嵌入 bufferView 或外部 uri）
    images = gltf.get("images", [])
    texture_max = None
    for img in images:
        w, h = None, None
        if "bufferView" in img:
            bv = gltf["bufferViews"][img["bufferView"]]
            start = bv.get("byteOffset", 0)
            data = bin_chunk[start : start + bv["byteLength"]]
            w, h = texture_size(data)
        elif img.get("uri", "").startswith("data:"):
            continue
        if w and h:
            texture_max = max(texture_max or 0, w, h)

    return {
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "triangles": triangles,
        "primitives": primitives,
        "materials": len(gltf.get("materials", [])),
        "images": len(images),
        "texture_max_px": texture_max,
        "generator": gltf.get("asset", {}).get("generator", ""),
        "gltf_version": version,
    }


# ─────────────────── 贴图段校验（P3 批次4）───────────────────

REQUIRED_FAMILIES = {
    "cobble": {"albedo", "normal", "rough"},
    "paving": {"albedo", "normal", "rough"},
    "granite": {"albedo", "normal", "rough"},
    "manhole": {"albedo", "normal"},
}


def decode_png_rgba(data: bytes) -> tuple[int, int, list[int]]:
    """完整解码 PNG（8bit, 非隔行）→ (w, h, RGBA 字节)。覆盖 filter0-4。"""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG")
    import zlib as _zlib

    w = h = None
    color_type = bit_depth = None
    idat = bytearray()
    off = 8
    while off + 8 <= len(data):
        ln, tag = struct.unpack(">I4s", data[off : off + 8])
        off += 8
        chunk = data[off : off + ln]
        off += ln + 4  # 数据后跟 4 字节 CRC，必须一并跳过
        if tag == b"IHDR":
            w, h = struct.unpack(">II", chunk[:8])
            bit_depth, color_type, _comp, _filt, interlace = struct.unpack(">BBBBB", chunk[8:13])
            if interlace != 0:
                raise ValueError("不支持隔行 PNG")
            if bit_depth != 8 or color_type not in (0, 2, 6):
                raise ValueError(f"不支持 PNG 格式 depth={bit_depth} color={color_type}")
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break
    if w is None:
        raise ValueError("缺 IHDR")
    channels = {0: 1, 2: 3, 6: 4}[color_type]
    raw = _zlib.decompress(bytes(idat))
    stride = w * channels
    out = bytearray(w * h * channels)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        if ftype == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ftype == 3:  # Average
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif ftype != 0:
            raise ValueError(f"未知 PNG filter {ftype}")
        out[y * stride : (y + 1) * stride] = line
        prev = line
    if channels == 4:
        return w, h, list(out)
    rgba = bytearray(w * h * 4)
    if channels == 1:
        for i in range(w * h):
            v = out[i]
            rgba[i * 4 : i * 4 + 4] = bytes((v, v, v, 255))
    else:  # RGB
        for i in range(w * h):
            rgba[i * 4 : i * 4 + 4] = bytes((out[i * 3], out[i * 3 + 1], out[i * 3 + 2], 255))
    return w, h, list(rgba)


def check_textures(manifest: dict, budgets: dict, failures: list[str]) -> list[str]:
    """校验 manifest.textures；返回逐条 PASS 行。"""
    lines: list[str] = []
    textures = manifest.get("textures", {})
    if not textures:
        failures.append("textures: 清单为空（先跑 tools/make_textures.py）")
        return lines

    seen_family: dict[str, set[str]] = {}
    for rel, exp in sorted(textures.items()):
        path = ROOT / rel
        if not path.exists():
            failures.append(f"{rel}: 贴图缺失（manifest 记录存在但文件已删）")
            continue
        data = path.read_bytes()
        got_sha = hashlib.sha256(data).hexdigest()
        if exp.get("sha256") != got_sha:
            failures.append(f"{rel}: sha256 漂移（记录 {str(exp.get('sha256'))[:12]} → 实测 {got_sha[:12]}），重新生成=旧验收失效")
        if exp.get("bytes") != len(data):
            failures.append(f"{rel}: 体积漂移（记录 {exp.get('bytes')} → 实测 {len(data)}）")
            continue
        try:
            w, h, px = decode_png_rgba(data)
        except Exception as e:  # noqa: BLE001 — 解码失败即验收失败
            failures.append(f"{rel}: PNG 解码失败 ({e})")
            continue
        if (w, h) != (exp.get("width"), exp.get("height")):
            failures.append(f"{rel}: 尺寸漂移（记录 {exp.get('width')}×{exp.get('height')} → 实测 {w}×{h}）")
        for dim, name in ((w, "width"), (h, "height")):
            if dim > budgets["max_texture_px"]:
                failures.append(f"{rel}: {name} {dim}px > 预算 {budgets['max_texture_px']}px")
            if dim & (dim - 1) != 0:
                failures.append(f"{rel}: {name} {dim} 非 2 的幂（平铺/压缩需 POT）")

        # 非纯色：RGB 人口标准差（透明像素不计入，避免井盖黑底拉方差）
        n_op = 0
        sr = sg = sb = 0.0
        sr2 = sg2 = sb2 = 0.0
        b_sum = 0
        alpha_partial = 0
        for i in range(0, len(px), 4):
            if px[i + 3] < 8:
                continue
            n_op += 1
            r, g, b = px[i], px[i + 1], px[i + 2]
            sr += r
            sg += g
            sb += b
            sr2 += r * r
            sg2 += g * g
            sb2 += b * b
            if px[i + 3] < 250:
                alpha_partial += 1
            if exp.get("role") == "normal":
                b_sum += b
        if n_op == 0:
            failures.append(f"{rel}: 全透明/空图")
            continue

        def _std(s: float, s2: float) -> float:
            mean = s / n_op
            return (s2 / n_op - mean * mean) ** 0.5

        std_max = max(_std(sr, sr2), _std(sg, sg2), _std(sb, sb2))
        if std_max < 2.0:
            failures.append(f"{rel}: 疑似纯色图（RGB std={std_max:.2f} < 2.0）")

        role = exp.get("role", "")
        if role == "normal" and b_sum / n_op < 200:
            failures.append(f"{rel}: 法线 B 通道均值 {b_sum / n_op:.0f} < 200（+Z 约定被破坏）")
        if exp.get("family") == "manhole" and role == "albedo" and alpha_partial == 0:
            failures.append(f"{rel}: 井盖 albedo 无透明边（圆形贴片应带 AA 边）")

        fam = exp.get("family", "?")
        seen_family.setdefault(fam, set()).add(role)
        lines.append(
            f"PASS: {rel} {len(data)}B sha={got_sha[:12]} {w}x{h} std={std_max:.1f}"
        )

    for fam, need in REQUIRED_FAMILIES.items():
        have = seen_family.get(fam, set())
        missing = need - have
        if missing:
            failures.append(f"textures/{fam}: 族别不齐（缺 {sorted(missing)}）")
        else:
            lines.append(f"PASS: textures/{fam} 族别齐全 {sorted(have)}")

    # 目录孤儿：文件在、清单无 = 未受控
    tex_dir = ROOT / "godot-project/assets/textures"
    if tex_dir.is_dir():
        for f in sorted(tex_dir.glob("*.png")):
            rel = str(f.relative_to(ROOT)).replace("\\", "/")
            if rel not in textures:
                failures.append(f"{rel}: 孤儿贴图（存在但未入 manifest.textures）")
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    ap.add_argument("--update", action="store_true", help="用当前实测值重建 manifest")
    args = ap.parse_args()

    if not args.manifest.exists() and not args.update:
        print(f"FAIL: manifest 不存在（先运行 --update 生成基线）: {args.manifest}")
        return 1

    manifest = (
        json.loads(args.manifest.read_text(encoding="utf-8"))
        if args.manifest.exists()
        else {"budgets": DEFAULT_BUDGETS, "assets": {}}
    )
    budgets = {**DEFAULT_BUDGETS, **manifest.get("budgets", {})}
    assets = manifest.setdefault("assets", {})

    # 校验对象：--update 时扫描仓库里的 GLB 并入 manifest 已记录项；否则以 manifest 为准
    if args.update:
        discovered = {
            str(p.relative_to(ROOT)).replace("\\", "/")
            for p in (ROOT / "godot-project/assets/models").glob("*.glb")
        }
        targets = sorted(discovered | set(assets))
    else:
        targets = sorted(assets)

    failures: list[str] = []
    measured_all: dict[str, dict] = {}

    for rel in targets:
        path = ROOT / rel
        if not path.exists():
            failures.append(f"{rel}: 文件缺失（manifest 记录存在但文件已删）")
            continue
        measured = measure(path)
        measured_all[rel] = measured

        if args.update:
            assets[rel] = {k: v for k, v in measured.items() if v is not None}
            continue

        expected = assets.get(rel, {})
        for key in ("bytes", "sha256", "triangles", "materials"):
            if expected.get(key) != measured[key]:
                failures.append(f"{rel}: {key} 漂移（记录 {expected.get(key)} → 实测 {measured[key]}），旧验收失效")

    # 预算（对实测值一律检查，无论校验还是重建）
    for rel, m in measured_all.items():
        if m["bytes"] > budgets["max_glb_bytes"]:
            failures.append(f"{rel}: 体积 {m['bytes']} > 预算 {budgets['max_glb_bytes']}")
        if m.get("texture_max_px") and m["texture_max_px"] > budgets["max_texture_px"]:
            failures.append(f"{rel}: 贴图 {m['texture_max_px']}px > 预算 {budgets['max_texture_px']}px")
        if "cafe" in rel and m["triangles"] > budgets["max_cafe_faces"]:
            failures.append(f"{rel}: 面数 {m['triangles']} > 预算 {budgets['max_cafe_faces']}")

    # 贴图段（两种模式都校验：生成器只写清单，校验器只读）
    tex_lines = check_textures(manifest, budgets, failures)

    if args.update and not failures:
        manifest["budgets"] = budgets
        manifest["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"manifest 已重建: {args.manifest}（{len(assets)} 个资产）")
    elif args.update and failures:
        print("存在失败项，manifest 未写入")

    report = {
        "tool": "check_glb",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "manifest": str(args.manifest.relative_to(ROOT)),
        "budgets": budgets,
        "measured": measured_all,
        "textures": manifest.get("textures", {}),
        "failures": failures,
        "ok": not failures,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    for rel, m in measured_all.items():
        print(
            f"{'FAIL' if any(rel in f for f in failures) else 'PASS'}: {rel} "
            f"{m['bytes']}B sha={m['sha256'][:12]} 三角形={m['triangles']} 材质={m['materials']}"
        )
    for line in tex_lines:
        print(line)
    for f in failures:
        print(f"FAIL: {f}")
    print(f"check_glb: {'全部通过' if not failures else str(len(failures)) + ' 项失败'}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
