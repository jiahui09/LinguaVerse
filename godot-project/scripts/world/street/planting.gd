extends RefCounted

## 街景子系统 — 预算制种植计划 (纯函数, 不碰场景树)
## 借 GTA_SZ city-roadside-planting.ts 思路: 总预算 / 逐格上限 / 拒绝原因记录。
##   - 只产出 "位置 + 拒绝记录"; 几何生成由 street_furniture.gd 消费 plan 结果。
##   - 确定性: z 网格扫描 + 双侧固定顺序, 无随机 → 同参数得同位置序列
##     (Tree_* 序号稳定, 拆分前后截图可比)。
##   - 避让策略唯一写入者: blocked() 同时供行道树与路灯调用 (单点修改)。

const PARAMS := {
	"budget_total": 12,        # 总预算 (槽位 = z_count × 两侧)
	"cell_size": 12.0,         # 逐格宽度 (= 一个 z 步长, 验收口径)
	"per_cell": 2,             # 每格上限 (两侧各一)
	"z_from": -30.0,           # 种植带起点 (与 NPC 巡游带对齐, 见装配器头注)
	"z_step": 12.0,
	"z_count": 6,              # -30, -18, -6, 6, 18, 30
	"prop_x": 4.78,            # 树/灯统一 x (边界算术见装配器头注释)
	"cafe_door_z": 4.34,       # = layout cafe_anchor.s (street_check 断言二者同步)
	"cafe_door_clear": 3.5,    # 咖啡馆门口缓冲半径
	"npc_clear": 1.6,          # 距 NPC 定点最小净距 (Jean)
	"npc_x": 5.5,
	"npc_z": -3.66,
}

## 拒绝原因闭集 (验收断言: 一切拒绝必须落在本集合内, 禁止散落字符串)
const REASONS := ["cafe_door_buffer", "npc_clearance", "cell_cap", "budget_exhausted"]

func params() -> Dictionary:
	return PARAMS

func param_hash() -> String:
	return str(PARAMS).sha256_text()

## 实例入口 (装配器): 用默认参数计划
func plan() -> Dictionary:
	return plan_with(PARAMS)

## 静态核心 (测试可带覆盖参数, 例如压低预算验证 budget_exhausted 路径)
static func plan_with(base: Dictionary, overrides: Dictionary = {}) -> Dictionary:
	var p: Dictionary = base.duplicate()
	for k in overrides:
		p[k] = overrides[k]
	var positions: Array = []
	var rejected: Array = []
	var budget := int(p["budget_total"])
	var per_cell := int(p["per_cell"])
	for i in int(p["z_count"]):
		var z := float(p["z_from"]) + float(i) * float(p["z_step"])
		var cell_used := 0
		for side_v in [1.0, -1.0]:
			var side := float(side_v)
			var reason := blocked(side, z, p)
			if reason != "":
				rejected.append({"z": z, "side": side, "reason": reason})
				continue
			if positions.size() >= budget:
				rejected.append({"z": z, "side": side, "reason": "budget_exhausted"})
				continue
			if cell_used >= per_cell:
				rejected.append({"z": z, "side": side, "reason": "cell_cap"})
				continue
			positions.append({"x": side * float(p["prop_x"]), "z": z, "side": side})
			cell_used += 1
	return {"positions": positions, "rejected": rejected, "planted": positions.size()}

## 避让策略: 返回 "" (可种) 或 REASONS 中的原因。
## 咖啡馆与 Jean 都在 +X 侧 → -X 半永远可种 (与拆分前行为一致)。
static func blocked(side: float, z: float, p: Dictionary) -> String:
	if side <= 0.0:
		return ""
	if absf(z - float(p["cafe_door_z"])) < float(p["cafe_door_clear"]):
		return "cafe_door_buffer"
	var d := Vector2(side * float(p["prop_x"]), z).distance_to(
		Vector2(float(p["npc_x"]), float(p["npc_z"])))
	if d < float(p["npc_clear"]):
		return "npc_clearance"
	return ""
