#!/usr/bin/env python3
"""
build_cafe.py — Blender headless 脚本
在 Blender 中程序化搭建"咖啡馆 des Psaumes"可走入模型并导出 .glb

坐标约定(Blender, Z-up):
  +X = 沿街宽方向(最终 Godot 的 Z / 街道方向)
  +Y = 街区进深方向(朝向咖啡馆内部)
  +Z = 高度
  门面在 Y=-5(靠街一侧), 门洞开在 Y=-4.5 处, 玩家从 -Y 走入 +Y

尺寸:
  整体壳: 宽 10m(X) × 进深 8m(Y) × 两层高 7.2m(Z)
  内部: 一层打通为咖啡馆(净高 3.4m), 二层阁楼造型(装饰, 玩家不可达)
  门洞: 宽 2.2m × 高 2.8m 在门面中央(可走入)
  内容: 门面招牌/大玻璃橱窗/雨棚 + 内部吧台/咖啡机/3张桌/椅 + 暖色顶灯
"""

import bpy
import math
import mathutils

# ---------- 工具 ----------
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
        m.use_nodes = True
        bsdf.inputs["Emission Color"].default_value = (*emit_color, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emit
    MATS[name] = m
    return m


def box(name, x, y, z, cx=0.0, cy=0.0, cz=0.0, mat_name=None, rx=0.0, ry=0.0, rz=0.0):
    """以 cx,cy,cz 为中心建长方体"""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(cx, cy, cz))
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (x, y, z)
    if rx: obj.rotation_euler[0] = math.radians(rx)
    if ry: obj.rotation_euler[1] = math.radians(ry)
    if rz: obj.rotation_euler[2] = math.radians(rz)
    if mat_name:
        if mat_name in MATS:
            obj.data.materials.append(MATS[mat_name])
        else:
            obj.data.materials.append(mat(mat_name))
    return obj


def cylinder(name, radius, height, cx=0.0, cy=0.0, cz=0.0, mat_name=None, seg=20):
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=height,
                                        vertices=seg, location=(cx, cy, cz))
    obj = bpy.context.active_object
    obj.name = name
    if mat_name:
        if mat_name in MATS:
            obj.data.materials.append(MATS[mat_name])
        else:
            obj.data.materials.append(mat(mat_name))
    return obj


def join_into(name, objs):
    """合并为单一 mesh(减少 draw call)"""
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    if not objs:
        return None
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    objs[0].name = name
    return objs[0]


# ================= 开始搭建 =================
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.object.select_all(action='DESELECT')

# ---------- 色板 (Haussmann + 咖啡馆暖调) ----------
CREAM   = mat("wall_cream",    (0.965, 0.940, 0.900), rough=0.85)   # 外墙
DARKG   = mat("shop_green",    (0.12, 0.24, 0.14),   rough=0.5)    # 门面深绿
WOOD    = mat("wood",          (0.42, 0.26, 0.13),   rough=0.45)   # 吧台木
GLASS   = mat("glass",         (0.45, 0.62, 0.60),   rough=0.05, metal=0.1)  # 玻璃
ROOFZ   = mat("roof_zinc",     (0.30, 0.30, 0.33),   rough=0.7)    # 屋顶锌灰
SIGNB   = mat("sign_black",    (0.08, 0.08, 0.10),   rough=0.4)    # 招牌底
SIGNG   = mat("sign_gold",     (0.85, 0.72, 0.35),   rough=0.3, metal=0.8)  # 金字
AWNING  = mat("awning",        (0.55, 0.18, 0.16),   rough=0.9)    # 红雨棚
CHAIR   = mat("chair",         (0.20, 0.18, 0.16),   rough=0.6)
LAMP    = mat("lamp",          (0.95, 0.92, 0.85),   rough=0.4, emit=1.8, emit_color=(1.0, 0.86, 0.62))
FLOORI  = mat("floor_inner",   (0.55, 0.42, 0.30),   rough=0.6)
COFFEE  = mat("coffee_machine",(0.15, 0.15, 0.17),   rough=0.3, metal=0.8)
TILE    = mat("floor_tile",    (0.78, 0.75, 0.70),   rough=0.7)
PASTRY  = mat("pastry",        (0.72, 0.55, 0.35),   rough=0.8)
RED     = mat("red_chair",     (0.62, 0.15, 0.12),   rough=0.6)
DARKC   = mat("counter_top",   (0.15, 0.13, 0.11),   rough=0.35, metal=0.3)

# ---------- 几何尺寸 ----------
W = 4.6     # 外壳 X 宽(窄门面, 匹配 OSM 咖啡馆 3.63m 沿街 + 两侧少许)
D = 8.0     # 外壳 Y 深
H = 7.2     # 两层高(含屋顶到 ~7.2)
WALL = 0.35 # 墙厚

# 建筑主体墙壳: 前后左右四面 + 顶
# 外墙薄片
box("WallBack",  W, WALL, H,  cy=D/2-WALL/2, cz=H/2, mat_name="wall_cream")        # 后(Y=+D/2)
box("WallFront", W, WALL, H,  cy=-D/2+WALL/2, cz=H/2, mat_name="wall_cream")      # 前(带门洞将挖)
box("WallLeft",  WALL, D, H,  cx=-W/2+WALL/2, cz=H/2, mat_name="wall_cream")
box("WallRight", WALL, D, H,  cx=W/2-WALL/2, cz=H/2, mat_name="wall_cream")
# 楼板(一层地板在 y=0)
box("Floor",     W, D, 0.2,  cy=0, cz=-0.1, mat_name="floor_inner")
# 屋顶
box("Roof1",     W+0.4, D+0.4, 0.3, cy=0, cz=H, mat_name="roof_zinc")
# 二层层板(隔开阁楼)
box("MidFloor",  W-2*WALL, D-2*WALL, 0.2, cy=0, cz=3.6, mat_name="roof_zinc")

# ---------- 门面处理: 门洞 (前墙 -Y 侧, 门面更靠街, 前脸做成沿街立面) ----------
# 简化: 前墙实际在 Y=-D/2, 门洞区域不建墙 → 改由三段墙拼(避开中间门洞 2.4m)
DOOR_W = 1.6
left_w = (W - DOOR_W) / 2
box("FrontLeft",  left_w, WALL, H,  cx=-(DOOR_W/2 + left_w/2), cy=-D/2+WALL/2, cz=H/2, mat_name="wall_cream")
box("FrontRight", left_w, WALL, H,  cx=(DOOR_W/2 + left_w/2),  cy=-D/2+WALL/2, cz=H/2, mat_name="wall_cream")
# 门头横梁(门洞上方到顶)
box("FrontLintel", DOOR_W, WALL, H-2.9, cx=0, cy=-D/2+WALL/2, cz=2.9+(H-2.9)/2, mat_name="wall_cream")

# ---------- 门面装饰 ----------
# 前墙外侧法线面位于 Y = -(D/2) = -4.0 (墙中心 -3.825, 厚 0.35)
FACADE_Y = -D/2           # -4.0: 前墙外表面
# 深绿门脸下半段(0~1.0m 门基座, 避开中间门洞 2.6m)
for side_x in [-1, 1]:
    seg_w = left_w
    seg_cx = side_x * (DOOR_W/2 + seg_w/2)
    box("ShopBase%d" % (1 if side_x>0 else 2), seg_w, 0.1, 1.0,
        cx=seg_cx, cy=FACADE_Y-0.05, cz=0.5, mat_name="shop_green")
# 门框绿柱(门洞两侧)
box("DoorJambL", 0.28, 0.3, 2.9, cx=-(DOOR_W/2+0.14), cy=FACADE_Y+0.05, cz=1.45, mat_name="shop_green")
box("DoorJambR", 0.28, 0.3, 2.9, cx=(DOOR_W/2+0.14),  cy=FACADE_Y+0.05, cz=1.45, mat_name="shop_green")
# 大玻璃橱窗(门两侧各一块窄窗, 高 1.0~3.0)
for side_x in [-1, 1]:
    win_w = max(0.4, left_w - 0.5)
    win_cx = side_x * (DOOR_W/2 + 0.25 + win_w/2)
    box("ShowWindow%d" % (1 if side_x>0 else 2), win_w, 0.06, 2.0,
        cx=win_cx, cy=FACADE_Y-0.12, cz=2.0, mat_name="glass")
    box("WinUpper%d" % (1 if side_x>0 else 2), win_w, 0.06, 0.7,
        cx=win_cx, cy=FACADE_Y-0.12, cz=3.35, mat_name="shop_green")
# 玻璃门(向内侧推开, 斜 25°, 让出门洞中缝)
box("GlassDoorL", 0.65, 0.05, 2.9, cx=-0.5, cy=-2.2, cz=1.45, mat_name="glass", rz=25)
box("GlassDoorR", 0.65, 0.05, 2.9, cx=0.5,  cy=-2.2, cz=1.45, mat_name="glass", rz=-25)
# 招牌横条(门面上方 3.6~4.2 奶白墙带)
box("SignBoard", 3.4, 0.2, 0.9, cy=FACADE_Y-0.1, cz=4.05, mat_name="sign_black")
# 金字 "CAFÉ DES PSAUMES"(14 字母, 收进 3.6m)
letters = "CAFE DES PSAUMES"
txt_x0 = -1.55
for i, ch in enumerate(letters):
    if ch == ' ':
        continue
    box("Letter_%02d" % i, 0.30, 0.05, 0.40,
        cx=txt_x0 + i*0.225, cy=FACADE_Y-0.16, cz=4.05, mat_name="sign_gold")
# 红白雨棚(门面上缘 3.0~3.55, 遮橱窗顶)
box("Awning1", W+0.3, 1.0, 0.12, cy=FACADE_Y-0.75, cz=3.3, mat_name="awning", rx=15)
# 门灯(门框两侧上方)
box("WallLampL", 0.2, 0.15, 0.6, cx=-(DOOR_W/2+0.35), cy=FACADE_Y-0.15, cz=3.55, mat_name="lamp")
box("WallLampR", 0.2, 0.15, 0.6, cx=(DOOR_W/2+0.35),  cy=FACADE_Y-0.15, cz=3.55, mat_name="lamp")

# ---------- 室内: 吧台(靠后墙 Y=D/2) ----------
BAR_CX = 0.0   # 吧台横向居中
BAR_Y = D/2 - 1.5
box("BarTop",   3.2, 0.9, 0.08, cx=BAR_CX, cy=BAR_Y, cz=1.1, mat_name="counter_top")
box("BarFront", 3.2, 0.1, 1.1,  cx=BAR_CX, cy=BAR_Y-0.45, cz=0.55, mat_name="wood")
box("BarSide",  0.1, 1.0, 1.1,  cx=BAR_CX+1.6, cy=BAR_Y-0.5, cz=0.55, mat_name="wood")
box("BarSide2", 0.1, 1.0, 1.1,  cx=BAR_CX-1.6, cy=BAR_Y-0.5, cz=0.55, mat_name="wood")
# 咖啡机(吧台上)
box("Espresso", 0.55, 0.5, 0.55, cx=BAR_CX-0.9, cy=BAR_Y-0.15, cz=1.45, mat_name="coffee_machine")
box("Espresso2",0.5, 0.4, 0.45, cx=BAR_CX+0.1, cy=BAR_Y-0.15, cz=1.42, mat_name="coffee_machine")
cylinder("Steam", 0.02, 0.2, BAR_CX-0.35, BAR_Y-0.1, 1.75, mat_name="coffee_machine")
# 收银台小摆件
box("CashBox", 0.3, 0.15, 0.1, cx=BAR_CX+1.1, cy=BAR_Y-0.2, cz=1.3, mat_name="coffee_machine")
# 甜品柜(吧台边)
box("PastryCase", 0.9, 0.5, 0.9, cx=BAR_CX-1.7, cy=BAR_Y-0.1, cz=0.45, mat_name="wood")
box("PastryGlass", 0.8, 0.45, 0.06, cx=BAR_CX-1.7, cy=BAR_Y-0.4, cz=0.93, mat_name="glass")
for px, py in [(-1.95, -0.1), (-1.5, -0.1), (-1.72, 0.15)]:
    box("Croissant", 0.16, 0.12, 0.05, cx=px, cy=py+0.05, cz=0.9, mat_name="pastry", rz=20)
# 壁架酒柜(侧墙 +X)
box("ShelfUnit", 0.5, 0.3, 2.0, cx=W/2-0.5, cy=2.5, cz=1.0, mat_name="wood")
for lvl in range(4):
    box("Shelf%d" % lvl, 0.4, 0.26, 0.03, cx=W/2-0.5, cy=2.5, cz=0.25+lvl*0.5, mat_name="wood")
# 挂画
box("FramePic", 0.5, 0.05, 0.6, cx=-W/2+0.45, cy=2.0, cz=1.8, mat_name="sign_black")

# ---------- 桌椅(店内窄摆) ----------
def chair_at(cx, cy, rot_z=0):
    box("ChairSeat", 0.4, 0.4, 0.06, cx=cx, cy=cy, cz=0.46, mat_name="red_chair")
    for dx in [-0.17, 0.17]:
        box("ChairBack", 0.04, 0.4, 0.5, cx=cx+dx, cy=cy, cz=0.72, mat_name="red_chair", rz=rot_z)
    for dx, dy in [(-0.17, -0.17), (0.17, -0.17), (-0.17, 0.17), (0.17, 0.17)]:
        box("ChairLeg", 0.04, 0.04, 0.45, cx=cx+dx, cy=cy+dy, cz=0.22, mat_name="chair")

def table_at(cx, cy, n=2):
    box("TableTop", 0.7, 0.7, 0.06, cx=cx, cy=cy, cz=0.72, mat_name="counter_top")
    for dx, dy in [(-0.3, -0.3), (0.3, -0.3), (-0.3, 0.3), (0.3, 0.3)]:
        box("TableLeg", 0.05, 0.05, 0.7, cx=cx+dx, cy=cy+dy, cz=0.35, mat_name="chair")
    import math as _m
    for i in range(n):
        a = (i / n) * 6.283
        chair_at(cx + 0.8 * _m.cos(a), cy + 0.8 * _m.sin(a))

table_at(-0.5, 2.0, 2)
table_at(-0.5, 0.3, 2)
table_at(1.2, 1.2, 1)

# ---------- 顶灯(暖光) ----------
for lx, lz in [(-0.5, 1.2), (0.0, 0.2), (1.0, 2.0)]:
    box("CeilingLamp", 0.5, 0.12, 0.06, cx=lx, cy=lz, cz=3.32, mat_name="lamp")
    cylinder("LampShade", 0.18, 0.15, lx, lz, 3.1, mat_name="lamp", seg=12)

# ---------- 门口地垫 ----------
box("Doormat", 1.0, 0.6, 0.02, cy=-D/2+0.8, cz=0.01, mat_name="red_chair")

# ---------- 门面露台(2 桌 靠墙, 窄) ----------
table_at(-1.1, -1.1, 2)
table_at(1.2, -1.2, 2)

# ---------- 屋顶造型: 巴黎窗 + 烟囱 ----------
for rx2 in [-3.2, -0.6, 2.0]:
    box("RoofWindow", 1.0, 0.6, 0.8, cx=rx2, cy=D/2-0.6, cz=H-0.4, mat_name="roof_zinc")
    box("RoofWinGlass", 0.9, 0.5, 0.05, cx=rx2, cy=D/2-0.85, cz=H-0.1, mat_name="glass")
box("Chimney", 0.5, 0.7, 0.9, cx=3.2, cy=2.2, cz=H+0.45, mat_name="roof_zinc")
box("ChimneyCap", 0.6, 0.8, 0.1, cx=3.2, cy=2.2, cz=H+0.9, mat_name="roof_zinc")

# ---------- 平移: 门面放到世界原点 ----------
# 前墙外表面原在 Y=-4.0 → 平移 +4.0, 使门面(街边)在 Y=0, 内部向 +Y
for obj in bpy.data.objects:
    if obj.type == 'MESH':
        obj.location.y += D / 2

# 打印包围盒(用于 S4 定位校验)
for obj in bpy.data.objects:
    obj.select_set(True)
bpy.ops.object.select_all(action='SELECT')
import numpy as np
bb_min = [1e9, 1e9, 1e9]
bb_max = [-1e9, -1e9, -1e9]
for obj in bpy.data.objects:
    if obj.type != 'MESH':
        continue
    for corner in obj.bound_box:
        w = obj.matrix_world @ mathutils.Vector(corner)
        for i in range(3):
            bb_min[i] = min(bb_min[i], w[i])
            bb_max[i] = max(bb_max[i], w[i])
print("CAFE_AABB X: %.2f..%.2f" % (bb_min[0], bb_max[0]))
print("CAFE_AABB Y: %.2f..%.2f" % (bb_min[1], bb_max[1]))
print("CAFE_AABB Z: %.2f..%.2f" % (bb_min[2], bb_max[2]))
print("CAFE_FRONT_AT_Y=0, DOOR_X_SPAN: ±1.3")
bpy.ops.object.select_all(action='DESELECT')


# 最宽物体报告
widest = sorted(
    ((obj.matrix_world @ mathutils.Vector(c)).x for obj in bpy.data.objects if obj.type=='MESH' for c in obj.bound_box),
    key=lambda x: abs(x))
print("CAFE_MAX_ABS_X:", round(max(abs(x) for x in widest), 2))

# 逐个最宽物体
import mathutils as _mu
report = []
for obj in bpy.data.objects:
    if obj.type != 'MESH':
        continue
    bb = [obj.matrix_world @ _mu.Vector(c) for c in obj.bound_box]
    xmax = max(abs(v.x) for v in bb)
    if xmax > 2.4:
        report.append((round(xmax, 2), obj.name))
report.sort(reverse=True)
for xm, nm in report[:12]:
    print("CAFE_WIDE %.2f %s" % (xm, nm))
import os
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "godot-project", "assets", "models")
os.makedirs(OUT_DIR, exist_ok=True)
OUT_PATH = os.path.abspath(os.path.join(OUT_DIR, "cafe.glb"))

bpy.ops.export_scene.gltf(
    filepath=OUT_PATH,
    export_format='GLB',
    use_selection=False,
    export_yup=True,
)
print("CAFE_GLB_EXPORTED:", OUT_PATH)
