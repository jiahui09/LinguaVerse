# job — place_des_vosges（首地标对象：Place des Vosges 对称红砖拱廊）

- 决策 24：首地标 = Place des Vosges 对称红砖拱廊（不改选巴黎圣母院外景）。
- 决策 28：五件套 `job/prompt/evidence/model/validation.json` + 八项具名验收；
  browser 项按 §P2-B 如实降级为 llvmpipe 位置抽查。
- 方案 §P3 行 7：`currentStage≥modelled` + sha 绑定；browser/silhouette 如实标
  llvmpipe/真机待验。
- 摆位：vosges 布局主侧中央空档 s=195.3..218.4（23.1m，左邻 Pavillon du Roi
  face=7.87，右邻 Hôtel de Montmorin face=13.07），拱廊前脸贴 face=7.87 线，
  右端回墙收 5.2m 错台为内凹转角。
- 预算：单对象三角形软帽 1500（65k 三街总预算余量 ≈9.3k 留给批次 7/8，
  批次 6 决策 29 修订批批准）；GLB ≤8MiB。
- 产出：`tools/blender/landmarks/place_des_vosges.py` → `artifacts/landmark-glb/`
  → 过闸拷入 `godot-project/assets/models/place_des_vosges.glb`。
