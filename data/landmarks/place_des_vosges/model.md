# model — place_des_vosges（构建管线记录）

## 命令
```
tools/blender-4.2.8-linux-x64/blender --background \
    --python tools/blender/landmarks/place_des_vosges.py
# → artifacts/landmark-glb/place_des_vosges.glb + report.json
cp artifacts/landmark-glb/place_des_vosges.glb godot-project/assets/models/
python3 tools/check_glb.py --update          # manifest.assets 收录
tools/Godot_v4.7.2-stable_linux.x86_64 --headless --path godot-project --import
python3 tools/landmark_tasks.py bind place_des_vosges   # 三处 sha 绑定
```

## 实测（report.json / manifest.assets）
- triangles=1104（软帽 1500），materials=brick/stone/inner，primitives=3，
  bytes=80,356（≤8MiB），generator=Khronos glTF Blender I/O v4.2.83。
- 坐标变换：Godot (X,Y,Z) ←→ Blender (X,Z,−Y)；前脸 x=0，摆位由
  street_generator 读 `layout.meta.landmarks`（side·face, s_center）落位。
- 81+ 盒部件 join 单 mesh；导出 `export_yup=True`。

## sha（bind 后写入 validation.json 与 manifest["landmarks"]，勿手改）
见 `validation.json` sourceSha256/artifactSha256。
