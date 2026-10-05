#!/usr/bin/env python3
"""LinguaVerse 环境音/音效程序合成器（CC0，零下载、纯标准库）。

生成三个 16-bit mono 22050Hz WAV：
  godot-project/assets/audio/ambient/street_loop.wav   街道环境音（循环）
  godot-project/assets/audio/ambient/cafe_loop.wav     咖啡馆室内音（循环）
  godot-project/assets/audio/sfx/cup_clink.wav         点单杯碟轻碰（0.6s 单次）

设计要点：
  * 确定性：固定种子 + 固定迭代顺序，重复运行字节一致
  * 无缝循环：先合成 T+X（X=0.5s）缓冲，再做「尾接头」交叉折叠：
        out[i] = (i/X)*b[i] + (1-i/X)*b[i+T]   (i < X)
        out[i] = b[i]                          (i >= X)
    于是 out[T-1]=b[T-1] 与 out[0]=b[T] 是原缓冲的相邻采样，接缝天然连续
  * 所有低频调制都取 k/循环时长 的整数倍基频，保证周期性
  * 事件（鸟叫/杯碰）只落在 [X, T) 内，绝不骑在接缝上
  * 无 numpy/scipy：一阶低通、带通（两个低通相减）、正弦分量全部手写

用法：
  python3 tools/make_ambience.py                 # 写入仓库并更新 manifest 的 audio 段
  python3 tools/make_ambience.py --out /tmp/x     # 只写 WAV（供校验器做确定性比对）
"""

import argparse
import array
import hashlib
import json
import math
import random
import sys
import wave
from pathlib import Path

SR = 22050
SEED = 20260601
XFADE_SEC = 0.5
AMBIENT_SECONDS = 8.0
CLINK_SECONDS = 0.6
PEAK_TARGET = 0.5            # 归一化峰值（≈ -6 dBFS）
CLINK_PEAK = 0.5012          # -6.0 dBFS
CLINK_PAD_ZEROS = 32         # 首尾置零采样数

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_AMBIENT = ROOT / "godot-project/assets/audio/ambient"
DEFAULT_OUT_SFX = ROOT / "godot-project/assets/audio/sfx"
MANIFEST = ROOT / "godot-project/data/assets_manifest.json"
SOURCE_NOTE = "CC0-1.0 程序合成（本仓库 tools/make_ambience.py，无第三方素材）"


# ────────────────────────── 基础工具 ──────────────────────────

def one_pole_lp(buf, alpha):
    """一阶低通，就地返回新列表。"""
    out = []
    y = 0.0
    a = alpha
    for x in buf:
        y += a * (x - y)
        out.append(y)
    return out


def normalize(samples, peak):
    m = max(abs(x) for x in samples)
    if m <= 0.0:
        raise ValueError("合成结果为静音")
    k = peak / m
    return [x * k for x in samples]


def crossfade_loop(buf, total, period, xfade):
    """把长度 total=period+xfade 的缓冲折叠成长度 period 的无缝循环。"""
    out = [0.0] * period
    for i in range(xfade):
        w = i / xfade
        out[i] = w * buf[i] + (1.0 - w) * buf[i + period]
    out[xfade:period] = buf[xfade:period]
    return out


def write_wav(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = array.array('h')
    for x in samples:
        v = int(round(x * 32767.0))
        if v > 32767:
            v = 32767
        elif v < -32768:
            v = -32768
        pcm.append(v)
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def sha256_of(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ────────────────────────── 街道环境音 ──────────────────────────

def synth_street():
    dur = AMBIENT_SECONDS
    T = int(dur * SR)
    Xn = int(XFADE_SEC * SR)
    N = T + Xn
    rng = random.Random(SEED)

    # 1) 城市底噪：布朗噪声（低频轰鸣）→ 两道一阶低通
    brown = 0.0
    rumble_in = []
    for _ in range(N):
        brown = (brown + rng.gauss(0.0, 1.0) * 0.05) * 0.998
        rumble_in.append(brown)
    rumble = one_pole_lp(one_pole_lp(rumble_in, 0.06), 0.06)

    # 2) 远处车流呼啸：白噪 → 更狠的低通（几乎只剩包络起伏）
    whoosh_in = [rng.gauss(0.0, 1.0) for _ in range(N)]
    whoosh = one_pole_lp(whoosh_in, 0.01)

    # 3) 周期性调制：基频 = 1/dur 及其整数倍 → 天然周期，无缝
    out = []
    for i in range(N):
        t = i / SR
        g_swell = 0.55 + 0.30 * math.sin(2 * math.pi * 2 * t / dur + 0.9) \
                       + 0.15 * math.sin(2 * math.pi * 5 * t / dur + 2.3)
        g_whoosh = 0.60 + 0.40 * math.sin(2 * math.pi * 1 * t / dur + 4.1)
        out.append(rumble[i] * g_swell + whoosh[i] * 6.0 * g_whoosh)

    # 4) 确定性的稀疏鸟叫（只落在 [Xn, T) 内，绝不骑缝）
    events = 3
    for _ in range(events):
        start = rng.uniform(Xn + 0.3 * SR, T - 0.8 * SR)
        start = int(start)
        chirp_dur = 0.14
        chirp_n = int(chirp_dur * SR)
        f0 = rng.uniform(2400.0, 2800.0)
        f1 = f0 + rng.uniform(600.0, 1000.0)
        amp = rng.uniform(0.05, 0.08)
        for k in range(chirp_n):
            tt = k / SR
            p = k / chirp_n
            # 线性扫频的连续相位：2π(f0·t + (f1-f0)t²/(2·dur))
            phase = 2 * math.pi * (f0 * tt + (f1 - f0) * tt * tt / (2 * chirp_dur))
            env = math.sin(math.pi * p) ** 2
            out[start + k] += amp * env * math.sin(phase)

    looped = crossfade_loop(out, N, T, Xn)
    return normalize(looped, PEAK_TARGET)


# ────────────────────────── 咖啡馆室内音 ──────────────────────────

def synth_cafe():
    dur = AMBIENT_SECONDS
    T = int(dur * SR)
    Xn = int(XFADE_SEC * SR)
    N = T + Xn
    rng = random.Random(SEED + 1)

    # 1) 房间底噪：白噪 → 4 级低通（0.06）。单级低通在奈奎斯特处仍有 ~2.6% 增益，
    #    会留下可闻嘶声并顶破接缝差分预算；4 级后高频增益 ≈ (0.06/1.94)^4 ≈ 9e-7，干净。
    room = [rng.gauss(0.0, 1.0) for _ in range(N)]
    for _ in range(4):
        room = one_pole_lp(room, 0.06)
    room = [x * 8.0 for x in room]

    # 2) 人声 murmur 感：两组 4 级低通相减 ≈ [60, 250]Hz 深闷带通（"隔着墙的交谈"，
    #    规格要求绝不能像说话）。陡峭裙边保证带外高频残余 ≈ 1e-5 量级。
    murmur_in = [rng.gauss(0.0, 1.0) for _ in range(N)]
    hi = murmur_in
    for _ in range(4):
        hi = one_pole_lp(hi, 0.14)
    lo = hi
    for _ in range(4):
        lo = one_pole_lp(lo, 0.05)
    band = [h - l for h, l in zip(hi, lo)]

    # 3) 低频暖 hum（92/138Hz 非工频）+ 周期性调制（k/T 基频 → 天然无缝）
    out = []
    w1 = 2 * math.pi * 92.0 / SR
    w2 = 2 * math.pi * 138.0 / SR
    for i in range(N):
        t = i / SR
        hum = 0.02 * math.cos(w1 * i) + 0.015 * math.cos(w2 * i + 0.7)
        murmur_env = 0.5 + 0.3 * math.sin(2 * math.pi * 3 * t / dur + 0.4) \
                         + 0.2 * math.sin(2 * math.pi * 7 * t / dur + 1.9)
        out.append(room[i] + hum + band[i] * 1.8 * murmur_env)

    # 4) 稀疏杯盘轻碰（与 cup_clink 同族分量、更轻更短），落在 [Xn+0.3, T-0.8)，绝不骑缝
    for _ in range(4):
        start = int(rng.uniform(Xn + 0.3 * SR, T - 0.8 * SR))
        amp = rng.uniform(0.05, 0.09)
        f_base = rng.choice([2100.0, 2350.0])
        partials = [(f_base, 1.0, 0.10), (f_base * 1.5, 0.6, 0.07), (f_base * 2.1, 0.35, 0.05)]
        clink_n = int(0.25 * SR)
        for (f, a, tau) in partials:
            w = 2 * math.pi * f / SR
            amp_i = a * amp
            for k in range(clink_n):
                out[start + k] += amp_i * math.sin(w * k) * math.exp(-k / (tau * SR))

    looped = crossfade_loop(out, N, T, Xn)
    return normalize(looped, PEAK_TARGET)


# ────────────────────────── 杯碟轻碰音效 ──────────────────────────

def synth_clink():
    n = int(CLINK_SECONDS * SR)
    rng = random.Random(SEED + 2)
    out = [0.0] * n

    # 陶瓷分量：非整数倍频率 + 各自指数衰减
    partials = [(2100.0, 1.00, 0.14),
                (3150.0, 0.62, 0.10),
                (4370.0, 0.42, 0.07),
                (5820.0, 0.26, 0.05)]
    for (f, a, tau) in partials:
        w = 2 * math.pi * f / SR
        for k in range(n):
            out[k] += a * math.sin(w * k) * math.exp(-k / (tau * SR))

    # 敲击瞬态：前 ~4ms 的窄噪声脉冲
    for k in range(int(0.004 * SR)):
        out[k] += 0.7 * rng.gauss(0.0, 1.0) * math.exp(-k / (0.0015 * SR))

    # 先首尾置零（去 click），再归一化到 -6 dBFS（置零处保持为 0）
    for k in range(CLINK_PAD_ZEROS):
        out[k] = 0.0
        out[-1 - k] = 0.0
    return normalize(out, CLINK_PEAK)


# ────────────────────────── manifest 增量 ──────────────────────────

def update_manifest(entries):
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    gen_sha = sha256_of(Path(__file__).resolve())
    audio = {}
    for key, (path, seconds) in entries.items():
        audio[key] = {
            "path": str(path.relative_to(ROOT)),
            "seconds": round(seconds, 3),
            "bytes": path.stat().st_size,
            "sha256": sha256_of(path),
            "source": SOURCE_NOTE,
            "generator_sha256": gen_sha,
        }
    data["audio"] = audio
    data["audio_budgets"] = {
        "max_audio_bytes": 614400,
        "max_audio_sec": 12,
        "min_audio_sec": 0.5,
    }
    MANIFEST.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                         encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description="程序合成 LinguaVerse 音频")
    ap.add_argument("--out", type=Path, default=None,
                    help="仅写 WAV 到指定目录（用于确定性比对，不改 manifest）")
    args = ap.parse_args()

    street = synth_street()
    cafe = synth_cafe()
    clink = synth_clink()

    if args.out is not None:
        write_wav(args.out / "street_loop.wav", street)
        write_wav(args.out / "cafe_loop.wav", cafe)
        write_wav(args.out / "cup_clink.wav", clink)
        print("[make_ambience] 仅写 WAV → %s（不改 manifest）" % args.out)
        return 0

    p_street = DEFAULT_OUT_AMBIENT / "street_loop.wav"
    p_cafe = DEFAULT_OUT_AMBIENT / "cafe_loop.wav"
    p_clink = DEFAULT_OUT_SFX / "cup_clink.wav"
    write_wav(p_street, street)
    write_wav(p_cafe, cafe)
    write_wav(p_clink, clink)

    for p, sec in ((p_street, len(street) / SR),
                   (p_cafe, len(cafe) / SR),
                   (p_clink, len(clink) / SR)):
        print("[make_ambience] %s  %.2fs  %d bytes" % (p.name, sec, p.stat().st_size))

    update_manifest({
        "street_loop": (p_street, len(street) / SR),
        "cafe_loop": (p_cafe, len(cafe) / SR),
        "cup_clink": (p_clink, len(clink) / SR),
    })
    print("[make_ambience] manifest audio 段已更新: %s" % MANIFEST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
