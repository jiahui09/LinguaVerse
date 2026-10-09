#!/usr/bin/env python3
"""landmark_tasks.py — 地标对象五件套验收状态机（P3 批次7，方案 §P2-B 行1/决策28）

对象五件套（`data/landmarks/<id>/`）:
  job.md         对象定义/范围/预算
  prompt.md      建模规格（几何/尺寸/材质/坐标约定/输出）
  evidence.md    真实形制证据（参考来源与关键尺寸）
  model.md       构建管线记录（命令/工具版本/坐标变换）
  validation.json  状态机 + 八项具名验收 + sha 绑定

阶段: planned → evidence-ready → modelled → verified（本机 browser 项降级 llvmpipe，
真机待验项如实记录；currentStage ≥ modelled 才放行 verify 的 glb_check 步）。

八项具名验收（每项 status/reviewedBy/reviewedAt/evidencePaths）:
  scale / orientation / silhouette / context / collision / browser / performance / provenance

用法:
  python3 tools/landmark_tasks.py init <id>      # 建五件套模板（幂等）
  python3 tools/landmark_tasks.py bind <id>      # 算 sha → validation.json + manifest["landmarks"]
  python3 tools/landmark_tasks.py status [<id>]  # 打印 stage/八项/sha 一致性
  python3 tools/landmark_tasks.py validate [<id>]  # 全量门禁（缺一即 FAIL, exit 1）

sha 绑定链（决策28"源或 GLB 一变旧验收即失效"）:
  tools/blender/landmarks/<module>.py (source_sha256)
    → godot-project/assets/models/<id>.glb (artifact_sha256, 同 manifest.assets)
    → data/assets_manifest.json ["landmarks"][id]
三处任一不符 → validate FAIL（改源必须重跑 Blender、重 bind、重走人工验收）。
"""

import hashlib
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LM_DIR = os.path.join(ROOT, "data", "landmarks")
MANIFEST = os.path.join(ROOT, "godot-project", "data", "assets_manifest.json")
GLB_REL = "godot-project/assets/models/%s.glb"
SRC_REL = "tools/blender/landmarks/%s.py"   # 模块名 = id（对象一模块）

STAGES = ["planned", "evidence-ready", "modelled", "verified"]
CHECK_NAMES = ["scale", "orientation", "silhouette", "context",
               "collision", "browser", "performance", "provenance"]
FIVE = ["job.md", "prompt.md", "evidence.md", "model.md", "validation.json"]
MAX_GLB_BYTES = 8 * 1024 * 1024


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _path(lm_id):
    return os.path.join(LM_DIR, lm_id)


def cmd_init(lm_id):
    d = _path(lm_id)
    os.makedirs(d, exist_ok=True)
    made = []
    tpl = {
        "job.md": "# job — %s\n\n（对象定义/范围/预算；方案 §P2-B 五件套）\n" % lm_id,
        "prompt.md": "# prompt — %s\n\n（建模规格：几何/尺寸/材质/坐标约定 Godot(X,Y,Z)↔Blender(X,Z,−Y)/输出）\n" % lm_id,
        "evidence.md": "# evidence — %s\n\n（真实形制证据：参考来源与关键尺寸）\n" % lm_id,
        "model.md": "# model — %s\n\n（构建命令/Blender 版本/坐标变换/报告数字；bind 后自动附 sha）\n" % lm_id,
    }
    for fn, body in tpl.items():
        p = os.path.join(d, fn)
        if not os.path.exists(p):
            with open(p, "w", encoding="utf-8") as f:
                f.write(body)
            made.append(fn)
    vp = os.path.join(d, "validation.json")
    if not os.path.exists(vp):
        v = {
            "id": lm_id,
            "currentStage": "planned",
            "stages": STAGES,
            "checks": {
                n: {"status": "pending", "reviewedBy": "", "reviewedAt": "",
                    "evidencePaths": [], "note": ""}
                for n in CHECK_NAMES
            },
            "sourceSha256": "",
            "artifactSha256": "",
        }
        with open(vp, "w", encoding="utf-8") as f:
            json.dump(v, f, ensure_ascii=False, indent=2)
        made.append("validation.json")
    print("[landmark] init %s: 新建 %s（已存在跳过）" % (lm_id, made or "无"))


def _load_val(lm_id):
    p = os.path.join(_path(lm_id), "validation.json")
    with open(p, encoding="utf-8") as f:
        return json.load(f), p


def cmd_bind(lm_id):
    glb = os.path.join(ROOT, GLB_REL % lm_id)
    src = os.path.join(ROOT, SRC_REL % lm_id)
    if not os.path.exists(glb):
        print("[landmark] bind FAIL: GLB 不存在 %s（先过闸拷入）" % glb)
        return 1
    if not os.path.exists(src):
        print("[landmark] bind FAIL: 源模块不存在 %s" % src)
        return 1
    art = sha256_file(glb)
    src_sha = sha256_file(src)
    v, vp = _load_val(lm_id)
    v["artifactSha256"] = art
    v["sourceSha256"] = src_sha
    if v["currentStage"] in ("planned", "evidence-ready"):
        v["currentStage"] = "modelled"
    with open(vp, "w", encoding="utf-8") as f:
        json.dump(v, f, ensure_ascii=False, indent=2)
    with open(MANIFEST, encoding="utf-8") as f:
        m = json.load(f)
    m.setdefault("landmarks", {})[lm_id] = {
        "glb": GLB_REL % lm_id,
        "source": SRC_REL % lm_id,
        "source_sha256": src_sha,
        "artifact_sha256": art,
        "bytes": os.path.getsize(glb),
        "stage": v["currentStage"],
    }
    m["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=2)
    print("[landmark] bind %s: stage=%s art=%s src=%s（已写 manifest[landmarks]）"
          % (lm_id, v["currentStage"], art[:12], src_sha[:12]))
    return 0


def _validate_one(lm_id):
    errs = []
    d = _path(lm_id)
    for fn in FIVE:
        if not os.path.exists(os.path.join(d, fn)):
            errs.append("五件套缺 %s" % fn)
    if errs:
        return errs
    v, _ = _load_val(lm_id)
    stage = v.get("currentStage", "")
    if stage not in STAGES:
        errs.append("currentStage 非法: %r" % stage)
    elif STAGES.index(stage) < STAGES.index("modelled"):
        errs.append("currentStage=%s < modelled（未达放行线）" % stage)
    for n in CHECK_NAMES:
        c = v.get("checks", {}).get(n)
        if c is None:
            errs.append("八项缺 %s" % n)
            continue
        if not c.get("status") or c["status"] == "pending":
            errs.append("验收 %s 未评" % n)
        for k in ("reviewedBy", "reviewedAt"):
            if not c.get(k):
                errs.append("验收 %s 缺 %s" % (n, k))
        eps = c.get("evidencePaths") or []
        if not eps:
            errs.append("验收 %s 缺 evidencePaths" % n)
        for ep in eps:
            if not os.path.exists(os.path.join(ROOT, ep)):
                errs.append("验收 %s 证据不存在: %s" % (n, ep))
    glb = os.path.join(ROOT, GLB_REL % lm_id)
    src = os.path.join(ROOT, SRC_REL % lm_id)
    if not os.path.exists(glb):
        errs.append("GLB 不存在 %s" % (GLB_REL % lm_id))
    else:
        art = sha256_file(glb)
        if art != v.get("artifactSha256"):
            errs.append("artifactSha256 失配（GLB 变了 → 重 bind + 重走验收）")
        if os.path.getsize(glb) > MAX_GLB_BYTES:
            errs.append("GLB > 8MiB")
    if not os.path.exists(src):
        errs.append("源模块不存在 %s" % (SRC_REL % lm_id))
    else:
        if sha256_file(src) != v.get("sourceSha256"):
            errs.append("sourceSha256 失配（源变了 → 重跑 Blender + 重 bind）")
    with open(MANIFEST, encoding="utf-8") as f:
        m = json.load(f)
    e = m.get("landmarks", {}).get(lm_id)
    if e is None:
        errs.append("manifest[landmarks] 无条目（跑 bind）")
    else:
        if e.get("artifact_sha256") != v.get("artifactSha256"):
            errs.append("manifest artifact_sha256 与 validation.json 失配")
        if e.get("source_sha256") != v.get("sourceSha256"):
            errs.append("manifest source_sha256 与 validation.json 失配")
    return errs


def cmd_validate(lm_id=None):
    ids = [lm_id] if lm_id else sorted(
        e for e in os.listdir(LM_DIR) if os.path.isdir(os.path.join(LM_DIR, e))
    ) if os.path.isdir(LM_DIR) else []
    if not ids:
        print("[landmark] validate: 无地标对象目录（%s）" % LM_DIR)
        return 0
    bad = 0
    for i in ids:
        errs = _validate_one(i)
        if errs:
            bad += 1
            for e in errs:
                print("[landmark] FAIL %s: %s" % (i, e))
        else:
            v, _ = _load_val(i)
            print("[landmark] OK %s (stage=%s, 八项全评, sha 三处一致)" % (i, v["currentStage"]))
    return 1 if bad else 0


def cmd_status(lm_id=None):
    ids = [lm_id] if lm_id else sorted(os.listdir(LM_DIR)) if os.path.isdir(LM_DIR) else []
    for i in ids:
        v, _ = _load_val(i)
        done = [n for n, c in v.get("checks", {}).items()
                if c.get("status") not in ("pending", "")]
        print("[landmark] %s stage=%s 八项已评=%d/8 art=%s src=%s"
              % (i, v.get("currentStage"), len(done),
                 v.get("artifactSha256", "")[:12], v.get("sourceSha256", "")[:12]))
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("init", "bind", "status", "validate"):
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    lm_id = sys.argv[2] if len(sys.argv) > 2 else None
    if cmd in ("init", "bind") and not lm_id:
        print("用法: landmark_tasks.py %s <id>" % cmd)
        return 2
    if cmd == "init":
        cmd_init(lm_id)
        return 0
    if cmd == "bind":
        return cmd_bind(lm_id)
    if cmd == "status":
        return cmd_status(lm_id)
    return cmd_validate(lm_id)


if __name__ == "__main__":
    sys.exit(main())
