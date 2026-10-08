#!/usr/bin/env python3
"""P3 批次2 — 连接走廊布局生成 + 三街接缝 placement 计算.

只写 artifacts/p3b2/ (候选纪律, 无自动发布); 集成 = 人工 cp + manifest 更新.
方案 (决策 30): 街道装配为"直线展开"模型, 接缝在**游戏空间**直链:
    rosiers(恒等) → corridor(锚=罗斯街路面端) → vosges(锚=走廊链终点=环西北角)
轴角差定朝向: rotation.y = (my_axis − ref_axis) (度→弧度); placement.ref_axis 自带参考轴.
断言口径: 接缝世界距 < 0.5m (构造性), ENU 只作 origin 数据不再做位移源.

用法: python3 tools/p3_build_joints.py   (仓库根目录)
"""
import json
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import osm_to_layout as O  # noqa: E402  (复用中线/投影函数, 保证与工具同法)

OUT_DIR = ROOT / "artifacts" / "p3b2"

PULL_VOSGES = ROOT / "data/osm/place_des_vosges_full.json"
PULL_ROSIERS = ROOT / "data/osm/rosiers_full.json"
LAYOUT_ROSIERS = ROOT / "godot-project/data/layouts/rosiers_layout.json"
LAYOUT_VOSGES = ROOT / "godot-project/data/layouts/vosges_layout.json"

# Dijkstra 最短步行路由 (382m) 的 way id 链 — 首个为贪链种子 (西北端起顺扫)
CHAIN_IDS = [
    220442415, 23071694, 995241575, 576429487, 576429486, 576429484,
    576429483, 576429481, 23071686, 1190197279, 1356985638, 1356985637,
    1190197265, 1190197267, 390298282, 948652818, 45828501,
]
FB_RING_TOUCH = (48.856307, 2.3649664)   # Rue des Francs Bourgeois 45828501 端点 == 环 way 节点

JOINT_DP = 7                               # --chain-from 字符串精度 (工具与复现共用)


def die(msg: str) -> None:
    print(f"[p3_build_joints] FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def load_elems(*paths: Path) -> list:
    elems, seen = [], set()
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for e in json.load(f).get("elements", []):
                key = (e["type"], e["id"])
                if key in seen:
                    continue
                seen.add(key)
                elems.append(e)
    return elems


def highway_ways(elems: list) -> list:
    return [e for e in elems if e["type"] == "way" and "highway" in e.get("tags", {})]


def bbox_origin(elems: list):
    """与工具同式: 元素几何 + 节点坐标包围盒中心."""
    lats = [g["lat"] for e in elems for g in e.get("geometry", [])]
    lons = [g["lon"] for e in elems for g in e.get("geometry", [])]
    lats += [e["lat"] for e in elems if e.get("type") == "node" and "lat" in e]
    lons += [e["lon"] for e in elems if e.get("type") == "node" and "lon" in e]
    return ((min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2)


def local_poly(ways: list, origin) -> list:
    poly_geo, _ = O.build_street_polyline(ways)
    if not poly_geo:
        die("中线贪链为空")
    lat0, lon0 = origin
    return [O.to_local(lat, lon, lat0, lon0) for (lat, lon) in poly_geo]


def project(poly_local: list, pt_local):
    segs = O.polyline_segments(poly_local)
    return O.project_to_segments(pt_local, segs)[:2]


def point_at_arc(poly_local: list, s: float):
    acc = 0.0
    for i in range(len(poly_local) - 1):
        ax, ay = poly_local[i]
        bx, by = poly_local[i + 1]
        L = math.hypot(bx - ax, by - ay)
        if acc + L >= s and L > 0:
            t = (s - acc) / L
            return (ax + (bx - ax) * t, ay + (by - ay) * t)
        acc += L
    return poly_local[-1]


def inv_to_local(x: float, z: float, origin):
    """to_local 逆变换."""
    lat0, lon0 = origin
    lat = lat0 - z / 110574.0
    lon = lon0 + x / (math.cos(math.radians(lat0)) * 111320.0)
    return lat, lon


def ry(deg: float, x: float, z: float):
    """Godot rotation.y=rad(deg) 作用于 (x, z) 平面向量."""
    g = math.radians(deg)
    return (x * math.cos(g) + z * math.sin(g), -x * math.sin(g) + z * math.cos(g))


def orient_cut(poly_local: list, cf_local, do_cut: bool):
    """复现工具 --chain-from/--chain-cut: 过半反向 + 丢前缀."""
    segs = O.polyline_segments(poly_local)
    s_cf = O.project_to_segments(cf_local, segs)[0]
    w_cf = sum(sg["L"] for sg in segs)
    if s_cf > w_cf / 2.0:
        poly_local = poly_local[::-1]
        s_cf = w_cf - s_cf
    if do_cut:
        poly_local = O._cut_poly(poly_local, s_cf)
    return poly_local, s_cf, w_cf


def seg_len_total(poly_local: list) -> float:
    """与工具 wsum 同口径 (polyline_segments 跳过 <0.5m 段)."""
    return sum(sg["L"] for sg in O.polyline_segments(poly_local))


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # ── 1) 罗斯街: joint 地理点 (arc = café_arc + 路面端 z) ──
    rosiers = json.load(open(LAYOUT_ROSIERS, encoding="utf-8"))
    s0_min = min(b["s0"] for b in rosiers["buildings"])
    road_min = s0_min - 14.0                       # = -89.01 (assembler min_s 同式)
    if abs(road_min + 89.01) > 0.05:
        die(f"rosiers 路面端异常: {road_min}")
    axis_r = float(rosiers["meta"]["street_axis_deg"])
    axis_corr = (axis_r - 180.0) % 360.0      # 接缝共轴: 走廊 = 罗斯街轴反向延伸

    elems_r = [e for e in load_elems(PULL_ROSIERS)]
    cafe = next((e for e in elems_r if e["type"] == "node"
                 and e.get("tags", {}).get("amenity") == "cafe"
                 and "Psaumes" in e.get("tags", {}).get("name", "")), None)
    if cafe is None:
        die("café des Psaumes 节点缺失")
    origin_r = (cafe["lat"], cafe["lon"])
    poly_r = local_poly(highway_ways(elems_r), origin_r)
    s_cafe = project(poly_r, (0.0, 0.0))[0]        # origin=café → café 本地 (0,0)
    s_joint = s_cafe + road_min
    jx, jz = point_at_arc(poly_r, s_joint)
    joint_lat, joint_lon = inv_to_local(jx, jz, origin_r)
    joint_str = f"{joint_lat:.{JOINT_DP}f},{joint_lon:.{JOINT_DP}f}"
    print(f"joint: café_arc={s_cafe:.2f} road_min={road_min:.2f} → "
          f"arc={s_joint:.2f} → {joint_str}")

    # ── 2) 走廊候选生成 (工具, 复用全部新参数) ──
    corridor_art = OUT_DIR / "corridor_layout.json"
    cmd = [
        sys.executable, str(ROOT / "tools/osm_to_layout.py"),
        "--input", str(PULL_VOSGES), "--input", str(PULL_ROSIERS),
        "--output", str(corridor_art),
        "--street-name", "Rue des Francs Bourgeois",
        "--chain-ways", ",".join(map(str, CHAIN_IDS)),
        "--chain-from", joint_str, "--chain-cut", "--no-cafe",
        "--ends", "open,open",
        "--axis-deg", f"{axis_corr:.1f}",
        "--surface-drop", "0.004",
        "--placement", "by_v", "--across-max", "45",
        "--span-down", "0", "--span-up", "500",
        # 弯折链折返处投影翻车防护 (超长假楼 / 远段钳制建筑): 只作用本候选
        "--span-max", "60", "--max-proj-dist", "45",
    ]
    print("→", " ".join(cmd[2:]))
    r = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
    print(r.stdout, end="")
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        die("走廊生成失败")

    corridor = json.load(open(corridor_art, encoding="utf-8"))
    n_corr = len(corridor["buildings"])
    if n_corr < 10:
        die(f"走廊建筑过少: {n_corr}")

    # ── 3) 复现走廊链 → 校验 total_len + z_fb (FB×环触点弧) ──
    elems_c = load_elems(PULL_VOSGES, PULL_ROSIERS)
    by_id = {w["id"]: w for w in highway_ways(elems_c)}
    missing = [i for i in CHAIN_IDS if i not in by_id]
    if missing:
        die(f"chain id 缺失: {missing}")
    ways_c = [by_id[i] for i in CHAIN_IDS]
    origin_c = tuple(float(v) for v in joint_str.split(","))
    poly_c = local_poly(ways_c, origin_c)
    poly_c, s_cf, _ = orient_cut(poly_c, (0.0, 0.0), do_cut=True)
    total_c = seg_len_total(poly_c)
    stored_total = float(corridor["street"]["total_len"])
    if abs(total_c - stored_total) > 0.15:
        die(f"走廊链复现不一致: 复现 {total_c:.2f} vs 存储 {stored_total}")
    fb_local = (FB_RING_TOUCH[0], FB_RING_TOUCH[1])
    z_fb = project(poly_c, O.to_local(fb_local[0], fb_local[1], *origin_c))[0]
    end_latlon = inv_to_local(poly_c[-1][0], poly_c[-1][1], origin_c)
    d_end = O.dist_m(end_latlon[0], end_latlon[1], *FB_RING_TOUCH)
    if d_end > 1.0:
        die(f"走廊链终点 ≠ FB×环触点 (Δ={d_end:.2f}m)")
    print(f"走廊: {n_corr}栋 chain={s_cf:.1f}→{stored_total}m z_fb={z_fb:.2f} "
          f"axis={corridor['meta']['street_axis_deg']} ends={corridor['street'].get('ends')}")

    # ── 4) 复现 vosges 环链 (还原参数) → FB 触点本地坐标 ──
    elems_v = load_elems(PULL_VOSGES)
    ways_v = [w for w in elems_v if w["type"] == "way"
              and w.get("tags", {}).get("name") == "Place des Vosges"
              and w.get("tags", {}).get("highway") in ("residential", "tertiary")]
    origin_v = bbox_origin(elems_v)
    poly_v = local_poly(ways_v, origin_v)
    total_v = seg_len_total(poly_v)
    committed_v = json.load(open(LAYOUT_VOSGES, encoding="utf-8"))
    if abs(total_v - float(committed_v["street"]["total_len"])) > 0.15:
        die(f"vosges 链复现不一致: {total_v:.2f} vs {committed_v['street']['total_len']}")
    fb_s, fb_v = project(poly_v, O.to_local(fb_local[0], fb_local[1], *origin_v))
    print(f"vosges: 链 {total_v:.1f}m axis={committed_v['meta']['street_axis_deg']} "
          f"FB触点本地 v={fb_v:.2f} s={fb_s:.2f}")

    # ── 5) placement 计算 (方案 A: 游戏空间直链) ──
    axis_c = float(corridor["meta"]["street_axis_deg"])
    axis_v = float(committed_v["meta"]["street_axis_deg"])
    if abs(axis_c - axis_corr) > 0.05:
        die(f"走廊轴覆盖未生效: {axis_c} != {axis_corr}")
    g_c = axis_c - axis_r
    g_v = axis_v - axis_r
    # corridor: 锚(chain-from=joint) → 目标 (0, road_min) [rosiers 恒等帧]
    corr_pl = {"ref": "rosiers", "ref_axis": axis_r, "x": 0.0, "z": round(road_min, 2)}
    # vosges: 锚(=origin=bbox中心, 本地 fb) → 目标 = 走廊链终点世界位 (rosiers 帧)
    #   node.position = corridor_pos + Ry(g_c)·(0,0,z_fb) − Ry(g_v)·(fb_v,0,fb_s)
    x1, z1 = ry(g_c, 0.0, z_fb)
    x2, z2 = ry(g_v, fb_v, fb_s)
    vos_pl = {
        "ref": "rosiers", "ref_axis": axis_r,
        "x": round(corr_pl["x"] + x1 - x2, 2), "z": round(corr_pl["z"] + z1 - z2, 2),
        "anchor": [round(fb_v, 2), round(fb_s, 2)],
    }
    # 构造性校验: 接缝距 (直接按公式代回)
    cx, cz = corr_pl["x"] + x1, corr_pl["z"] + z1                    # 走廊链终点世界
    ax_, az_ = vos_pl["x"] + x2, vos_pl["z"] + z2                    # vosges 锚世界
    seam = math.hypot(cx - ax_, cz - az_)
    if seam > 0.01:
        die(f"vosges 接缝自检 {seam:.3f}m > 0.01")
    print(f"placement: corridor={corr_pl} axisΔ={g_c:+.1f}° | "
          f"vosges={vos_pl} axisΔ={g_v:+.1f}° | 接缝自检 {seam:.4f}m")

    # ── 6) 写入 artifacts: placement + vosges ends/road_limits ──
    corridor["meta"]["placement"] = corr_pl
    with open(corridor_art, "w", encoding="utf-8") as f:
        json.dump(corridor, f, ensure_ascii=False, indent=1)

    vos_out = dict(committed_v)
    vos_out["meta"] = dict(committed_v["meta"])
    vos_out["street"] = dict(committed_v["street"])
    vos_out["street"]["ends"] = ["open", "open"]
    vos_out["street"]["road_limits"] = [round(0.0 - 0.0, 2), round(total_v - 0.0, 2)]
    vos_out["meta"]["placement"] = vos_pl
    with open(OUT_DIR / "vosges_layout.json", "w", encoding="utf-8") as f:
        json.dump(vos_out, f, ensure_ascii=False, indent=1)

    print(f"OK → {corridor_art} ({n_corr} 栋) + {OUT_DIR / 'vosges_layout.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
