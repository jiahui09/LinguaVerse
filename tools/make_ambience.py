#!/usr/bin/env python3
"""LinguaVerse 环境音/音效程序合成器 v2（CC0，零下载、纯标准库）。

生成 16-bit **立体声 44100Hz** WAV：
  godot-project/assets/audio/ambient/street_loop.wav   街道环境音（循环）
  godot-project/assets/audio/ambient/cafe_loop.wav     咖啡馆室内音（循环）
  godot-project/assets/audio/sfx/cup_clink.wav         点单杯碟轻碰（0.6s 单次）
  godot-project/assets/audio/sfx/footstep.wav          石板路脚步触地（0.18s 单次）

v2 重做（真机反馈"配音不合适"，用户确认 4 件全部重做、44100Hz 立体声分层）：
  * 44100Hz / 2ch：v1 的 22050Hz 单声道听感发扁发干
  * 分层声景：每件由 5+ 层独立声源叠加（城市轰鸣/风/人潮/鸟/事件），事件有固定
    pan（鸟左、车铃右…），主体 mono→Haas 微延迟（L/R 12ms 错位+电平差）造宽度
  * Schroeder 混响（3 comb + 2 allpass）给房间/户外距离感：cafe 最湿、street 次之、
    clink 短尾、footstep 干（贴地感）
  * 事件密度与时长升级：鸟 4 组多音节、远喇叭、自行车铃；cafe 加咖啡机嘶声与
    椅子拖动；clink 改"杯落碟"双碰结构；footstep 改 heel-toe 双触+砂粒散开
  * 保留 v1 的三大约束：确定性（固定种子、固定顺序，重复运行字节一致）/
    无缝循环（T+X 尾接头交叉折叠 + 全调制取 k/T 整数基频 + 事件不骑缝）/
    一阶滤波全部手写（无 numpy/scipy）

v3 重调（真机复验三症状: 机械/合成感重、响度不合适、杂音/爆音/接缝）：
  * 去机械感：全部调制从"单正弦规律摆动"换成 irregular_lfo（随机整数倍频+随机
    相位叠加——仍严格以 dur 为周期故折叠无缝, 但包络不再可辨识地周期摆动）；
    鸟鸣 4→6 组、pan 随机散布、音节数与远近幅度随机
  * 响度：新增 normalize_rms_lr——先去直流, 再把两件 loop 统一 RMS=0.085
    (-21.4dBFS)（v2 纯峰值归一导致两件差 1.5dB, 进出咖啡馆响度跳变）;
    播放端 sfx 层次: clink -4→0dB、footstep -4→-2dB
  * 去杂音：crowd 带通 hi 0.28→0.15（≈1050Hz 回到设计带宽）、air 0.35→0.18,
    各加二级一阶平滑——v2 的单级 LP 留下 ~8% 白噪尾巴（实测样本间最大跳变
    0.205=中位 11 倍, 听感滋滋）, v3 降至 0.046
  * 判据升级（check_audio）: 两 loop RMS ≤0.5dB、loop 杂音门 maxΔ≤0.06、
    直流收紧 2%→0.5%

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

SR = 44100
SEED = 20260601
XFADE_SEC = 0.5
AMBIENT_SECONDS = 8.0
CLINK_SECONDS = 0.6
FOOTSTEP_SECONDS = 0.18
PEAK_TARGET = 0.5            # 环境音归一化峰值（≈ -6 dBFS）
RMS_AMBIENT_TARGET = 0.085   # v3: 两件 loop 统一 RMS（-21.4dBFS），消除切换响度跳变
PEAK_AMBIENT_MAX = 0.5       # v3 RMS 归一后的峰值封顶
CLINK_PEAK = 0.5012          # -6.0 dBFS
FOOTSTEP_PEAK = 0.5012       # -6.0 dBFS（与 cup_clink 同族响度）
CLINK_PAD_FRAMES = 32        # 首尾置零帧数（立体声按帧对齐）
FOOTSTEP_PAD_FRAMES = 32

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_AMBIENT = ROOT / "godot-project/assets/audio/ambient"
DEFAULT_OUT_SFX = ROOT / "godot-project/assets/audio/sfx"
MANIFEST = ROOT / "godot-project/data/assets_manifest.json"
SOURCE_NOTE = "CC0-1.0 程序合成（本仓库 tools/make_ambience.py，无第三方素材）"

# 立体声设计：Haas 微延迟（毫秒）与右声道电平差（宽度因场景而异）
HAAS_STREET_MS = 12.0
HAAS_CAFE_MS = 8.0
HAAS_LEVEL_R = 0.94


# ────────────────────────── 基础工具 ──────────────────────────

def one_pole_lp(buf, alpha):
    """一阶低通，返回新列表。"""
    out = []
    y = 0.0
    a = alpha
    for x in buf:
        y += a * (x - y)
        out.append(y)
    return out


def bandpass(buf, lo_alpha, hi_alpha):
    """低通相减带通：[lo, hi] 带近似通过。"""
    hi = one_pole_lp(buf, hi_alpha)
    lo = one_pole_lp(hi, lo_alpha)
    return [h - l for h, l in zip(hi, lo)]


def normalize_lr(lr, peak):
    """L/R 联合峰值归一（保持声像比例），返回 [L, R]。"""
    m = max(max(abs(x) for x in lr[0]), max(abs(x) for x in lr[1]))
    if m <= 0.0:
        raise ValueError("合成结果为静音")
    k = peak / m
    return [[x * k for x in lr[0]], [x * k for x in lr[1]]]


def irregular_lfo(n_samples, dur, rng, terms=3, n_range=(1, 13), depth=0.5):
    """周期性不规则调制（v3 去机械感主力）：随机整数倍频 + 随机相位正弦叠加。

    任意整数倍频 k/dur 都严格以 dur 为周期 → 折叠后无缝；随机相位/幅度/频点
    让包络不再像单正弦那样规律摆动（v2 的 sin(2π·k·t/dur) 肉眼可辨的周期感
    是"机械/合成感"的主源之一）。返回中心为 1.0、近似 [1-depth, 1+depth] 的序列。
    """
    comps = []
    a_base = depth / terms
    for _ in range(terms):
        comps.append((rng.randint(n_range[0], n_range[1]),
                      rng.uniform(0.0, 2.0 * math.pi),
                      a_base * rng.uniform(0.5, 1.5)))
    out = [1.0] * n_samples
    for i in range(n_samples):
        t = i / SR
        s = 0.0
        for (k_n, phi, a) in comps:
            s += a * math.sin(2.0 * math.pi * k_n * t / dur + phi)
        out[i] = 1.0 + s
    return out


def normalize_rms_lr(lr, rms_target, peak_max):
    """v3 响度归一：先去直流，再按 L/R 联合 RMS 缩放到目标，最后峰值封顶。

    v2 纯峰值归一导致两件 loop RMS 差 1.5dB（进出咖啡馆响度跳变, 真机反馈
    "音量/响度不合适"的实锤之一）。RMS 目标取 0.085（-21.4dBFS, 与 v2 街道
    听感持平——只把 cafe 拉齐到街道, 保守不整体变响）；峰值仍 ≤0.5 防削波。
    """
    out = []
    for ch in lr:
        m = sum(ch) / len(ch)
        out.append([x - m for x in ch])          # 去直流
    all_s = out[0] + out[1]
    rms = math.sqrt(sum(x * x for x in all_s) / len(all_s))
    if rms <= 0.0:
        raise ValueError("合成结果为静音")
    k = rms_target / rms
    out = [[x * k for x in ch] for ch in out]
    peak = max(max(abs(x) for x in out[0]), max(abs(x) for x in out[1]))
    if peak > peak_max:
        k2 = peak_max / peak
        out = [[x * k2 for x in ch] for ch in out]
    return out


def crossfade_loop_ch(buf, T, Xn):
    """把长度 T+Xn 的缓冲折叠成长度 T 的无缝循环（单声道）。"""
    out = [0.0] * T
    for i in range(Xn):
        w = i / Xn
        out[i] = w * buf[i] + (1.0 - w) * buf[i + T]
    out[Xn:T] = buf[Xn:T]
    return out


def to_stereo(mono, haas_ms, seed):
    """mono → Haas 立体声 + L/R 各自独立的空气感细节（种子确定）。"""
    d = int(haas_ms * 0.001 * SR)
    L = list(mono)
    R = [0.0] * d + list(mono[:len(mono) - d])
    R = [x * HAAS_LEVEL_R for x in R]
    rng = random.Random(seed)
    # L/R 各自的细微高频空气层（微弱，造宽度；两声道种子不同故不相关）
    for ch in (0, 1):
        air = [rng.gauss(0.0, 1.0) for _ in range(len(mono))]
        air = bandpass(air, 0.08, 0.45)
        g = 0.012 if ch == 0 else 0.010
        for i in range(len(mono)):
            L[i] += air[i] * g if ch == 0 else 0.0
            if ch == 1:
                R[i] += air[i] * g
    return [L, R]


def schroeder_reverb(buf, wet, combs, aps):
    """Schroeder 混响：并联 comb + 串联 allpass，返回 wet 比例混入后的缓冲。"""
    n = len(buf)
    acc = [0.0] * n
    for di, (delay, g) in enumerate(combs):
        y = [0.0] * n
        for i in range(n):
            v = buf[i] + (g * y[i - delay] if i >= delay else 0.0)
            y[i] = v
        for i in range(n):
            acc[i] += y[i] * (1.0 / len(combs))
    for delay, g in aps:
        out = [0.0] * n
        for i in range(n):
            xd = acc[i - delay] if i >= delay else 0.0
            yd = out[i - delay] if i >= delay else 0.0
            out[i] = -g * acc[i] + xd + g * yd
        acc = out
    return [(1.0 - wet) * buf[i] + wet * acc[i] for i in range(n)]


def write_wav(path, lr):
    """立体声交织写 16-bit WAV。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    L, R = lr[0], lr[1]
    pcm = array.array('h')
    for i in range(len(L)):
        for x in (L[i], R[i]):
            v = int(round(x * 32767.0))
            if v > 32767:
                v = 32767
            elif v < -32768:
                v = -32768
            pcm.append(v)
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def sha256_of(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ────────────────────────── 事件合成件（短缓冲） ──────────────────────────

def env_chirp(buf, start, dur, f0, f1, amp, pan_gain):
    """线性扫频鸟鸣（多音节由外层多次调用）。pan_gain: 0=L, 1=R。"""
    n = int(dur * SR)
    for k in range(n):
        t = k / SR
        p = k / n
        phase = 2 * math.pi * (f0 * t + (f1 - f0) * t * t / (2 * dur))
        env = math.sin(math.pi * p) ** 2
        v = amp * env * math.sin(phase)
        idx = start + k
        if 0 <= idx < len(buf[0]):
            buf[0][idx] += v * (1.0 - 0.7 * pan_gain)
            buf[1][idx] += v * (0.3 + 0.7 * pan_gain)


def env_ceramic(buf, start, partials, amp, pan_gain, total_n):
    """陶瓷部分音族（杯碰族共用）。"""
    for (f, a, tau) in partials:
        w = 2 * math.pi * f / SR
        ai = a * amp
        n = min(int(tau * 6 * SR), total_n)
        for k in range(n):
            v = ai * math.sin(w * k) * math.exp(-k / (tau * SR))
            idx = start + k
            if 0 <= idx < len(buf[0]):
                buf[0][idx] += v * (1.0 - 0.6 * pan_gain)
                buf[1][idx] += v * (0.4 + 0.6 * pan_gain)


def env_noise_burst(buf, start, dur, amp, lo_alpha, hi_alpha, seed, pan_gain=0.5):
    """带通噪声突发（咖啡机嘶声/砂粒/敲击瞬态共用）。"""
    n = int(dur * SR)
    rng = random.Random(seed)
    raw = [rng.gauss(0.0, 1.0) for _ in range(n)]
    shaped = bandpass(raw, lo_alpha, hi_alpha)
    peak = max(abs(x) for x in shaped) or 1.0
    for k in range(n):
        env = math.sin(math.pi * k / n) ** 1.5
        v = amp * shaped[k] / peak * env
        idx = start + k
        if 0 <= idx < len(buf[0]):
            buf[0][idx] += v * (1.0 - 0.6 * pan_gain)
            buf[1][idx] += v * (0.4 + 0.6 * pan_gain)


# ────────────────────────── 街道环境音（立体声循环） ──────────────────────────

def synth_street():
    dur = AMBIENT_SECONDS
    T = int(dur * SR)
    Xn = int(XFADE_SEC * SR)
    N = T + Xn
    rng = random.Random(SEED)

    # 1) 城市轰鸣底床：布朗噪声 → 双级低通（远车流+建筑共鸣）
    brown = 0.0
    rumble_in = []
    for _ in range(N):
        brown = (brown + rng.gauss(0.0, 1.0) * 0.05) * 0.998
        rumble_in.append(brown)
    rumble = one_pole_lp(one_pole_lp(rumble_in, 0.06), 0.06)

    # 2) 车流呼啸：白噪狠低通（几乎只剩包络起伏）
    whoosh = one_pole_lp([rng.gauss(0.0, 1.0) for _ in range(N)], 0.01)

    # 3) 空气/风层：中频带通慢起伏（街道纵深的"呼吸"）
    # v3 带宽收窄：hi_alpha 0.35→0.18——v2 的 0.35 留下近白噪高频尾巴（诊断:
    # 最大相邻样本差 0.205=中位 11 倍, 集中在 2.2-3.0s）, 即真机反馈的"杂音/滋滋"。
    # 二级平滑：单极 LP 在 Nyquist 仍穿透 ~8%, 再串一阶把尾巴压下去
    air = one_pole_lp(bandpass([rng.gauss(0.0, 1.0) for _ in range(N)], 0.05, 0.18), 0.18)

    # 4) 人潮 murmur：[300,1100]Hz 带通 + 音节感慢调制（远，听不清词——不能像说话）
    # v3: hi_alpha 0.28→0.15（2kHz→≈1050Hz, 回到设计带宽）+ 二级平滑压高频尾巴
    crowd_raw = [rng.gauss(0.0, 1.0) for _ in range(N)]
    crowd = one_pole_lp(bandpass(crowd_raw, 0.05, 0.15), 0.15)

    # 5) 层叠加：v3 调制全部换成 irregular_lfo（随机整数倍频+随机相位, 仍严格以
    # dur 为周期→折叠无缝）。v2 的单正弦规律摆动是"机械/合成感重"的主源之一。
    g_rumble = irregular_lfo(N, dur, rng, terms=3, n_range=(1, 7), depth=0.75)
    g_whoosh = irregular_lfo(N, dur, rng, terms=2, n_range=(1, 4), depth=0.67)
    g_crowd = irregular_lfo(N, dur, rng, terms=4, n_range=(3, 15), depth=0.90)
    g_air = irregular_lfo(N, dur, rng, terms=2, n_range=(1, 5), depth=0.67)
    mono = []
    for i in range(N):
        mono.append(rumble[i] * 0.55 * g_rumble[i]
                    + whoosh[i] * 6.0 * 0.60 * g_whoosh[i]
                    + crowd[i] * 0.55 * 0.50 * g_crowd[i]
                    + air[i] * 0.8 * 0.60 * g_air[i])

    # 事件缓冲（立体声，事件只落 [Xn+0.3, T-0.8)，绝不骑缝）
    ev = [[0.0] * N, [0.0] * N]

    # 6) 鸟鸣 6 组（v3 4→6, pan 随机散布）：每组 2-4 音节, 远近幅度散布
    for g_i in range(6):
        base = int(rng.uniform(Xn + 0.3 * SR, T - 1.4 * SR))
        syllables = rng.randint(2, 4)
        f0 = rng.uniform(2300.0, 2900.0)
        pan = rng.uniform(0.08, 0.92)
        dist = rng.uniform(0.6, 1.0)              # 远近感: 距离衰减
        for s in range(syllables):
            st = base + int(s * rng.uniform(0.16, 0.30) * SR)
            fa = f0 + rng.uniform(-200.0, 200.0)
            fb = fa + rng.uniform(600.0, 1100.0)
            env_chirp(ev, st, 0.12 + 0.04 * s, fa, fb,
                      rng.uniform(0.05, 0.08) * dist, pan)

    # 7) 自行车铃（右 pan，双击 ding-ding）
    ding = [(2450.0, 1.0, 0.09), (3680.0, 0.5, 0.06), (4900.0, 0.25, 0.04)]
    bell_at = int(rng.uniform(Xn + 0.5 * SR, T - 1.2 * SR))
    env_ceramic(ev, bell_at, ding, 0.10, 0.85, N)
    env_ceramic(ev, bell_at + int(0.13 * SR), ding, 0.07, 0.85, N)

    # 8) 远处喇叭：闷 honk（200Hz 基 + 谐波，低通感靠衰减快的低次谐波实现）
    honk_at = int(rng.uniform(Xn + 0.6 * SR, T - 1.5 * SR))
    honk_n = int(0.45 * SR)
    for (f, a, tau) in ((196.0, 0.5, 0.35), (392.0, 0.22, 0.25), (588.0, 0.08, 0.15)):
        w = 2 * math.pi * f / SR
        for k in range(honk_n):
            v = 0.07 * a * math.sin(w * k) * math.exp(-k / (tau * SR))
            idx = honk_at + k
            if idx < N:
                ev[0][idx] += v * 0.95
                ev[1][idx] += v * 0.35

    # 主体+事件 → Haas 立体声 → 少量户外距离混响 → 循环折叠 → 归一
    for i in range(N):
        mono[i] += ev[0][i] + ev[1][i]
    lr = to_stereo(mono, HAAS_STREET_MS, SEED + 40)
    wet_combs = [(2053, 0.72), (2251, 0.70), (2599, 0.68)]
    wet_aps = [(556, 0.6), (331, 0.6)]
    lr = [schroeder_reverb(ch, 0.16, wet_combs, wet_aps) for ch in lr]
    looped = [crossfade_loop_ch(lr[0], T, Xn), crossfade_loop_ch(lr[1], T, Xn)]
    return normalize_rms_lr(looped, RMS_AMBIENT_TARGET, PEAK_AMBIENT_MAX)


# ────────────────────────── 咖啡馆室内音（立体声循环） ──────────────────────────

def synth_cafe():
    dur = AMBIENT_SECONDS
    T = int(dur * SR)
    Xn = int(XFADE_SEC * SR)
    N = T + Xn
    rng = random.Random(SEED + 1)

    # 1) HVAC/房间底噪：白噪 4 级低通（带外残余 ≈1e-7，无嘶声）
    room = [rng.gauss(0.0, 1.0) for _ in range(N)]
    for _ in range(4):
        room = one_pole_lp(room, 0.06)
    room = [x * 8.0 for x in room]

    # 2) 深闷人声 murmur：[60,250]Hz 陡裙带通（"隔着墙的交谈"，绝不能像说话）
    murmur_raw = [rng.gauss(0.0, 1.0) for _ in range(N)]
    hi = murmur_raw
    for _ in range(4):
        hi = one_pole_lp(hi, 0.14)
    lo = hi
    for _ in range(4):
        lo = one_pole_lp(lo, 0.05)
    murmur = [h - l for h, l in zip(hi, lo)]

    # 3) 暖 hum（92/138Hz 非工频）——合成主体
    w1 = 2 * math.pi * 92.0 / SR
    w2 = 2 * math.pi * 138.0 / SR
    # v3: 调制同样换成 irregular_lfo（与街道同一去机械感手法, 周期仍=dur 无缝）
    g_murmur = irregular_lfo(N, dur, rng, terms=3, n_range=(3, 11), depth=0.95)
    g_room = irregular_lfo(N, dur, rng, terms=2, n_range=(1, 4), depth=0.25)
    mono = []
    for i in range(N):
        hum = 0.02 * math.cos(w1 * i) + 0.015 * math.cos(w2 * i + 0.7)
        mono.append(room[i] * 0.8 * g_room[i] + hum
                    + murmur[i] * 1.8 * 0.5 * g_murmur[i])

    ev = [[0.0] * N, [0.0] * N]

    # 4) 杯碟轻碰 ×4（陶瓷族，pan 分布在两侧）
    clink_partials = [(2100.0, 1.0, 0.10), (2350.0, 0.6, 0.07), (2100.0 * 2.1, 0.35, 0.05)]
    for j in range(4):
        st = int(rng.uniform(Xn + 0.3 * SR, T - 0.9 * SR))
        pan = rng.choice([0.2, 0.8])
        # 补第二个分量族（2350 基的另一组）
        fam = clink_partials if j % 2 == 0 else [
            (2350.0, 1.0, 0.09), (3525.0, 0.5, 0.06), (4935.0, 0.3, 0.04)]
        env_ceramic(ev, st, fam, rng.uniform(0.05, 0.08), pan, N)

    # 5) 咖啡机蒸汽嘶声 ×1（中高频带通短包络，pan 靠右——吧台在右）
    steam_at = int(rng.uniform(Xn + 1.2 * SR, T - 1.6 * SR))
    env_noise_burst(ev, steam_at, 1.1, 0.10, 0.10, 0.5, SEED + 60, 0.75)

    # 6) 椅子拖动 ×1（低频摩擦 + 木共振短音）
    chair_at = int(rng.uniform(Xn + 0.8 * SR, T - 1.2 * SR))
    chair_n = int(0.35 * SR)
    rng_c = random.Random(SEED + 61)
    fric = [rng_c.gauss(0.0, 1.0) for _ in range(chair_n)]
    fric = one_pole_lp(fric, 0.12)
    fp = max(abs(x) for x in fric) or 1.0
    w_wood = 2 * math.pi * 172.0 / SR
    for k in range(chair_n):
        env = math.sin(math.pi * k / chair_n) ** 1.2
        v = env * (0.06 * fric[k] / fp + 0.03 * math.sin(w_wood * k) * math.exp(-k / (0.12 * SR)))
        idx = chair_at + k
        ev[0][idx] += v * 0.4
        ev[1][idx] += v * 0.9

    for i in range(N):
        mono[i] += ev[0][i] + ev[1][i]
    lr = to_stereo(mono, HAAS_CAFE_MS, SEED + 41)
    wet_combs = [(1443, 0.76), (1687, 0.74), (1999, 0.72)]   # 小房间更紧的早期反射
    wet_aps = [(441, 0.6), (269, 0.6)]
    lr = [schroeder_reverb(ch, 0.26, wet_combs, wet_aps) for ch in lr]
    looped = [crossfade_loop_ch(lr[0], T, Xn), crossfade_loop_ch(lr[1], T, Xn)]
    return normalize_rms_lr(looped, RMS_AMBIENT_TARGET, PEAK_AMBIENT_MAX)


# ────────────────────────── 杯碟轻碰音效（立体声单次） ──────────────────────────

def synth_clink():
    n = int(CLINK_SECONDS * SR)
    rng = random.Random(SEED + 2)
    ev = [[0.0] * n, [0.0] * n]

    # 陶瓷分量族：非整数倍频率 + 各自指数衰减
    partials = [(2100.0, 1.00, 0.14),
                (3150.0, 0.62, 0.10),
                (4370.0, 0.42, 0.07),
                (5820.0, 0.26, 0.05)]

    # 1) 主碰（杯落碟）：陶瓷族 + 敲击瞬态
    env_ceramic(ev, 0, partials, 1.0, 0.45, n)
    env_noise_burst(ev, 0, 0.006, 0.55, 0.2, 0.7, SEED + 30, 0.45)

    # 2) 副碰（碟被带起又落，36ms 后，更轻、微右移）
    secondary = [(f * 0.97, a * 0.45, tau * 0.8) for (f, a, tau) in partials]
    env_ceramic(ev, int(0.036 * SR), secondary, 1.0, 0.62, n)
    env_noise_burst(ev, int(0.036 * SR), 0.005, 0.22, 0.2, 0.7, SEED + 31, 0.62)

    # 3) 桌面木共振（180Hz 短衰减——把"碰"落在桌上而非空中）
    w_t = 2 * math.pi * 180.0 / SR
    for k in range(int(0.16 * SR)):
        v = 0.16 * math.sin(w_t * k) * math.exp(-k / (0.05 * SR))
        ev[0][k] += v * 0.9
        ev[1][k] += v * 0.75

    # 4) 房间短尾巴：clink 干脆为主，尾巴很轻
    wet_combs = [(1327, 0.70), (1583, 0.68), (1867, 0.66)]
    wet_aps = [(389, 0.55), (233, 0.55)]
    lr = [schroeder_reverb(ch, 0.14, wet_combs, wet_aps) for ch in ev]

    # 首尾按帧置零（去 click，立体声对齐）→ 归一 -6 dBFS（置零处保持 0）
    for k in range(CLINK_PAD_FRAMES):
        for ch in (0, 1):
            lr[ch][k] = 0.0
            lr[ch][-1 - k] = 0.0
    return normalize_lr(lr, CLINK_PEAK)


# ────────────────────────── 石板路脚步音效（立体声单次） ──────────────────────────

def synth_footstep():
    """0.18s 单次脚步（v2 heel-toe 双触）：跟触→前掌轻触→砂粒散开→62Hz 体感低频。

    石板路面质感：闷 thud 两级低通 + 4-8k 砂粒突发（鞋底碾过石缝），
    heel-toe 间隔 58ms，单次时长仍 0.18s（播放端头摆同步约束 0.12-0.30s 不变）。
    """
    n = int(FOOTSTEP_SECONDS * SR)
    rng = random.Random(SEED + 3)
    out = [0.0] * n

    # heel 触地：闷 thud（两级低通白噪）
    thud_src = [rng.gauss(0.0, 1.0) for _ in range(n)]
    thud = one_pole_lp(one_pole_lp(thud_src, 0.08), 0.08)
    # toe 触地（58ms 后，更轻更短）
    toe_off = int(0.058 * SR)
    # 砂粒层：4-8k 带通（石缝砂石散开，快衰）
    grit_raw = [rng.gauss(0.0, 1.0) for _ in range(n)]
    grit = bandpass(grit_raw, 0.4, 0.75)

    for k in range(n):
        t = k / SR
        # heel：3ms 起音（无 click）+ 55ms 指数衰减
        a_h = min(1.0, t / 0.003)
        out[k] += thud[k] * 5.2 * a_h * math.exp(-t / 0.052)
        # toe：58ms 处的前掌轻触
        tt = t - 0.058
        if tt >= 0.0:
            a_t = min(1.0, tt / 0.003)
            out[k] += thud[k] * 2.4 * a_t * math.exp(-tt / 0.030)
        # 砂粒散开：跟触即发，25ms 快衰
        out[k] += grit[k] * 0.55 * a_h * math.exp(-t / 0.025)
        # toe 后补一点短砂
        if tt >= 0.0:
            out[k] += grit[k] * 0.25 * math.exp(-tt / 0.018)

    # 跟步低频 62Hz（快衰，踏实感，非工频）
    w = 2 * math.pi * 62.0 / SR
    for k in range(n):
        out[k] += 0.35 * math.sin(w * k) * math.exp(-(k / SR) / 0.03)

    # 去直流 → 左右微分（脚步近在跟前，宽度极小）→ 按帧置零 → 归一
    mean = sum(out) / n
    out = [x - mean for x in out]
    rng_p = random.Random(SEED + 33)
    pan_jitter = rng_p.uniform(-0.04, 0.04)
    L = [x * (0.96 - pan_jitter) for x in out]
    R = [x * (0.96 + pan_jitter) for x in out]
    for k in range(FOOTSTEP_PAD_FRAMES):
        L[k] = 0.0
        L[-1 - k] = 0.0
        R[k] = 0.0
        R[-1 - k] = 0.0
    return normalize_lr([L, R], FOOTSTEP_PEAK)


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
    # 立体声 44100Hz：8s 环境音 ≈1.41MB，预算留 ~9% 余量
    data["audio_budgets"] = {
        "max_audio_bytes": 1536000,
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
    footstep = synth_footstep()

    if args.out is not None:
        args.out.mkdir(parents=True, exist_ok=True)
        write_wav(args.out / "street_loop.wav", street)
        write_wav(args.out / "cafe_loop.wav", cafe)
        write_wav(args.out / "cup_clink.wav", clink)
        write_wav(args.out / "footstep.wav", footstep)
        print("[make_ambience] 仅写 WAV → %s（不改 manifest）" % args.out)
        return 0

    p_street = DEFAULT_OUT_AMBIENT / "street_loop.wav"
    p_cafe = DEFAULT_OUT_AMBIENT / "cafe_loop.wav"
    p_clink = DEFAULT_OUT_SFX / "cup_clink.wav"
    p_footstep = DEFAULT_OUT_SFX / "footstep.wav"
    write_wav(p_street, street)
    write_wav(p_cafe, cafe)
    write_wav(p_clink, clink)
    write_wav(p_footstep, footstep)

    for p, lr in ((p_street, street), (p_cafe, cafe),
                  (p_clink, clink), (p_footstep, footstep)):
        print("[make_ambience] %s  %.2fs  %d bytes" % (
            p.name, len(lr[0]) / SR, p.stat().st_size))

    update_manifest({
        "street_loop": (p_street, len(street[0]) / SR),
        "cafe_loop": (p_cafe, len(cafe[0]) / SR),
        "cup_clink": (p_clink, len(clink[0]) / SR),
        "footstep": (p_footstep, len(footstep[0]) / SR),
    })
    print("[make_ambience] manifest audio 段已更新: %s" % MANIFEST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
