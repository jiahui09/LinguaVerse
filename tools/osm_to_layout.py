#!/usr/bin/env python3
"""
osm_to_layout.py — Overpass OSM → Godot 街道布局 JSON（v3，连续立面模型）

输入:  data/osm/rosiers_full.json
输出:  data/layouts/rosiers_layout.json

P2-B 参数化: --input/--output/--street-name/--cafe-name/--span-down/--span-up/--width
  候选产物一律先写 artifacts/candidates/<ts>/ (隔离候选纪律), 人工核验后再集成。
  不带参数运行 = 与历史字节级一致 (回归由 street_check 清单 sha256 断言兜底)。

核心模型（对 V1 街景最关键的正确抽象）:
  巴黎街景 = 街道中线 + 两侧"连续临街立面"（盒子简化）
  每栋建筑不再保留 OBB 旋转——而是投影到街道坐标系:
    side  : +1 = 街道左侧(东), -1 = 右侧(西)
    s0,s1 : 沿街跨度(米, 相对咖啡馆/锚点)
    depth : 进深(米, 从街边向街区内部)
    levels: 层数 → 高度
  Godot 生成器据此沿街道摆连续立面, 视觉天然对齐、无缝隙观感
"""

import argparse
import json
import math
import sys
from pathlib import Path

RAW_PATH = Path("data/osm/rosiers_full.json")
OUT_PATH = Path("godot-project/data/layouts/rosiers_layout.json")

DEFAULT_LEVELS = 6
LEVEL_HEIGHT = 3.2
STREET_WIDTH = 9.0                 # 步行街路面宽(米)
STREET_BACKOFF = STREET_WIDTH / 2 + 1.5   # 建筑临街面离街中线的距离
CAFE_NAME = "Cafe des Psaumes"
SPAN_DOWN = 70.0                   # 咖啡馆 -s(前)方向保留范围
SPAN_UP = 80.0                     # 咖啡馆 +s(后)方向保留范围
ACROSS_MAX = 22.0                  # 临街建筑离街垂直最大(第二排剔除)
MAX_DEPTH = 22.0                   # 盒子进深上限


def dist_m(a_lat, a_lon, b_lat, b_lon):
    return math.hypot((a_lat - b_lat) * 110574.0, (a_lon - b_lon) * 73000.0)


def to_local(lat, lon, lat0, lon0):
    x = (lon - lon0) * math.cos(math.radians(lat0)) * 111320.0
    z = (lat0 - lat) * 110574.0
    return x, z


def build_street_polyline(streets):
    """贪心连接街道段 → (经纬度点序列, 段列表)"""
    unused = [s for s in streets if len(s.get("geometry", [])) >= 2]
    if not unused:
        return [], []
    chain = [unused[0]]
    unused = unused[1:]
    while unused:
        tail = chain[-1]["geometry"][-1]
        best, bd, flip = None, 1e18, False
        for s in unused:
            h = s["geometry"]
            d1 = dist_m(tail["lat"], tail["lon"], h[0]["lat"], h[0]["lon"])
            d2 = dist_m(tail["lat"], tail["lon"], h[-1]["lat"], h[-1]["lon"])
            if d1 < bd: bd, best, flip = d1, s, False
            if d2 < bd: bd, best, flip = d2, s, True
        if bd > 25:
            break
        unused.remove(best)
        if flip:
            best["geometry"] = best["geometry"][::-1]
        chain.append(best)
    raw = []
    for s in chain:
        for g in s["geometry"]:
            raw.append((g["lat"], g["lon"]))
    pts = [raw[0]]
    for p in raw[1:]:
        if p != pts[-1]:
            pts.append(p)
    return pts, chain


def polyline_segments(poly):
    """折线 → 直线段列表, 每段带 (起, 止, 方向角, 长)"""
    segs = []
    for i in range(len(poly) - 1):
        a, b = poly[i], poly[i + 1]
        dx, dz = b[0] - a[0], b[1] - a[1]
        L = math.hypot(dx, dz)
        if L > 0.5:
            segs.append({"a": a, "b": b, "dx": dx, "dz": dz, "L": L,
                         "ang": math.degrees(math.atan2(dx, -dz)) % 360})  # 0=+Z
    return segs


def project_to_segments(p, segs):
    """点投影到折线 → (s沿街里程, v垂直距离); 单段内恒定方向"""
    best = None
    mile = 0.0
    for sg in segs:
        ax, az = sg["a"]
        abx, abz = sg["dx"], sg["dz"]
        L2 = sg["L"] * sg["L"]
        t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - ax) * abx + (p[1] - az) * abz) / L2))
        px, pz = ax + abx * t, az + abz * t
        d2 = (p[0] - px) ** 2 + (p[1] - pz) ** 2
        if best is None or d2 < best["d2"]:
            nx, nz = -abz, abx
            nl = math.hypot(nx, nz) or 1.0
            v = ((p[0] - ax) * nx + (p[1] - az) * nz) / nl
            best = {"s": mile + L2 ** 0.5 * t, "v": v, "d2": d2,
                    "seg_ang": sg["ang"]}
        mile += sg["L"]
    return best["s"], best["v"], best["seg_ang"]


def polygon_area(pts):
    n = len(pts)
    s = 0.0
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2.0


def make_slots(keep):
    """P3 批次1 槽位参数化: 按保留建筑 s 跨度均布灯具/长椅/种植网格。

    消费方 (godot-project/scripts/world/street/):
      street_furniture: slots.lamp_z (两侧生成, 交替装灯), slots.bench_seats [[x,z],..]
      planting.plan_with: slots.planting 覆盖 z 网格与预算
    默认 (Rosiers, 无 slots 字段) 走模块 PARAMS 绝对槽位 → 历史行为逐字节不变。
    """
    if not keep:
        return None
    s_min = min(b["s0"] for b in keep)
    s_max = max(b["s1"] for b in keep)
    span = s_max - s_min
    if span < 40.0:
        return None
    # 路灯: 14m 步长 (与现街设计密度一致), 边缘留 7m
    lamp_z = []
    z = s_min + 7.0
    while z <= s_max - 7.0:
        lamp_z.append(round(z, 1))
        z += 14.0
    # 长椅: ~110m 一处、交替侧 (|x|=5.75 与人行道宽核算一致)
    n_b = max(2, min(6, int(span / 110.0) + 2))
    benches = []
    for i in range(n_b):
        bz = s_min + span * (i + 0.5) / n_b
        benches.append([5.75 if i % 2 == 0 else -5.75, round(bz, 1)])
    # 种植: 42m 网格 (= 3×14) 双侧, z_from 偏移 ≡7 (mod 14) → 树与灯恒距 ≥7m
    # (步长与路灯 14 互质会导致网格渐进逼近出现 1m 贴脸, 已实测)
    p_step = 42.0
    p_count = max(1, int((span - 12.0) / p_step) + 1)
    planting = {
        "z_from": round(s_min + 14.0, 1),
        "z_step": p_step,
        "z_count": p_count,
        "budget_total": p_count * 2,
        "cafe_door_z": -9999.0,             # 无咖啡馆街区: 关闭幻影门口缓冲
    }
    return {"lamp_z": lamp_z, "bench_seats": benches, "planting": planting}


def main():
    ap = argparse.ArgumentParser(description="OSM Overpass JSON → 街道布局 JSON")
    ap.add_argument("--input", default=str(RAW_PATH), help="Overpass 结果 JSON")
    ap.add_argument("--output", default=str(OUT_PATH), help="布局 JSON 输出路径")
    ap.add_argument("--street-name", default="Rue des Rosiers", help="街道名 (meta/street)")
    ap.add_argument("--street-filter", default="",
                    help="参与中线拼接的街道名精确匹配 (空=输入里全部 highway, "
                         "与历史行为一致; 多街区 bbox 拉取时必填否则中线会乱链)")
    ap.add_argument("--highway-types", default="",
                    help="中线允许的 highway 类别, 逗号分隔 (空=全部)。"
                         "Place des Vosges 这类地名挂着外环车行道+园内步道混类, "
                         "不过滤会把花园十字路链进中线")
    ap.add_argument("--cafe-name", default=CAFE_NAME,
                    help="咖啡馆定位名; 拉取数据中无咖啡馆节点时自动无 cafe_anchor")
    ap.add_argument("--span-down", type=float, default=SPAN_DOWN, help="锚点 -s 保留范围(米)")
    ap.add_argument("--span-up", type=float, default=SPAN_UP, help="锚点 +s 保留范围(米)")
    ap.add_argument("--width", type=float, default=STREET_WIDTH, help="路面宽(米)")
    ap.add_argument("--across-max", type=float, default=ACROSS_MAX,
                    help="建筑离中线垂直距离上限(米); 广场环线中线离临街面更远, 需调大")
    ap.add_argument("--placement", choices=["backoff", "by_v"], default="backoff",
                    help="摆楼模型: backoff=V1 舞台布景(默认, 输出字节中性); "
                         "by_v=盒心按 OSM 真实投影 |v|, depth 用真实占地进深, "
                         "并写入 street.placement 字段 (装配器 get_facade_face 消费)")
    ap.add_argument("--emit-slots", action="store_true",
                    help="写入 street.slots 槽位参数 (灯具/长椅/种植网格); "
                         "placement=by_v 时自动开启, 默认字节中性不受影响")
    args = ap.parse_args()
    raw_path = Path(args.input)
    out_path = Path(args.output)
    street_width = args.width
    street_backoff = street_width / 2 + 1.5

    with open(raw_path, encoding="utf-8") as f:
        raw = json.load(f)
    elems = raw.get("elements", [])

    buildings = [e for e in elems if e["type"] == "way" and "building" in e.get("tags", {})]
    streets = [e for e in elems if e["type"] == "way" and "highway" in e.get("tags", {})]
    if args.street_filter:
        streets = [s for s in streets if s.get("tags", {}).get("name") == args.street_filter]
    if args.highway_types:
        allow = {t.strip() for t in args.highway_types.split(",") if t.strip()}
        streets = [s for s in streets if s.get("tags", {}).get("highway") in allow]
    cafes = [e for e in elems if e["type"] == "node" and e.get("tags", {}).get("amenity") == "cafe"]

    cafe_osm = next((c for c in cafes if args.cafe_name in c.get("tags", {}).get("name", "")),
                    (cafes[0] if cafes else None))
    if cafe_osm:
        origin = (cafe_osm["lat"], cafe_osm["lon"])
    else:
        # 无咖啡馆锚点 (如 Place des Vosges 拉取): 取几何包围盒中心, 元素不依赖 bounds 字段
        lats = [g["lat"] for e in elems for g in e.get("geometry", [])]
        lons = [g["lon"] for e in elems for g in e.get("geometry", [])]
        lats += [e["lat"] for e in elems if e.get("type") == "node" and "lat" in e]
        lons += [e["lon"] for e in elems if e.get("type") == "node" and "lon" in e]
        if not lats:
            print("输入无几何数据", file=sys.stderr)
            return 1
        origin = ((min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2)
    lat0, lon0 = origin

    poly_osm, _ = build_street_polyline(streets)
    poly = [to_local(lat, lon, lat0, lon0) for (lat, lon) in poly_osm]
    segs = polyline_segments(poly)
    if not segs:
        print("街道无有效线段", file=sys.stderr)
        return 1

    # 主街方向角（长度加权平均）
    wsum = sum(sg["L"] for sg in segs)
    main_ang = sum(sg["ang"] * sg["L"] for sg in segs) / wsum

    # 咖啡馆沿街位置 (无咖啡馆 → 锚点 = 原点 = s 0)
    cafe_s, cafe_v = 0.0, 0.0
    if cafe_osm:
        cl = to_local(cafe_osm["lat"], cafe_osm["lon"], lat0, lon0)
        cafe_s, cafe_v, _ = project_to_segments(cl, segs)
        print(f"咖啡馆: 沿街 {cafe_s:.1f}m, 离街 {cafe_v:.1f}m")
    anchor_s = cafe_s

    # 每栋建筑 → 沿街投影跨度 (s0..s1), 侧别
    keep = []
    for b in buildings:
        pts = [to_local(g["lat"], g["lon"], lat0, lon0) for g in b.get("geometry", [])]
        if len(pts) < 3 or polygon_area(pts) < 6.0:
            continue
        # 投影每个顶点
        proj = [project_to_segments(p, segs) for p in pts]
        s_vals = [pr[0] for pr in proj]
        v_vals = [pr[1] for pr in proj]
        s0, s1 = min(s_vals), max(s_vals)
        if s1 - s0 < 2.0:
            continue  # 退化投影 (链起点转角建筑全部顶点钳到 s=0, 零宽 sliver)
        v_mean = sum(v_vals) / len(v_vals)
        if abs(v_mean) > args.across_max:
            continue
        if not (anchor_s - args.span_down - 5 <= (s0 + s1) / 2 <= anchor_s + args.span_up + 5):
            continue

        tags = b.get("tags", {})
        lvl_s = tags.get("building:levels")
        try:
            levels = int(lvl_s) if lvl_s else DEFAULT_LEVELS
        except ValueError:
            levels = DEFAULT_LEVELS
        levels = max(2, min(levels, 12))

        along_w = s1 - s0                      # 沿街宽度
        depth = min(MAX_DEPTH, max(along_w, 8.0) * 0.9 + 3.0)  # 进深≈宽或封顶
        if args.placement == "by_v":
            # by_v: 盒心=OSM 真实投影 v → 进深用真实占地 (面积/沿街宽), 合成进深会戳穿路面
            real_d = polygon_area(pts) / max(along_w, 1.0)
            depth = min(MAX_DEPTH, max(6.0, real_d))
        keep.append({
            "id": b["id"],
            "name": tags.get("name", ""),
            "side": 1 if v_mean >= 0 else -1,
            "s0": round(s0 - cafe_s, 2),       # 相对咖啡馆
            "s1": round(s1 - cafe_s, 2),
            "v": round(v_mean, 2),
            "along_w": round(along_w, 2),
            "depth": round(min(depth, MAX_DEPTH), 2),
            "levels": levels,
            "height": round(levels * LEVEL_HEIGHT, 1),
            "heritage": "heritage" in tags,
        })

    # 咖啡馆: 在咖啡馆同侧(v 符号一致)的临街建筑中, 选沿街中点最贴近 s=0 的建筑
    cafe_bld = None
    if cafe_osm and keep:
        cafe_side = 1 if cafe_v >= 0 else -1
        same_side = [b for b in keep if b["side"] == cafe_side]
        if same_side:
            cafe_bld = min(same_side, key=lambda b: abs((b["s0"] + b["s1"]) / 2))
            cafe_bld["is_cafe"] = True
            cafe_anchor = {
                "building_id": cafe_bld["id"],
                "name": cafe_osm["tags"].get("name", CAFE_NAME),
                "side": cafe_bld["side"],
                "s": round((cafe_bld["s0"] + cafe_bld["s1"]) / 2, 2),
            }
        else:
            cafe_anchor = None
    else:
        cafe_anchor = None

    # 去完全重复: 同侧同区间(容差0.5m)只保留一个
    seen = set()
    dedup = []
    for b in keep:
        key = (b["side"], round(b["s0"], 1), round(b["s1"], 1))
        if key in seen:
            continue
        seen.add(key)
        dedup.append(b)
    keep = dedup

    layout = {
        "meta": {
            "street": args.street_name,
            "source": "OpenStreetMap (ODbL)",
            "origin_lat": round(lat0, 6), "origin_lon": round(lon0, 6),
            "unit": "meters",
            "street_axis_deg": round(main_ang, 1),  # 0=+Z
        },
        "street": {
            "name": args.street_name,
            "width": street_width,
            "backoff": street_backoff,
            "total_len": round(wsum, 1),
        },
        "cafe_anchor": cafe_anchor,
        "buildings": sorted(keep, key=lambda b: (b["side"], b["s0"])),
    }
    if args.placement == "by_v":
        layout["street"]["placement"] = "by_v"
    if args.placement == "by_v" or args.emit_slots:
        slots = make_slots(keep)
        if slots:
            layout["street"]["slots"] = slots
            print(f"槽位: 路灯 {len(slots['lamp_z'])} 点 / 长椅 {len(slots['bench_seats'])} 处 / "
                  f"种植 {slots['planting']['z_count']} 格×双侧")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(layout, f, ensure_ascii=False, indent=1)

    n_side = {1: sum(1 for b in keep if b["side"] == 1),
              -1: sum(1 for b in keep if b["side"] == -1)}
    print(f"输出: {out_path}")
    print(f"保留建筑 {len(keep)} 栋 (左 {n_side[1]} / 右 {n_side[-1]}) | 街向 {main_ang:.0f}° | 街长 {wsum:.0f}m")
    print(f"咖啡馆替换: {cafe_bld['name'] if cafe_bld else '无'} (s={cafe_anchor['s'] if cafe_anchor else '-'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
