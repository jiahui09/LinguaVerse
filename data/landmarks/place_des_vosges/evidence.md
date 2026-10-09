# evidence — place_des_vosges（真实形制证据）

- 对象：Place des Vosges（巴黎孚日广场，1605–1612），巴黎最早规划广场，
  统一红砖 + 白石转角、陡坡锌板屋顶的对称联排；底层连续拱廊（36 座拱券）
  是广场招牌件（决策 24 引用的"对称红砖拱廊几何规整"依据）。
- 我们取首层拱廊形制：半圆券 + 红砖墩 + 白石券面/檐口，尺度对齐
  真实拱廊净高 ≈4m、券净宽 ≈4–5m（本模型 4.0 / 4.2–5.2m）。
- 摆位证据：`godot-project/data/layouts/vosges_layout.json`（OSM ODbL，
  origin 48.85602/2.368252）——主侧 heritage 建筑（Hôtel 群 9.6m/3 层）间
  中央空档 s=195.3..218.4；左邻 Pavillon du Roi（s180–195.3, face=7.87）、
  右邻 Hôtel de Montmorin（s218.4–241.7, face=13.07），两者 face 错台 5.2m
  由右端回墙收为内凹转角（如实反映 OSM 地块不规则，不冒充统一红线）。
- 布局 sha 见 `data/assets_manifest.json` blocks.vosges.layout（随本批 meta
  .landmarks 追加同步重算）。
