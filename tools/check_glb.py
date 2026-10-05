#!/usr/bin/env python3
"""GLB 资产校验（P0-B2）

- 从 GLB 真实结构统计：字节数 / SHA256 / 三角形 / primitive / 材质 / 贴图尺寸
- 与 godot-project/data/assets_manifest.json 交叉核对：任何漂移 = 验收失效
- 预算（面数/体积/贴图）来自 manifest，超预算即失败

用法：
  python3 tools/check_glb.py                 # 校验（写 artifacts/glb-report.json）
  python3 tools/check_glb.py --update        # 用当前实测值重建 manifest（人工确认后执行）
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
    for f in failures:
        print(f"FAIL: {f}")
    print(f"check_glb: {'全部通过' if not failures else str(len(failures)) + ' 项失败'}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
