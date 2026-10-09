#!/usr/bin/env python3
"""LinguaVerse 音频离线校验（tools/verify.sh 的 audio_check 步骤）。

只声称机器可判定的事：
  1 四个 WAV 存在、RIFF/WAVE 头合法、stereo/16-bit/44100Hz（v2 立体声重做）
  2 时长：环境音 6–12s；cup_clink 0.5–0.7s；footstep 0.12–0.30s
  3 体积 ≤ 预算（manifest audio_budgets，缺省 1536000 字节）
  4 环境音无缝循环（分声道、按内容校准）：接缝 |首-尾| ≤ 内容典型斜率且 < 峰值15%；
    首 5ms 最大相邻差 ≤ 内容 p99×1.5
  5 无削波（|s| ≤ 32766）、无直流偏置（分声道均值 < 2% 满幅）
  6 非静音（RMS > 1% 满幅）
  7 cup_clink / footstep：峰值 -6 dBFS ±0.5、首尾 32 帧全零
  8 立体声宽度：L 与 R 采样序列不全等（Haas/pan 生效，非假单声道）
  9 确定性：重跑 make_ambience.py 到临时目录，四个文件字节一致
 10 manifest 的 audio 段：sha256/bytes/seconds 与实文件一致、CC0 声明在位

不声称：听感/音色/响度舒适度（那需要人耳），不声称循环在所有播放器上无感。
退出码：0=全部通过，1=有失败。
"""

import array
import hashlib
import json
import math
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AMBIENT = [
    ROOT / "godot-project/assets/audio/ambient/street_loop.wav",
    ROOT / "godot-project/assets/audio/ambient/cafe_loop.wav",
]
CLINK = ROOT / "godot-project/assets/audio/sfx/cup_clink.wav"
FOOTSTEP = ROOT / "godot-project/assets/audio/sfx/footstep.wav"
MANIFEST = ROOT / "godot-project/data/assets_manifest.json"
GENERATOR = ROOT / "tools/make_ambience.py"

FS = 32767.0
CLINK_PAD = 32

failures = 0


def check(cond, label, detail=""):
    tag = "PASS" if cond else "FAIL"
    line = f"[{tag}] {label}"
    if detail:
        line += f" ({detail})"
    print(line)
    if not cond:
        global failures
        failures += 1


def read_wav(path):
    """返回 (samples:list[int], params dict)；读取失败时抛异常。"""
    with wave.open(str(path), "rb") as w:
        params = {
            "channels": w.getnchannels(),
            "sampwidth": w.getsampwidth(),
            "rate": w.getframerate(),
            "nframes": w.getnframes(),
        }
        raw = w.readframes(params["nframes"])
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder != "little":
        a.byteswap()
    return list(a), params


def main():
    # ── 1) 存在与格式 ─────────────────────────────────────────
    data = {}
    for p in AMBIENT + [CLINK, FOOTSTEP]:
        name = p.name
        check(p.exists(), f"{name} 存在")
        if not p.exists():
            continue
        try:
            samples, params = read_wav(p)
        except Exception as exc:  # noqa: BLE001 - 校验脚本要报告而非抛出
            check(False, f"{name} RIFF/WAVE 可解析", str(exc))
            continue
        check(params["channels"] == 2, f"{name} 立体声", str(params["channels"]))
        check(params["sampwidth"] == 2, f"{name} 16-bit", str(params["sampwidth"]))
        check(params["rate"] == 44100, f"{name} 44100Hz", str(params["rate"]))
        data[p] = (samples, params)

    # ── 2) 时长与体积 ────────────────────────────────────────
    budgets = {"max_audio_bytes": 1536000, "max_audio_sec": 12, "min_audio_sec": 0.5}
    if MANIFEST.exists():
        try:
            budgets.update(json.loads(MANIFEST.read_text(encoding="utf-8"))
                           .get("audio_budgets", {}))
        except Exception:  # noqa: BLE001
            pass

    for p in AMBIENT:
        if p not in data:
            continue
        samples, _ = data[p]
        sec = len(samples) / 2 / 44100.0
        check(6.0 <= sec <= budgets["max_audio_sec"], f"{p.name} 时长 {sec:.2f}s 在 6–{budgets['max_audio_sec']}s")
        check(p.stat().st_size <= budgets["max_audio_bytes"],
              f"{p.name} 体积 {p.stat().st_size}B ≤ {budgets['max_audio_bytes']}B")

    if CLINK in data:
        samples, _ = data[CLINK]
        sec = len(samples) / 2 / 44100.0
        check(0.5 <= sec <= 0.7, f"cup_clink 时长 {sec:.2f}s 在 0.5–0.7s")
        check(CLINK.stat().st_size <= budgets["max_audio_bytes"],
              f"cup_clink 体积 {CLINK.stat().st_size}B ≤ {budgets['max_audio_bytes']}B")

    if FOOTSTEP in data:
        samples, _ = data[FOOTSTEP]
        sec = len(samples) / 2 / 44100.0
        check(0.12 <= sec <= 0.30, f"footstep 时长 {sec:.2f}s 在 0.12–0.30s")
        check(FOOTSTEP.stat().st_size <= budgets["max_audio_bytes"],
              f"footstep 体积 {FOOTSTEP.stat().st_size}B ≤ {budgets['max_audio_bytes']}B")

    # ── 4) 无缝循环（分声道）+ 5) 削波/直流 + 6) 非静音 ──────
    for p in AMBIENT:
        if p not in data:
            continue
        samples, _ = data[p]
        L, R = samples[0::2], samples[1::2]
        peak = max(abs(s) for s in samples)
        for ci, (ch, cname) in enumerate(((L, "L"), (R, "R"))):
            seam = abs(ch[0] - ch[-1])
            # 接缝判据按内容校准（v2 中频声景在 44.1kHz 下样间斜率天然大，
            # v1 的固定 1% 峰值阈值只适配全低频内容）：
            #   接缝不比内容典型斜率陡（防把两段不相干信号硬接）+ 绝对上限防阶跃
            diffs = [abs(ch[i + 1] - ch[i]) for i in range(len(ch) - 1)]
            ds = sorted(diffs)
            p99 = ds[int(len(ds) * 0.99)]
            head = max(diffs[:int(0.005 * 44100)])  # 首 5ms @44100
            check(seam <= max(head, 1) and seam < peak * 0.15,
                  f"{p.name} 无缝循环({cname}): |首-尾|={seam} ≤ 内容斜率{head}"
                  f" 且 < 峰值15%={peak * 0.15:.1f}")
            check(head <= p99 * 1.5,
                  f"{p.name} 首5ms无异常突跳({cname}): 最大相邻差={head}"
                  f" ≤ 内容p99×1.5={p99 * 1.5:.0f}")
            mean = sum(ch) / len(ch)
            check(abs(mean) < 0.02 * 32768, f"{p.name} 无直流偏置({cname}, 均值 {mean:.1f})")
        check(peak <= 32766, f"{p.name} 无削波 (峰值 {peak})")
        rms = math.sqrt(sum(s * s for s in samples) / len(samples))
        check(rms > 0.01 * 32768, f"{p.name} 非静音 (RMS {rms:.0f})")
        # v2 立体声宽度：L≠R（Haas+pan；假单声道会在这里被抓）
        diff = sum(1 for a, b in zip(L, R) if a != b) / max(1, len(L))
        check(diff > 0.05, f"{p.name} 立体声宽度 (L≠R 采样占比 {diff:.0%})")

    # ── 7) cup_clink / footstep 峰值/首尾置零/削波/直流 ─────
    for p, label in ((CLINK, "cup_clink"), (FOOTSTEP, "footstep")):
        if p not in data:
            continue
        samples, _ = data[p]
        peak = max(abs(s) for s in samples)
        peak_db = 20 * math.log10(peak / FS)
        check(-6.5 <= peak_db <= -5.5, f"{label} 峰值 {peak_db:.2f} dBFS ∈ [-6.5,-5.5]")
        pad = CLINK_PAD * 2  # 32 帧 × 2ch 交织
        check(all(s == 0 for s in samples[:pad]),
              f"{label} 首 {CLINK_PAD} 帧为 0")
        check(all(s == 0 for s in samples[-pad:]),
              f"{label} 末 {CLINK_PAD} 帧为 0")
        check(peak <= 32766, f"{label} 无削波 (峰值 {peak})")
        L, R = samples[0::2], samples[1::2]
        for ch, cname in ((L, "L"), (R, "R")):
            mean = sum(ch) / len(ch)
            check(abs(mean) < 0.02 * 32768, f"{label} 无直流偏置({cname}, 均值 {mean:.1f})")
        rms = math.sqrt(sum(s * s for s in samples) / len(samples))
        check(rms > 0.01 * 32768, f"{label} 非静音 (RMS {rms:.0f})")
        diff = sum(1 for a, b in zip(L, R) if a != b) / max(1, len(L))
        check(diff > 0.0, f"{label} 立体声存在 (L≠R 采样占比 {diff:.0%})")

    # ── 9) 确定性：重跑生成器字节一致 ─────────────────────────
    all_ok = all(p.exists() for p in AMBIENT + [CLINK, FOOTSTEP])
    if all_ok:
        try:
            with tempfile.TemporaryDirectory() as tmp:
                proc = subprocess.run(
                    [sys.executable, str(GENERATOR), "--out", tmp],
                    capture_output=True, text=True, timeout=120)
                check(proc.returncode == 0, "确定性：重跑生成器退出码 0",
                      proc.stderr.strip()[-120:])
                for p in AMBIENT + [CLINK, FOOTSTEP]:
                    q = Path(tmp) / p.name
                    same = q.exists() and hashlib.sha256(q.read_bytes()).hexdigest() \
                        == hashlib.sha256(p.read_bytes()).hexdigest()
                    check(same, f"确定性：{p.name} 二次生成 SHA256 一致")
        except Exception as exc:  # noqa: BLE001
            check(False, "确定性：重跑生成器", str(exc))

    # ── 10) manifest audio 段 ─────────────────────────────────
    if MANIFEST.exists():
        m = json.loads(MANIFEST.read_text(encoding="utf-8"))
        audio = m.get("audio", {})
        check(len(audio) == 4, "manifest audio 段含 4 条", str(len(audio)))
        for key, p in (("street_loop", AMBIENT[0]), ("cafe_loop", AMBIENT[1]),
                       ("cup_clink", CLINK), ("footstep", FOOTSTEP)):
            entry = audio.get(key)
            if not entry:
                check(False, f"manifest 有 {key} 条目")
                continue
            if not p.exists():
                continue
            sha = hashlib.sha256(p.read_bytes()).hexdigest()
            check(entry.get("sha256") == sha, f"manifest {key} sha256 与文件一致")
            check(entry.get("bytes") == p.stat().st_size,
                  f"manifest {key} bytes 与文件一致")
            with wave.open(str(p), "rb") as w:
                real_sec = w.getnframes() / w.getframerate()
            check(abs(entry.get("seconds", -1) - real_sec) < 0.01,
                  f"manifest {key} seconds 与文件一致 ({real_sec:.2f}s)")
            check("CC0" in str(entry.get("source", "")) and "程序合成" in str(entry.get("source", "")),
                  f"manifest {key} source 声明 CC0 程序合成")
            check(bool(entry.get("generator_sha256")),
                  f"manifest {key} 含 generator_sha256")
    else:
        check(False, "manifest 存在")

    print(f"check_audio: {'全部通过' if failures == 0 else str(failures) + ' 项失败'}"
          f"（不声称主观听感）")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
