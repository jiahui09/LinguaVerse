#!/usr/bin/env python3
"""check_layout.py — 布局/资产清单三方核对 (P3 批次1 新工具)。

三方 = assets_manifest.json 记录 == 磁盘文件 == 目录扫描登记:
  1. 清单==磁盘: 每个带 path/bytes/sha256 的条目 (blocks 布局 / assets 模型 /
     audio 音频 / textures 贴图) 实测磁盘 sha256 与字节数, 逐一比对。
  2. 目录==清单: 对应目录下的每个产物文件必须已登记 (反向防漏 —
     "文件变了/新增了但记录没更新" 同样失败)。
  3. 预算: 单 GLB ≤ budgets.max_glb_bytes; 贴图 ≤ max_texture_px² (PNG IHDR)。
  4. blocks 子系统: 每块必须登记 5 个子系统 hash (键集合核对, 值的
     运行时重算由 street_check 断言负责 — 分层不重复)。

verify.sh 集成: 并入 street_check 步骤 (bash -c 链), 保持十步入口不变。
退出码: 0=全绿, 1=任一核对失败。确定性纯标准库 (无 numpy/PIL 依赖)。
"""
import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MF = ROOT / "godot-project" / "data" / "assets_manifest.json"

SUBSYSTEMS = {
    "road_surface", "street_furniture", "planting", "building_signs", "road_names",
}

# 目录 → 收集后缀 → 清单登记段 (None = 该段不存在时视为漏登记)
SWEEP = [
    (ROOT / "godot-project" / "data" / "layouts", ("*.json",), "blocks"),
    (ROOT / "godot-project" / "assets" / "models", ("*.glb",), "assets"),
    (ROOT / "godot-project" / "assets" / "audio", ("*.wav",), "audio"),
    (ROOT / "godot-project" / "assets" / "textures", ("*.png",), "textures"),
]

ok_count = 0
fail_count = 0


def say(cond: bool, msg: str) -> bool:
    global ok_count, fail_count
    if cond:
        ok_count += 1
        print(f"[OK]   {msg}")
    else:
        fail_count += 1
        print(f"[FAIL] {msg}")
    return cond


def sha256_of(path: Path) -> tuple:
    data = path.read_bytes()
    return hashlib.sha256(data).hexdigest(), len(data)


def png_size(path: Path) -> tuple:
    """读 PNG IHDR 拿宽高 (stdlib; 非 PNG 返回 (0,0))。"""
    try:
        with path.open("rb") as f:
            head = f.read(24)
        if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
            return 0, 0
        w, h = struct.unpack(">II", head[16:24])
        return w, h
    except OSError:
        return 0, 0


def walk_entries(mf: dict):
    """遍历全部带 path/bytes/sha256 的条目, 产出 (段, 名称, 条目dict)。"""
    for name, blk in mf.get("blocks", {}).items():
        lay = blk.get("layout", {})
        if "path" in lay:
            yield "blocks", f"blocks.{name}.layout", lay
    for key, ent in mf.get("assets", {}).items():
        # assets 段以文件路径为键, 无独立 path 字段 → 用键补全
        ent2 = dict(ent)
        ent2.setdefault("path", key)
        yield "assets", key, ent2
    for name, ent in mf.get("audio", {}).items():
        yield "audio", f"audio.{name}", ent
    for name, ent in mf.get("textures", {}).items():
        yield "textures", f"textures.{name}", ent


def main() -> int:
    if not MF.is_file():
        print(f"[FAIL] manifest 不存在: {MF}")
        return 1
    mf = json.loads(MF.read_text(encoding="utf-8"))
    budgets = mf.get("budgets", {})
    max_glb = int(budgets.get("max_glb_bytes", 8 * 1024 * 1024))
    max_px = int(budgets.get("max_texture_px", 2048))

    # ── 1) 清单==磁盘 (+预算) ──
    declared_paths = set()
    for section, label, ent in walk_entries(mf):
        rel = str(ent.get("path", ""))
        if not say(bool(rel), f"{label}: 条目有 path"):
            continue
        p = ROOT / rel
        if not say(p.is_file(), f"{label}: 磁盘存在 ({rel})"):
            continue
        declared_paths.add(rel)
        sha, nbytes = sha256_of(p)
        say(str(ent.get("sha256", "")) == sha,
            f"{label}: sha256 清单==磁盘 ({sha[:16]}…)")
        say(int(ent.get("bytes", -1)) == nbytes,
            f"{label}: bytes 清单==磁盘 ({nbytes})")
        if section == "assets":
            say(nbytes <= max_glb, f"{label}: ≤ {max_glb} B 预算 (实 {nbytes})")
        if section == "textures":
            w, h = png_size(p)
            say(w > 0 and w <= max_px and h <= max_px,
                f"{label}: 贴图 {w}×{h} ≤ {max_px}²")

    # ── 2) 目录==清单 (反向防漏) ──
    for directory, patterns, section in SWEEP:
        if not directory.is_dir():
            continue
        seen = set()
        for pat in patterns:
            for f in sorted(directory.rglob(pat)):
                rel = str(f.relative_to(ROOT))
                seen.add(rel)
                say(rel in declared_paths, f"目录登记: {rel} ∈ manifest.{section}")
        for rel in sorted(declared_paths):
            if (ROOT / rel).parent.is_relative_to(directory):
                say(rel in seen, f"清单条目存在于扫描目录: {rel}")

    # ── 3) blocks 子系统键集合 ──
    blocks = mf.get("blocks", {})
    say(bool(blocks), "manifest.blocks 非空")
    for name, blk in blocks.items():
        subs = set(blk.get("subsystems", {}).keys())
        say(subs == SUBSYSTEMS,
            f"blocks.{name}: 5 子系统键集合一致 (缺 {sorted(SUBSYSTEMS - subs) or '无'}"
            f" / 多 {sorted(subs - SUBSYSTEMS) or '无'})")

    print(f"\ncheck_layout: {ok_count} OK / {fail_count} FAIL")
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
