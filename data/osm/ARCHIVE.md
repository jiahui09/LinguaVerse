# OSM 拉取档案 / OSM Pull Archive

每条拉取记录：查询文件、端点 URL、osm3s 时间戳、sha256。历史文档不改写，此文件为实际以什么为准的总账。

## Rue des Rosiers（V1 街景，历史拉取）

- 原始数据：`data/osm/rosiers_full.json`
- 查询：`data/osm/query_rosiers_full.osm`
- 端点：https://overpass-api.de/api/interpreter（S1 会话记录，未存 URL 明文——照此格式补齐）
- osm3s 时间戳：2026-09-06T14:27:46Z
- sha256：`8d4b2175180b41fbffec516250486ccdc80c77001114253a9f4c67018bbebc2f`

### 溯源备注（2026-10-08 发现）

`tools/osm_to_layout.py` 自 S1（441cb3a）从未修改，但**默认运行不能复现仓库中的
`godot-project/data/layouts/rosiers_layout.json`**：

- 工具输出：19 栋 / 4230 字节 / 无 bay_index
- 仓库成品：25 栋 / 5701 字节 / 含 15 栋合成补空楼（id 900000–900014，bay_index 0/1/2）
  + 9 栋被剔除的 OSM 投影

即 S1 提交 = 工具原始输出 + **未入库的编辑后处理**（去重叠 + 连续立面补空）。
`bay_index` 全仓无消费方（死字段）。
防护：`assets_manifest.json → blocks.rosiers.layout.sha256` + street_check 三方核对
会拦住任何误重跑覆盖（重跑即 69 项断言爆红）。历史成品按"不改写历史"原则保留。

## Place des Vosges（P2-B 第二街区）

- 原始数据：`data/osm/place_des_vosges_full.json`
- 查询：`data/osm/query_place_des_vosges_full.osm`（bbox 48.8530,2.3585,48.8585,2.3720）
- 端点：https://overpass-api.de/api/interpreter（第 2 次尝试成功；首发 406 为缺少 UA，
  后续 busy 为服务端瞬态，重试循环解决）
- osm3s 时间戳：2026-10-08T07:58:37Z
- sha256：`0cdd25d475fbf6fcd2415d9386a82b5bd4d2bc85f42851ad12d01b8fd39a4742`
- 元素：2347（buildings 834 / highways 1513）；含 Rue des Rosiers 东段（两街联通用）
- 中线：地名 "Place des Vosges" 挂 18 段混类（residential 外环 + tertiary + 16 条园内
  步道）；贪心拼接实际只链入 2 条车行 way（18232134+22715944，footway 孤立自动断开），
  `--highway-types residential,tertiary` 显式固化该选择
