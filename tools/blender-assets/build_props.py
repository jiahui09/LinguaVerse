#!/usr/bin/env python3
"""build_props.py — P3 批次5 道具 GLB 库（10 件）

Blender headless 确定性生成，替换 street_furniture / street_generator 的原语道具
（决策 25 配套：街灯灯罩 + 配重柱身；GLB 过闸后拷入 godot-project/assets/models/）。

用法:
  tools/blender-4.2.8-linux-x64/blender --background --python tools/blender-assets/build_props.py

输出:
  artifacts/prop-glb/*.glb + report.json（逐件三角形/材质/体积）

坐标约定（核心，勿凭直觉写位置）:
  Godot (X, Y, Z) ←→ Blender (X, Z, -Y)，即 Blender 坐标 = Godot 绕 X 轴 +90°。
  助手 gbox/gcyl/gcone/gico 的尺寸与位置一律用 **Godot 空间**（脚底 y=0），
  内部换算；旋转: Godot 绕 X/Y 旋转 θ = Blender 绕 X/Z 同角（rot_gx/rot_gy 参数）。

面数纪律（决策 29: 单街 ≤25k, GLB 替换后复核定值; 单 GLB ≤8MiB）:
  逐件目标见 SOFT_CAP，超帽只告警——真正的预算断言在 street_check（单街合计）。
"""

import json
import math
import os
import sys

import bpy

# ---------- 材质 ----------
MATS = {}


def mat(name, color, rough=0.6, metal=0.0, emit=0.0, emit_color=(1, 1, 1)):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit > 0:
        bsdf.inputs["Emission Color"].default_value = (*emit_color, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emit
    MATS[name] = m
    return m


def _m(name):
    if name in MATS:
        return MATS[name]
    raise KeyError("未定义材质: " + name)


# ---------- Godot→Blender 助手 ----------
def _bpos(gpos):
    # Godot (x, y, z) → Blender (x, z, -y)
    return (gpos[0], -gpos[2], gpos[1])


def _finish(obj, name, mat_name, rot_gx=0.0, rot_gy=0.0):
    obj.name = name
    obj.data.materials.append(_m(mat_name))
    if rot_gx:
        obj.rotation_euler[0] = math.radians(rot_gx)   # Godot X = Blender X
    if rot_gy:
        obj.rotation_euler[2] = math.radians(rot_gy)   # Godot Y = Blender Z
    return obj


def gbox(name, gsize, gpos, mat_name, rot_gx=0.0, rot_gy=0.0):
    """长方体: gsize/gpos 均为 Godot 空间 (x,y,z)。"""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=_bpos(gpos))
    o = bpy.context.active_object
    o.scale = (gsize[0], gsize[2], gsize[1])            # Blender (x,z,y)
    return _finish(o, name, mat_name, rot_gx, rot_gy)


def gcyl(name, gr, gh, gpos, mat_name, seg=8, caps=True):
    """立式圆柱 (轴 = Godot Y)。"""
    kw = dict(vertices=seg, radius=gr, depth=gh, location=_bpos(gpos))
    if not caps:
        kw["end_fill_type"] = "NOTHING"
    bpy.ops.mesh.primitive_cylinder_add(**kw)
    return _finish(bpy.context.active_object, name, mat_name)


def gcone(name, r1, r2, gh, gpos, mat_name, seg=8):
    """圆锥台: r1=底(Godot 下端), r2=顶。"""
    bpy.ops.mesh.primitive_cone_add(
        vertices=seg, radius1=r1, radius2=r2, depth=gh, location=_bpos(gpos)
    )
    return _finish(bpy.context.active_object, name, mat_name)


def gico(name, gr, gpos, mat_name, gsx=1.0, gsy=1.0, gsz=1.0):
    """低多边形球 (icosphere subdiv1 = 80 三角形), gs* = Godot 轴向缩放。"""
    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=1, radius=gr, location=_bpos(gpos)
    )
    o = bpy.context.active_object
    o.scale = (gsx, gsz, gsy)
    return _finish(o, name, mat_name)


# ---------- 合并/导出/报告 ----------
OUT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "artifacts", "prop-glb")
)
REPORT = []
SOFT_CAPS = {
    "street_lamp": 170, "tree": 320, "bench": 200, "planter": 460,
    "bollard": 100, "barrier": 270, "tree_grate": 130, "hydrant": 140,
    "trash_bin": 130, "bistro_set": 240,
}


def _tris(o):
    return sum(max(0, len(p.vertices) - 2) for p in o.data.polygons)


def _clean():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def export_asset(filename):
    """join 当前场景全部 mesh → 导出单文件 GLB → 清场。"""
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise RuntimeError("无 mesh 可导出: " + filename)
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = os.path.splitext(filename)[0]

    out = os.path.join(OUT_DIR, filename)
    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
    )
    t = _tris(obj)
    mats = [s.name for s in obj.data.materials]
    size = os.path.getsize(out)
    cap = SOFT_CAPS.get(obj.name)
    warn = "  !! 超软帽 %d" % cap if cap and t > cap else ""
    print("PROP_BUILD %s tris=%d bytes=%d mats=%s%s"
          % (filename, t, size, ",".join(mats), warn))
    REPORT.append({
        "file": filename, "triangles": t, "bytes": size, "materials": mats,
        "soft_cap": cap, "over_cap": bool(cap and t > cap),
    })
    _clean()


# ================= 十件道具 (Godot 空间尺寸) =================

def a_street_lamp():
    """巴黎街灯: 配重柱身 + 六棱灯罩 (灯罩材质 lamp_glow 由 set_night_glow 驱动)。"""
    M = "lamp_metal"
    gcyl("base", 0.145, 0.30, (0, 0.15, 0), M, seg=8)            # 28
    gcone("column", 0.075, 0.048, 3.0, (0, 1.9, 0), M, seg=8)    # 28 柱身 0.4→3.4
    gcyl("weight", 0.095, 0.26, (0, 1.15, 0), M, seg=8)          # 28 配重鼓包
    gcyl("lantern_base", 0.15, 0.05, (0, 3.43, 0), M, seg=6)     # 20
    gcyl("glass", 0.125, 0.40, (0, 3.66, 0), "lamp_glow", seg=6, caps=False)  # 12
    gcyl("lantern_top", 0.15, 0.05, (0, 3.89, 0), M, seg=6)      # 20
    gcone("cap", 0.14, 0.018, 0.30, (0, 4.06, 0), M, seg=6)      # 20 尖顶含饰钮
    export_asset("street_lamp.glb")


def a_tree():
    """悬铃木修剪型: 锥台干 + 三球冠 (比原语 456 面省约 140)。"""
    gcone("root", 0.16, 0.11, 0.4, (0, 0.2, 0), "bark", seg=10)   # 36
    gcone("trunk", 0.115, 0.085, 2.2, (0, 1.5, 0), "bark", seg=10)  # 36
    gico("crown_a", 0.95, (0, 3.2, 0), "leaf", gsy=0.82)          # 80
    gico("crown_b", 0.75, (-0.5, 2.95, 0.3), "leaf")              # 80
    gico("crown_c", 0.8, (0.42, 3.5, -0.25), "leaf")              # 80
    export_asset("tree.glb")


def a_bench():
    """巴黎条板长椅: 5 座板 + 3 背板 + 铸铁腿框 (座 0.47 高, 靠背朝 +X)。"""
    W, I = "bench_wood", "bench_iron"
    for i, gx in enumerate((-0.18, -0.09, 0.0, 0.09, 0.18)):
        gbox("seat%d" % i, (0.075, 0.04, 1.6), (gx, 0.45, 0), W)   # 60
    for i, gy in enumerate((0.62, 0.76, 0.90)):
        gbox("back%d" % i, (0.05, 0.10, 1.6), (0.19, gy, 0), W)    # 36
    for gz in (-0.72, 0.72):
        gbox("post", (0.06, 0.5, 0.06), (0.19, 0.65, gz), I)       # 24
    for gz in (-0.7, 0.7):
        gbox("leg_f", (0.05, 0.45, 0.06), (-0.16, 0.225, gz), I)   # 24
        gbox("leg_b", (0.05, 0.45, 0.06), (0.17, 0.225, gz), I)    # 24
        gbox("apron", (0.4, 0.07, 0.07), (0.0, 0.42, gz), I)       # 24
    export_asset("bench.glb")


def a_planter():
    """自然端花坛石槽 4.3m: 石壁+压顶+土壤+三团灌木 (替换 2 盒原语)。"""
    S, L, D = "stone", "shrub_leaf", "soil"
    gbox("wall_fa", (4.3, 0.55, 0.07), (0, 0.275, 0.415), S)       # 12
    gbox("wall_fb", (4.3, 0.55, 0.07), (0, 0.275, -0.415), S)      # 12
    gbox("wall_s1", (0.07, 0.55, 0.76), (2.115, 0.275, 0), S)      # 12
    gbox("wall_s2", (0.07, 0.55, 0.76), (-2.115, 0.275, 0), S)     # 12
    # 压顶与墙外缘齐平 (4.3=墙宽, 侧压顶 0.07@±2.115) → 相邻花坛只在 x=±2.15 接缝
    # 点接触, 无共面重叠 (首版 4.44/±2.17 外挑 0.09 会与邻段压顶 0.14m z-fight)
    gbox("rim_a", (4.3, 0.07, 0.10), (0, 0.55, 0.42), S)             # 12
    gbox("rim_b", (4.3, 0.07, 0.10), (0, 0.55, -0.42), S)            # 12
    gbox("rim_s1", (0.07, 0.07, 0.74), (2.115, 0.55, 0), S)          # 12
    gbox("rim_s2", (0.07, 0.07, 0.74), (-2.115, 0.55, 0), S)         # 12
    gbox("soil", (4.1, 0.06, 0.72), (0, 0.50, 0), D)               # 12
    gico("shrub1", 0.5, (-1.35, 0.80, 0), L, gsy=0.62)             # 80
    gico("shrub2", 0.55, (0, 0.82, 0), L, gsy=0.62)                # 80
    gico("shrub3", 0.48, (1.35, 0.79, 0.05), L, gsy=0.62)          # 80
    export_asset("planter.glb")


def a_bollard():
    """石质护柱 1.10m (自然端花坛接缝, 替换 0.18 方盒)。"""
    S = "stone"
    gcyl("base", 0.13, 0.14, (0, 0.07, 0), S, seg=8)               # 28
    gcone("shaft", 0.075, 0.058, 0.8, (0, 0.54, 0), S, seg=8)      # 28
    gcone("cap", 0.085, 0.03, 0.16, (0, 1.02, 0), S, seg=8)        # 28
    export_asset("bollard.glb")


def a_barrier():
    """施工围栏 13m 跨: 3 横杆 + 13 红白条 + A 腿 ×4 + 告示板 (文字 Label3D 留 GDScript)。"""
    R, WH, F = "barrier_red", "barrier_white", "barrier_frame"
    for gy in (0.30, 0.70, 1.05):
        gbox("rail", (13.0, 0.10, 0.06), (0, gy, 0), F)            # 36
    for i in range(13):
        gx = -6.0 + float(i)
        gbox("stripe%d" % i, (1.0, 0.28, 0.05), (gx, 0.52, 0.055),
             R if i % 2 == 0 else WH)                               # 156
    for gx in (-5.2, 5.2):
        for gz in (-0.25, 0.25):
            gbox("leg", (0.09, 1.2, 0.09), (gx, 0.6, gz), F,
                 rot_gx=-20.0 * (1.0 if gz > 0 else -1.0))          # 48
    gbox("plate", (1.2, 0.8, 0.06), (0, 1.05, 0.10), WH)           # 12
    export_asset("barrier.glb")


def a_tree_grate():
    """树池铁篦 0.56²: 框+5 条栅+土壤面 (人行道 x∈[4.5,6], 树 x=4.78 → 外缘恰齐路缘)。"""
    I, D = "grate_iron", "soil"
    gbox("soil", (0.44, 0.02, 0.44), (0, 0.006, 0), D)              # 12
    gbox("frame_f", (0.56, 0.03, 0.06), (0, 0.02, 0.25), I)         # 12
    gbox("frame_b", (0.56, 0.03, 0.06), (0, 0.02, -0.25), I)        # 12
    gbox("frame_l", (0.06, 0.03, 0.44), (-0.25, 0.02, 0), I)        # 12
    gbox("frame_r", (0.06, 0.03, 0.44), (0.25, 0.02, 0), I)         # 12
    for gx in (-0.16, -0.08, 0.0, 0.08, 0.16):
        gbox("bar", (0.03, 0.028, 0.42), (gx, 0.02, 0), I)          # 60
    export_asset("tree_grate.glb")


def a_hydrant():
    """消防栓 0.80m 红 (街道两端步道边, 新增点缀)。"""
    H = "hydrant_red"
    gcyl("base", 0.12, 0.10, (0, 0.05, 0), H, seg=8)                # 28
    gcone("body", 0.085, 0.07, 0.5, (0, 0.35, 0), H, seg=8)         # 28
    gcone("dome", 0.075, 0.02, 0.14, (0, 0.67, 0), H, seg=8)        # 28
    gbox("nut", (0.05, 0.06, 0.05), (0, 0.77, 0), H)                # 12
    gbox("noz_l", (0.10, 0.08, 0.08), (-0.10, 0.45, 0), H)          # 12
    gbox("noz_r", (0.10, 0.08, 0.08), (0.10, 0.45, 0), H)           # 12
    export_asset("hydrant.glb")


def a_trash_bin():
    """垃圾桶 0.78m 绿 (路灯旁步道, 新增点缀)。"""
    G = "bin_green"
    gcyl("body", 0.17, 0.6, (0, 0.36, 0), G, seg=8)                 # 28
    gcyl("rim", 0.19, 0.05, (0, 0.685, 0), G, seg=8)                # 28
    gcone("lid", 0.18, 0.10, 0.09, (0, 0.75, 0), G, seg=8)          # 28
    gcyl("base", 0.14, 0.06, (0, 0.03, 0), G, seg=8)                # 28
    export_asset("trash_bin.glb")


def a_bistro_set():
    """咖啡馆外摆: 石圆桌 + 2 木椅 (仅 cafe_anchor 街)。"""
    T, I, W = "bistro_marble", "bistro_iron", "bench_wood"
    gcyl("table_top", 0.34, 0.035, (0, 0.72, 0), T, seg=10)         # 36
    gcyl("table_leg", 0.03, 0.68, (0, 0.36, 0), I, seg=6)           # 20
    gcyl("table_foot", 0.16, 0.03, (0, 0.015, 0), I, seg=6)         # 20
    for pz, s in ((0.85, 1.0), (-0.85, -1.0)):      # 两椅沿 Z, 背朝外
        gbox("seat", (0.4, 0.035, 0.4), (0, 0.46, pz), W)           # 12
        for dx, dz in ((-0.17, -0.17), (0.17, -0.17), (-0.17, 0.17), (0.17, 0.17)):
            gbox("cleg", (0.03, 0.45, 0.03), (dx, 0.225, pz + dz * s), I)  # 48
        gbox("cback", (0.36, 0.34, 0.03), (0, 0.72, pz + 0.19 * s), W)     # 12
    export_asset("bistro_set.glb")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    _clean()

    # 色板 (与 GDScript 原语色一致, 换装后观感连续)
    mat("lamp_metal", (0.07, 0.09, 0.08), rough=0.5, metal=0.6)
    mat("lamp_glow", (0.92, 0.86, 0.68), rough=0.4, emit=1.6,
        emit_color=(1.0, 0.85, 0.6))
    mat("bark", (0.33, 0.25, 0.19), rough=0.95)
    mat("leaf", (0.37, 0.44, 0.35), rough=0.9)
    mat("bench_wood", (0.45, 0.28, 0.15), rough=0.6)
    mat("bench_iron", (0.12, 0.13, 0.12), rough=0.5, metal=0.4)
    mat("stone", (0.74, 0.72, 0.68), rough=0.9)
    mat("shrub_leaf", (0.30, 0.45, 0.27), rough=0.9)
    mat("soil", (0.22, 0.17, 0.13), rough=1.0)
    mat("grate_iron", (0.16, 0.16, 0.17), rough=0.6, metal=0.5)
    mat("barrier_red", (0.72, 0.16, 0.13), rough=0.8)
    mat("barrier_white", (0.88, 0.86, 0.82), rough=0.8)
    mat("barrier_frame", (0.35, 0.36, 0.38), rough=0.6, metal=0.3)
    mat("hydrant_red", (0.75, 0.15, 0.10), rough=0.5)
    mat("bin_green", (0.14, 0.28, 0.18), rough=0.6)
    mat("bistro_marble", (0.90, 0.89, 0.86), rough=0.35)
    mat("bistro_iron", (0.10, 0.11, 0.10), rough=0.5, metal=0.5)

    for fn in (
        a_street_lamp, a_tree, a_bench, a_planter, a_bollard,
        a_barrier, a_tree_grate, a_hydrant, a_trash_bin, a_bistro_set,
    ):
        fn()

    with open(os.path.join(OUT_DIR, "report.json"), "w", encoding="utf-8") as f:
        json.dump(REPORT, f, ensure_ascii=False, indent=2)
    total = sum(r["triangles"] for r in REPORT)
    over = [r["file"] for r in REPORT if r["over_cap"]]
    print("PROP_DONE 件数=%d 三角形合计=%d 超帽=%s" % (len(REPORT), total, over or "无"))
    if over:
        sys.exit(2)   # 软帽超限 → 构建失败, 先调形再过闸


main()
