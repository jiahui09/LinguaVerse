#!/usr/bin/env python3
"""build_npcs.py — P3 批次8 NPC 外观模型 GLB（决策 27：弃胶囊+球眼）

Blender headless 确定性生成 5 件人物模型，参数化变体（服装/发型/帽/裙/围裙）。
用法:
  tools/blender-4.2.8-linux-x64/blender --background --python tools/blender-assets/build_npcs.py

输出:
  artifacts/npc-glb/*.glb + report.json

坐标约定（与 build_props 一致）:
  Godot (X, Y, Z) ←→ Blender (X, Z, -Y)；助手尺寸/位置一律 Godot 空间（脚底 y=0）。
  Godot 前向 = -Z（面朝 -Z），眼/鼻/鞋头在 z 负侧。

部件分层（决策 27 骨骼步行动作时间盒 → 程序摆动降级，边界如实记录）:
  每件 6 个部件对象（Head/Torso/ArmL/ArmR/LegL/LegR），部件内部 join 成单 mesh，
  origin 移到**关节枢轴**（肩/髋/颈）→ Godot 里直接转 rotation.x 即可摆臂迈腿。
  不 join 成单 mesh：glTF 按对象导出节点层级，Node 名 = Blender 对象名。

中等圆润化（真机反馈"更写实而不是方块人"，用户选档 600–800 面/件）:
  方块躯干 → 低段位圆台收分（肩宽腰细/腕细），头/手 → UV 球，四肢 → 圆台，
  鼻 → 小球；鞋/围裙/帽檐仍为低面盒体（贴图五官不做——小几何五官更立体）。
  面数控制靠段位（球 seg/rings、柱 seg 6–12），目标每件 600–800 tris。
  六部件结构与关节枢轴（颈 1.44/肩 1.43/髋 0.92）不变 → npc_base 摆动兼容。
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


def _bpos(gpos):
    # Godot (x, y, z) → Blender (x, z, -y)
    return (gpos[0], -gpos[2], gpos[1])


def _finish(obj, name, mat_name, rot_gx=0.0, rot_gy=0.0):
    obj.name = name
    obj.data.materials.append(_m(mat_name))
    if rot_gx:
        obj.rotation_euler[0] = math.radians(rot_gx)
    if rot_gy:
        obj.rotation_euler[2] = math.radians(rot_gy)
    return obj


def gbox(name, gsize, gpos, mat_name, rot_gx=0.0, rot_gy=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=_bpos(gpos))
    o = bpy.context.active_object
    o.scale = (gsize[0], gsize[2], gsize[1])
    return _finish(o, name, mat_name, rot_gx, rot_gy)


def gcyl(name, gr, gh, gpos, mat_name, seg=8, caps=True, scale_xz=(1.0, 1.0)):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=seg, radius=gr, depth=gh, end_fill_type="NGON" if caps else "NOTHING",
        location=_bpos(gpos))
    o = bpy.context.active_object
    # Blender z=高(Godot y)；xz 平面两轴 = Godot x/z
    o.scale = (scale_xz[0], scale_xz[1], 1.0)
    return _finish(o, name, mat_name)


def gsphere(name, gr, gpos, mat_name, seg=12, rings=7, scale=(1.0, 1.0, 1.0)):
    """UV 球（中等圆润化）。scale=(gx, gy, gz)；seg·rings 控面数。"""
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=seg, ring_count=rings, radius=gr, location=_bpos(gpos))
    o = bpy.context.active_object
    o.scale = scale
    return _finish(o, name, mat_name)


def gcone(name, r_bot, r_top, gh, gpos, mat_name, seg=8, caps=True):
    """圆台（radius1=底/Godot 下端, radius2=顶/Godot 上端）——四肢/躯干收分。"""
    bpy.ops.mesh.primitive_cone_add(
        vertices=seg, radius1=r_bot, radius2=r_top, depth=gh,
        end_fill_type="NGON" if caps else "NOTHING", location=_bpos(gpos))
    o = bpy.context.active_object
    return _finish(o, name, mat_name)


def _tris(o):
    return sum(max(0, len(p.vertices) - 2) for p in o.data.polygons)


def _clean():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def _join_part(part_name, objs, pivot_g):
    """部件内部 join；origin 移到关节枢轴 pivot_g（Godot 空间）。"""
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = part_name
    # origin → 枢轴（Cursor 方式，Godot 空间换算）
    bpy.context.scene.cursor.location = _bpos(pivot_g)
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    return obj


OUT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "artifacts", "npc-glb")
)
REPORT = []
SOFT_CAP = 800  # 单件软帽（决策29 GLB 8MiB 是硬线；中等圆润化档 600–800 面只告警）

# ---------------- 变体参数（5 件） ----------------
# top: 上衣/大衣色  bottom: 下装  hair: 发色  skin: 肤色  shoe: 鞋
# mode: 大衣下摆 / 裙 / 围裙;  hat: fedora / flat / beret / none;  scarf: 颈巾
VARIANTS = {
    "npc_marie": dict(   # 服务员：白衬衫+黑裤+小帽+围裙
        top=(0.93, 0.91, 0.87), bottom=(0.13, 0.13, 0.15), hair=(0.35, 0.24, 0.15),
        skin=(0.87, 0.71, 0.60), shoe=(0.10, 0.10, 0.11),
        mode="apron", hat="none", scarf=False, skirt=False),
    "npc_pierre": dict(  # 行人：蓝灰夹克
        top=(0.33, 0.42, 0.53), bottom=(0.24, 0.25, 0.27), hair=(0.20, 0.15, 0.11),
        skin=(0.85, 0.68, 0.57), shoe=(0.14, 0.12, 0.11),
        mode="coat", hat="none", scarf=False, skirt=False),
    "npc_jean": dict(    # 老人：棕大衣+fedora+围巾
        top=(0.44, 0.34, 0.26), bottom=(0.26, 0.24, 0.22), hair=(0.75, 0.74, 0.70),
        skin=(0.83, 0.67, 0.56), shoe=(0.15, 0.13, 0.12),
        mode="coat", hat="fedora", scarf=True, skirt=False),
    "npc_colette": dict(  # 居民：酒红上衣+裙+发髻
        top=(0.55, 0.26, 0.31), bottom=(0.30, 0.22, 0.24), hair=(0.30, 0.20, 0.13),
        skin=(0.88, 0.72, 0.61), shoe=(0.17, 0.13, 0.13),
        mode="plain", hat="none", scarf=False, skirt=True),
    "npc_antoine": dict(  # 居民：深绿大衣+flat cap
        top=(0.26, 0.35, 0.28), bottom=(0.18, 0.18, 0.20), hair=(0.36, 0.30, 0.22),
        skin=(0.82, 0.66, 0.55), shoe=(0.12, 0.12, 0.13),
        mode="coat", hat="flat", scarf=False, skirt=False),
}


def build_human(p, prefix):
    """参数化人物：6 部件（枢轴已归位），返回部件对象列表。
    材质名带件前缀：MATS 模块级共享，同名会命中首件的配色（批次8 教训）。"""
    skin, hair, top, bot, shoe = p["skin"], p["hair"], p["top"], p["bottom"], p["shoe"]
    mat(prefix + "_skin", skin, rough=0.8)
    mat(prefix + "_hair", hair, rough=0.9)
    mat(prefix + "_top", top, rough=0.85)
    mat(prefix + "_bottom", bot, rough=0.85)
    mat(prefix + "_shoe", shoe, rough=0.6)
    mat("npc_eye", (0.10, 0.09, 0.09), rough=0.4)
    mat(prefix + "_apron", (0.95, 0.95, 0.93), rough=0.9)
    mat(prefix + "_hat", (0.28, 0.26, 0.25), rough=0.9)
    mat(prefix + "_scarf", (0.58, 0.22, 0.20), rough=0.95)
    SKIN, HAIR, TOP, BOT, SHOE = (prefix + "_skin"), (prefix + "_hair"), (prefix + "_top"), (prefix + "_bottom"), (prefix + "_shoe")

    # ---- Head（颈枢轴 y=1.44）球面头 + 低段位五官 ----
    head = [
        gsphere("hd", 0.118, (0, 1.575, 0), SKIN, seg=12, rings=7,
                scale=(0.92, 1.0, 0.86)),            # 椭球头 0.217×0.236×0.203
        gsphere("hair", 0.126, (0, 1.628, 0.020), HAIR, seg=12, rings=4,
                scale=(0.95, 0.62, 0.92)),          # 发盖（覆顶+后脑）
        gsphere("eye_l", 0.016, (-0.045, 1.588, -0.101), "npc_eye", seg=6, rings=3),
        gsphere("eye_r", 0.016, (0.045, 1.588, -0.101), "npc_eye", seg=6, rings=3),
        gsphere("nose", 0.020, (0, 1.548, -0.108), SKIN, seg=6, rings=3,
                scale=(0.8, 1.0, 0.9)),
    ]
    if p.get("skirt"):  # 发髻
        head.append(gsphere("bun", 0.050, (0, 1.690, 0.082), HAIR, seg=8, rings=4))
    if p["hat"] == "fedora":
        head += [
            gcone("hat_top", 0.100, 0.086, 0.092, (0, 1.735, 0.0), "%s_hat" % prefix,
                  seg=12),                                          # 帽体收分
            gcyl("hat_brim", 0.160, 0.020, (0, 1.692, 0.0), "%s_hat" % prefix, seg=12),
        ]
    elif p["hat"] == "flat":
        head += [
            gcyl("cap", 0.115, 0.058, (0, 1.700, 0.005), "%s_hat" % prefix, seg=10,
                 scale_xz=(1.0, 1.06)),
            gbox("visor", (0.175, 0.018, 0.115), (0, 1.688, -0.155), "%s_hat" % prefix),
        ]
    elif p["hat"] == "beret":
        head.append(gsphere("beret", 0.118, (0, 1.698, 0.012), "%s_hat" % prefix,
                            seg=10, rings=4, scale=(1.0, 0.45, 1.0)))
    h_obj = _join_part("Head", head, (0, 1.44, 0))

    # ---- Torso（颈枢轴 y=1.44；呼吸/点头整体动作挂上层 Model）----
    torso = [
        gcone("chest", 0.178, 0.202, 0.52, (0, 1.20, 0), TOP, seg=12),  # 肩宽腰细 0.94..1.46
        gcyl("hips", 0.190, 0.10, (0, 0.94, 0), BOT, seg=12, scale_xz=(0.99, 0.94)),
    ]
    if p["mode"] == "apron":
        torso += [
            gbox("apron", (0.30, 0.44, 0.045), (0, 1.14, -0.128), "%s_apron" % prefix),
            gbox("apron_skirt", (0.33, 0.16, 0.05), (0, 0.90, -0.126), "%s_apron" % prefix),
        ]
    elif p["mode"] == "coat":
        torso.append(
            gcone("coat_skirt", 0.213, 0.198, 0.17, (0, 0.90, 0.0), TOP, seg=12))
    if p["scarf"]:
        torso.append(
            gcyl("scarf", 0.115, 0.075, (0, 1.465, 0.0), "%s_scarf" % prefix, seg=10,
                 scale_xz=(1.0, 1.05)))
    if p["skirt"]:
        torso.append(
            gcone("skirt", 0.235, 0.185, 0.36, (0, 0.78, 0), BOT, seg=12))  # A 字裙 0.60..0.96
    t_obj = _join_part("Torso", torso, (0, 1.44, 0))

    # ---- ArmL/R（肩枢轴 y=1.43, x=±0.255）圆台臂收分 + 球手 ----
    arms = []
    for side, sx in (("L", -1), ("R", 1)):
        parts = [
            gcone("arm", 0.048, 0.060, 0.55, (sx * 0.255, 1.145, 0), TOP, seg=8),
            gsphere("hand", 0.052, (sx * 0.255, 0.838, 0), SKIN, seg=8, rings=4,
                    scale=(0.88, 1.0, 0.98)),
        ]
        arms.append(_join_part("Arm" + side, parts, (sx * 0.255, 1.43, 0)))

    # ---- LegL/R（髋枢轴 y=0.92, x=±0.09）圆台腿收分 + 低面鞋 ----
    legs = []
    for side, sx in (("L", -1), ("R", 1)):
        parts = [
            gcone("leg", 0.055, 0.075, 0.78, (sx * 0.09, 0.53, 0), BOT, seg=8),  # 0.14..0.92
            gbox("shoe", (0.15, 0.10, 0.27), (sx * 0.09, 0.05, -0.04), SHOE),
        ]
        legs.append(_join_part("Leg" + side, parts, (sx * 0.09, 0.92, 0)))

    return [h_obj, t_obj] + arms + legs


def export_parted(filename, objs):
    """导出多部件（不 join：每部件一个 glTF 节点，Node 名 = 部件名）。"""
    if not objs:
        raise RuntimeError("无部件可导出: " + filename)
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]

    out = os.path.join(OUT_DIR, filename)
    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
    )
    total = sum(_tris(o) for o in objs)
    mats = sorted({s.material.name for o in objs for s in o.material_slots
                   if s.material is not None})
    size = os.path.getsize(out)
    warn = "  !! 超软帽 %d" % SOFT_CAP if total > SOFT_CAP else ""
    print("NPC_BUILD %s tris=%d bytes=%d parts=%d mats=%s%s"
          % (filename, total, size, len(objs), ",".join(mats), warn))
    REPORT.append({
        "file": filename, "triangles": total, "bytes": size,
        "materials": mats, "parts": [o.name for o in objs],
        "soft_cap": SOFT_CAP, "over_cap": bool(total > SOFT_CAP),
    })
    _clean()


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    _clean()
    for fname, params in VARIANTS.items():
        objs = build_human(params, fname)
        export_parted(fname + ".glb", objs)
    with open(os.path.join(OUT_DIR, "report.json"), "w", encoding="utf-8") as f:
        json.dump(REPORT, f, ensure_ascii=False, indent=2)
    over = [r["file"] for r in REPORT if r["over_cap"]]
    print("NPC_DONE %d 件, 超帽: %s" % (len(REPORT), over or "无"))


if __name__ == "__main__":
    main()
