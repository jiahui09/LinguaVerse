#!/usr/bin/env python3
"""place_des_vosges.py — P3 批次7 首地标对象：Place des Vosges 对称红砖拱廊

五件套: data/landmarks/place_des_vosges/{job,prompt,evidence,model}.md + validation.json
状态机: tools/landmark_tasks.py (init → build here → 过闸拷入 → bind → validate)
决策 24/28: 首地标 = 对称红砖拱廊（不改选圣母院）；八项具名验收 browser 项降级 llvmpipe。

用法:
  tools/blender-4.2.8-linux-x64/blender --background \
      --python tools/blender/landmarks/place_des_vosges.py

输出: artifacts/landmark-glb/place_des_vosges.glb + report.json
面数软帽 1500（65k 三街总预算余量 ≈9.3k 留给批次 7/8）。

坐标约定（同 build_props）: Godot (X, Y, Z) ←→ Blender (X, Z, -Y)。
Godot 空间: 前立面 x=0（街在 +X），拱廊段沿 Z 展开 23.1m，脚底 y=0，总高 8.72m。

几何（对称 3 跨, vosges 布局空档 s=195.3..218.4, face=7.87）:
  中跨净宽 5.2 (z=±2.6), 侧跨净宽 4.2 (中心 z=±5.6), 墩 0.9 (z=±3.05, ±8.15)
  拱脚线 y=4.0; 环厚 0.45 → 中环外缘 3.05 = 墩心 (两拱券在墩心汇合, 真实拱廊构造)
  楔石 9 块/券; 拱肩回填 = 6 切片/墩 (外缘曲线保守取样, 残缝透后墙暗色不出天)
  后墙 x∈[-1.3,-1.15] 封洞 (拱廊进深 1.15m 视感)
  右端回墙接 Hôtel de Montmorin (face 13.07 → local x=-5.2, 错台 5.2m 收内凹转角)
  材质: brick 红砖 / stone 白石(券/檐/柱) / inner 洞内暗色
"""

import json
import math
import os
import sys

import bpy

# ---------- 材质 ----------
MATS = {}


def mat(name, color, rough=0.6, metal=0.0):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    MATS[name] = m
    return m


def _m(name):
    if name in MATS:
        return MATS[name]
    raise KeyError("未定义材质: " + name)


# ---------- Godot→Blender 助手 ----------
def _bpos(gpos):
    return (gpos[0], -gpos[2], gpos[1])


def _finish(obj, name, mat_name, rot_gx=0.0):
    obj.name = name
    obj.data.materials.append(_m(mat_name))
    if rot_gx:
        obj.rotation_euler[0] = math.radians(rot_gx)   # Godot X = Blender X
    return obj


def gbox(name, gsize, gpos, mat_name, rot_gx=0.0):
    """长方体: gsize/gpos 均为 Godot 空间 (x,y,z)。"""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=_bpos(gpos))
    o = bpy.context.active_object
    o.scale = (gsize[0], gsize[2], gsize[1])
    return _finish(o, name, mat_name, rot_gx)


# ---------- 场景常量 (Godot 空间) ----------
SPRING = 4.0            # 拱脚线
H = 8.72                # 总高 (檐口/压顶)
W_BODY = 17.2           # 主体宽 (z ∈ ±8.6)
Z_END = 11.55           # 半宽 (s0=195.3..s1=218.4 → 23.1m)
RING = 0.45             # 券环厚
N_VOUS = 9              # 每券楔石数
X_FRONT = 0.0           # 前立面 (街在 +X)
DEPTH = 1.2             # 墙厚 (x ∈ [-1.2, 0])

MID_HALF = 2.6          # 中跨净半宽
SIDE_C = 5.6            # 侧跨中心
SIDE_HALF = 2.1         # 侧跨净半宽
PIER = [3.05, 8.15]     # 墩中心 (中-侧墩, 侧-端墩)

# 切片高度 (拱肩回填, dy 相对拱脚)
SLICES = [0.0, 0.6, 1.2, 1.8, 2.4, 2.55, 3.05]


def _arc_mid(dy):
    v = (MID_HALF + RING) ** 2 - dy * dy
    return math.sqrt(v) if v > 0 else 0.0


def _arc_side_out(dy, sign):
    v = (SIDE_HALF + RING) ** 2 - dy * dy
    return SIDE_C + (math.sqrt(v) if v > 0 else 0.0) * sign


def _hole_mid(dy):
    v = MID_HALF ** 2 - dy * dy
    return math.sqrt(v) if v > 0 else 0.0


def _hole_side(dy, sign):
    v = SIDE_HALF ** 2 - dy * dy
    return SIDE_C + (math.sqrt(v) if v > 0 else 0.0) * sign


def build():
    mat("brick", (0.48, 0.22, 0.17), rough=0.92)
    mat("stone", (0.85, 0.82, 0.75), rough=0.8)
    mat("inner", (0.16, 0.14, 0.13), rough=0.95)

    # ===== 柱 (4 根: 墩心 z=±3.05, ±8.15) =====
    for zc in (PIER[0], -PIER[0], PIER[1], -PIER[1]):
        gbox("arc_col", (DEPTH, SPRING, 0.9), (-0.6, SPRING / 2.0, zc), "brick")
        gbox("arc_col_base", (1.45, 0.5, 1.15), (-0.575, 0.25, zc), "stone")
        gbox("arc_col_cap", (1.5, 0.3, 1.2), (-0.55, SPRING - 0.15, zc), "stone")

    # ===== 楔石券 (3 券: 中跨 + 双侧跨, 每券 9 块覆盖 0..180°) =====
    # 弦长按**外缘半径**取: 直边盒绕圆心刚体旋转时, 外缘点距 = 2·r_out·sin(Δ/2) —
    # 按 r_mid 取会让外缘张开 0.16m 缝 (内缘重叠不可见); 按 r_out 取则外缘贴合、
    # 内缘角点仍落在 r_in 圆上 (轮廓连续, 块体互插在内部不可见)。
    openings = [(0.0, MID_HALF), (SIDE_C, SIDE_HALF), (-SIDE_C, SIDE_HALF)]
    for zc, r_in in openings:
        r_mid = r_in + RING / 2.0
        r_out = r_in + RING
        chord = 2.0 * r_out * math.sin(math.pi / (2.0 * N_VOUS))
        for i in range(N_VOUS):
            phi = math.radians((i + 0.5) * 180.0 / N_VOUS)
            c, s = math.cos(phi), math.sin(phi)
            z = zc + r_mid * c
            y = SPRING + r_mid * s
            # 径向轴(本地 y)绕 X 转 θ 后 = (0, cosθ, sinθ) ≡ 径向 (0, sinφ, cosφ)
            # → θ = 90−φ, **全环统一** (含 φ>90 的左半: cos(90−φ)=sinφ ✓ sin(90−φ)=cosφ
            # 对 φ=150 也成立 cos(-60)=0.5 sin(-60)=-0.866 ✓; 分支写 φ−90 会把半环姿态反号)
            rot = 90.0 - math.degrees(phi)
            gbox("arc_voussoir", (DEPTH, RING, chord), (-0.6, y, z), "stone", rot_gx=rot)
        # 拱心石 (白石, 高出环面凸出 0.18 — 真实拱廊楔入环顶)
        gbox("arc_keystone", (1.38, 0.7, 0.66),
             (-0.51, SPRING + r_in + RING / 2.0, zc), "stone")

    # ===== 拱肩回填切片 (4 区: 2 内墩 + 2 端区; 每区 6 片, x 前脸 -0.1 内凹) =====
    for sign in (1.0, -1.0):
        # 内墩 (中-侧): 左界=中环外缘, 右界=min(侧环外缘, 侧洞缘)
        for k in range(len(SLICES) - 1):
            d0, d1 = SLICES[k], SLICES[k + 1]
            L = max(_arc_mid(d1), _hole_mid(d0))
            R = min(_arc_side_out(d1, -1.0),
                    _hole_side(d0, -1.0) if d0 < 2.1 else 1e9)
            if d1 > 2.55:
                R = 3.5   # 接侧跨拱顶填块左缘 (3.5), 避免与之同面 z-fight
            R = R * sign
            L = L * sign
            lo, hi = (L, R) if sign > 0 else (R, L)
            gbox("arc_spandrel", (DEPTH, d1 - d0, hi - lo),
                 (-0.65, SPRING + (d0 + d1) / 2.0, (lo + hi) / 2.0), "brick")
        # 端区 (侧-端柱外到翼墙 z=8.6): 左界=侧环外缘, 右界=8.6
        for k in range(len(SLICES) - 1):
            d0, d1 = SLICES[k], SLICES[k + 1]
            if d1 > 2.55:
                lo = 7.7
            else:
                lo = max(_arc_side_out(d1, 1.0), _hole_side(d0, 1.0) if d0 < 2.1 else 0.0)
            hi = 8.6
            lo, hi = lo * sign, hi * sign
            a, b = (lo, hi) if sign > 0 else (hi, lo)
            gbox("arc_spandrel", (DEPTH, d1 - d0, b - a),
                 (-0.65, SPRING + (d0 + d1) / 2.0, (a + b) / 2.0), "brick")

    # ===== 侧跨拱顶以上砖填 (y 6.55..7.05) + 全宽砖带 (7.05..7.45) =====
    for sign in (1.0, -1.0):
        gbox("arc_side_fill", (DEPTH, 0.5, 2 * SIDE_HALF),
             (-0.6, SPRING + SIDE_HALF + RING + 0.25, sign * SIDE_C), "brick")
    gbox("arc_band", (DEPTH, 0.4, W_BODY), (-0.6, 7.25, 0.0), "brick")

    # ===== 后墙 (封洞, 拱廊进深 1.15m) =====
    gbox("arc_backwall", (0.15, 7.05, W_BODY), (-1.225, 3.525, 0.0), "inner")

    # ===== 檐口双带 / 女儿墙 / 压顶 (主体) =====
    gbox("arc_cornice1", (1.5, 0.17, W_BODY + 0.35), (-0.6, 7.535, 0.0), "stone")
    gbox("arc_cornice2", (1.35, 0.16, W_BODY + 0.6), (-0.6, 7.70, 0.0), "stone")
    gbox("arc_parapet", (DEPTH, 0.82, W_BODY), (-0.6, 8.19, 0.0), "brick")
    gbox("arc_cap", (1.3, 0.12, W_BODY + 0.3), (-0.6, 8.66, 0.0), "stone")

    # ===== 基座 / 台阶 (主体 + 两翼) =====
    gbox("arc_base", (1.45, 0.4, W_BODY), (-0.575, 0.2, 0.0), "stone")
    gbox("arc_step", (1.7, 0.1, W_BODY), (-0.45, 0.05, 0.0), "stone")

    # ===== 翼墙 (左: 接 Pavillon du Roi 同线; 右: 接错台回墙) =====
    left_c = -(8.6 + Z_END) / 2.0
    left_w = Z_END - 8.6                      # 2.95
    right_w = 10.95 - 8.6                     # 2.35
    right_c = (8.6 + 10.95) / 2.0
    for zc, w in ((left_c, left_w), (right_c, right_w)):
        gbox("arc_wing", (DEPTH, H, w), (-0.6, H / 2.0, zc), "brick")
        gbox("arc_wing_base", (1.45, 0.4, w), (-0.575, 0.2, zc), "stone")
        gbox("arc_wing_step", (1.7, 0.1, w), (-0.45, 0.05, zc), "stone")
        gbox("arc_wing_c1", (1.5, 0.17, w), (-0.6, 7.535, zc), "stone")
        gbox("arc_wing_c2", (1.35, 0.16, w), (-0.6, 7.70, zc), "stone")
        gbox("arc_wing_cap", (1.3, 0.12, w + 0.3), (-0.6, 8.66, zc), "stone")

    # ===== 右端回墙 (face 7.87 → 13.07, 错台 5.2m 接 Montmorin) =====
    gbox("arc_return", (5.2, H, 0.6), (-2.6, H / 2.0, 11.25), "brick")
    gbox("arc_return_base", (5.2, 0.4, 1.45), (-2.6, 0.2, 11.25), "stone")
    gbox("arc_return_c2", (5.4, 0.16, 1.0), (-2.5, 7.70, 11.2), "stone")
    gbox("arc_return_cap", (5.4, 0.12, 1.3), (-2.5, 8.66, 11.2), "stone")


# ---------- 导出/报告 ----------
OUT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "artifacts", "landmark-glb")
)
FILE = "place_des_vosges.glb"
SOFT_CAP = 1500


def _tris(o):
    return sum(max(0, len(p.vertices) - 2) for p in o.data.polygons)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.ops.mesh.primitive_cube_add()   # 清过场 (确保无残留)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()

    build()

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise RuntimeError("无 mesh 可导出")
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = "place_des_vosges"

    out = os.path.join(OUT_DIR, FILE)
    bpy.ops.export_scene.gltf(
        filepath=out, export_format="GLB", use_selection=True, export_yup=True
    )
    t = _tris(obj)
    mats = [s.name for s in obj.data.materials]
    rep = {
        "file": FILE,
        "triangles": t,
        "materials": mats,
        "bytes": os.path.getsize(out),
        "soft_cap": SOFT_CAP,
        "over_cap": t > SOFT_CAP,
        "parts": len(meshes),
    }
    with open(os.path.join(OUT_DIR, "report.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=2)
    print("LANDMARK_DONE %s triangles=%d materials=%s over=%s"
          % (FILE, t, ",".join(mats), rep["over_cap"]))
    if rep["over_cap"]:
        sys.exit(2)


main()
