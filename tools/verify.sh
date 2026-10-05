#!/usr/bin/env bash
# 语宙一键验证入口（P0-B1）
#
# 四层防线的第 ① ② 层（结构断言 + 离线资产/音频校验）+ 后端冒烟；
# 每层只声称自己能证明的事，报告写入 artifacts/verify-report.json，
# 并记录关键输入的 SHA256——资产一变，旧结论即失效（哈希绑定验收）。
#
# 用法：
#   tools/verify.sh                # 全量：结构 + 回放 + 资产 + 冒烟 + 对话回归 + 帧采样
#   tools/verify.sh --quick        # 快速：跳过 LLM 对话回归（dialog_regression）
#   tools/verify.sh --with-llm     # 严格：LLM 相关步骤不可用即失败（默认记 SKIP）

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ART="$ROOT/artifacts"
mkdir -p "$ART"
GODOT="$ROOT/tools/Godot_v4.7.2-stable_linux.x86_64"
BACKEND="$ROOT/backend"
STEPS_TSV="$ART/.steps.tsv"
: > "$STEPS_TSV"

FAILURES=0
REQUIRE_LLM=0
QUICK=0
[ "${1:-}" = "--with-llm" ] && REQUIRE_LLM=1
[ "${1:-}" = "--quick" ] && QUICK=1
[ "${2:-}" = "--quick" ] && QUICK=1

note() { printf '%s\n' "$*"; }

record() { # name status detail
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$STEPS_TSV"
}

run_step() { # name cmd...
  local name="$1"; shift
  local log="$ART/$name.log"
  if "$@" >"$log" 2>&1; then
    note "PASS: $name"
    record "$name" PASS ""
  else
    note "FAIL: $name  (详见 artifacts/$name.log)"
    tail -n 5 "$log" | sed 's/^/       | /'
    FAILURES=$((FAILURES + 1))
    record "$name" FAIL "artifacts/$name.log"
  fi
}

sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }

# 带"跳过码"的步骤：0=PASS，跳过码=SKIP（不伪装通过），其余=FAIL
run_step_tolerant() { # name skip_code cmd...
  local name="$1" skip_code="$2"; shift 2
  local log="$ART/$name.log"
  "$@" >"$log" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    note "PASS: $name"
    record "$name" PASS ""
  elif [ "$rc" -eq "$skip_code" ]; then
    note "SKIP: $name（详见 artifacts/$name.log）"
    record "$name" SKIP "artifacts/$name.log"
  else
    note "FAIL: $name (exit=$rc, 详见 artifacts/$name.log)"
    tail -n 5 "$log" | sed 's/^/       | /'
    FAILURES=$((FAILURES + 1))
    record "$name" FAIL "artifacts/$name.log"
  fi
}

# ── 1/2/3 Godot headless 断言：结构 / 对话状态机 / 闭环回放 ───────────
run_step street_check "$GODOT" --headless --path godot-project -s res://scripts/debug/street_check.gd
run_step dialog_check "$GODOT" --headless --path godot-project -s res://scripts/debug/dialog_check.gd
run_step_tolerant playthrough_check 77 "$GODOT" --headless --path godot-project -s res://scripts/debug/playthrough_check.gd

# ── 帧时间采样（headless=逻辑耗时；真机 LV_PERF_ENFORCE=1 才判阈值） ──
run_step perf_drive env LV_ARTIFACTS_DIR="$ART" "$GODOT" --headless --path godot-project -s res://scripts/debug/perf_drive.gd

# ── 3/4 后端类型与 Prompt 组装 ─────────────────────────────────────────
backend_step() { # name binary...
  local name="$1" bin="$2"; shift 2
  local path="$BACKEND/node_modules/.bin/$bin"
  if [ ! -x "$path" ]; then
    note "SKIP: $name（backend 依赖未安装：cd backend && pnpm install）"
    record "$name" SKIP "backend 依赖未安装"
    return
  fi
  run_step "$name" "$path" "$@"
}
backend_step backend_typecheck tsc --noEmit -p "$BACKEND"
backend_step backend_prompt_check tsx "$BACKEND/scripts/check_prompt.ts"

# ── 5 离线资产校验（哈希绑定） ─────────────────────────────────────────
run_step glb_check python3 "$ROOT/tools/check_glb.py"

# ── 5b 环境音/音效离线校验：格式、体积、无缝循环、峰值、确定性 ─────────
run_step audio_check python3 "$ROOT/tools/check_audio.py"

# ── 6 后端开箱冒烟（build + 启动 + health + 可选 LLM 对话） ────────────
SMOKE_PORT=3999
smoke_backend() {
  local log="$ART/backend_smoke.log"
  : > "$log"
  if [ ! -x "$BACKEND/node_modules/.bin/tsc" ]; then
    echo "SKIP: backend 依赖未安装" >>"$log"
    return 2
  fi

  ( cd "$BACKEND" && ./node_modules/.bin/tsc ) >>"$log" 2>&1 || { echo "tsc build 失败" >>"$log"; return 1; }

  PORT=$SMOKE_PORT node "$BACKEND/dist/server.js" >>"$log" 2>&1 &
  local srv=$!
  sleep 1.5
  if ! kill -0 "$srv" 2>/dev/null; then
    echo "服务启动失败" >>"$log"; return 1
  fi

  local ok=0
  if curl -sf -m 5 "http://localhost:$SMOKE_PORT/api/health" >>"$log" 2>&1; then
    echo "" >>"$log"; ok=1
  else
    echo "health 检查失败" >>"$log"; kill "$srv" 2>/dev/null; return 1
  fi

  # LLM 冒烟：Ollama 可达才执行
  if curl -sf -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    local resp
    resp=$(curl -s -m 60 -X POST "http://localhost:$SMOKE_PORT/api/dialog" \
      -H 'Content-Type: application/json' \
      -d '{"player_input":"bonjour, un café s'"'"'il vous plaît","npc_info":{"name":"Marie","job":"咖啡馆服务员","personality":"热情但忙碌","speaks_french":true},"conversation_history":[{"role":"assistant","content":"Bonjour! Vous désirez?"}],"world_state":{"time_of_day":"day","player_position":{"x":0,"y":0,"z":0}}}')
    echo "$resp" >>"$log"
    kill "$srv" 2>/dev/null
    if echo "$resp" | grep -q '"text"'; then
      echo "LLM 冒烟通过" >>"$log"; return 0
    fi
    echo "LLM 冒烟失败" >>"$log"; return 1
  fi

  kill "$srv" 2>/dev/null
  echo "Ollama 不可达，LLM 冒烟跳过" >>"$log"
  if [ "$REQUIRE_LLM" = "1" ]; then return 1; fi
  return 2
}

smoke_backend
case $? in
  0) note "PASS: backend_smoke（含 LLM 对话）"; record backend_smoke PASS "" ;;
  2) note "SKIP: backend_smoke（LLM 部分不可用，详见 artifacts/backend_smoke.log）"; record backend_smoke SKIP "artifacts/backend_smoke.log" ;;
  *) note "FAIL: backend_smoke  (详见 artifacts/backend_smoke.log)"; FAILURES=$((FAILURES + 1)); record backend_smoke FAIL "artifacts/backend_smoke.log" ;;
esac

# ── 对话回归：固定法语脚本 × N 轮，度量延迟与输出契约 ──────────────────
if [ "$QUICK" = "1" ]; then
  note "SKIP: dialog_regression（--quick 模式）"
  record dialog_regression SKIP "--quick"
elif [ "$REQUIRE_LLM" = "1" ]; then
  run_step dialog_regression node "$ROOT/tools/dialog_regression.mjs"
else
  run_step_tolerant dialog_regression 77 node "$ROOT/tools/dialog_regression.mjs"
fi

# ── 报告：附关键输入 SHA256（资产一变，旧报告失效） ────────────────────
python3 - "$STEPS_TSV" "$ART/verify-report.json" "$ROOT" <<'PY'
import hashlib, json, subprocess, sys, datetime
from pathlib import Path

tsv, out, root = sys.argv[1], sys.argv[2], Path(sys.argv[3])
steps = []
for line in Path(tsv).read_text(encoding="utf-8").splitlines():
    parts = line.split("\t")
    if len(parts) >= 2:
        steps.append({"name": parts[0], "status": parts[1], "detail": parts[2] if len(parts) > 2 else ""})

inputs = {}
for rel in [
    "godot-project/data/layouts/rosiers_layout.json",
    "godot-project/assets/models/cafe.glb",
    "godot-project/data/assets_manifest.json",
    "tools/make_ambience.py",
    "tools/check_audio.py",
]:
    p = root / rel
    if p.exists():
        inputs[rel] = hashlib.sha256(p.read_bytes()).hexdigest()

try:
    commit = subprocess.run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True, check=True).stdout.strip()
except Exception:
    commit = None

ok = all(s["status"] in ("PASS", "SKIP") for s in steps)
report = {
    "tool": "verify.sh",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "ok": ok,
    "steps": steps,
    "inputs": {"sha256": inputs, "git_commit": commit},
    "scope": "结构断言 + 闭环回放(mock) + 离线资产校验 + 音频离线校验(格式/体积/无缝循环/峰值/确定性，不含主观听感) + 后端冒烟 + 帧采样(headless) + LLM 对话回归(延迟与输出契约)；不含画面观感、真机帧率、NPC 人设质量人工评分",
}
Path(out).parent.mkdir(parents=True, exist_ok=True)
Path(out).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"报告: {out}")
PY

rm -f "$STEPS_TSV"

if [ "$FAILURES" -gt 0 ]; then
  note ""
  note "verify: $FAILURES 项失败"
  exit 1
fi
note ""
note "verify: 全部通过（报告见 artifacts/verify-report.json；能证明什么见报告 scope 字段）"
