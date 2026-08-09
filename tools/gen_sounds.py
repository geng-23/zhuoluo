"""生成着落 App 音效资源（标准库，无第三方依赖）。

v2（UX 改进计划第三批）：圆润、动听、多样。

改进点（相对 v1）：
- 每个音符带 attack/release 包络（余弦渐入渐出，消除 v1 音符结尾不归零的"咔哒"声）
- 基频 + 2/3 次谐波（15%/8%）+ 极轻噪声瞬态（"气声"），去电子味
- 8 类声音差异化设计
- 响度 RMS 归一化（替代手写 amp 的不一致）

输出：
  - assets/sounds/add.wav                     添加任务
  - assets/sounds/complete.wav                完成任务
  - assets/sounds/reopen.wav                  恢复/撤销
  - assets/sounds/delete.wav                  删除任务
  - assets/sounds/click.wav                   多选/开关（极轻）
  - assets/sounds/drop.wav                    拖放成功（改期/象限）
  - assets/sounds/skip.wav                    跳过本次
"""
import math
import os
import random
import wave

SR = 44100


def write_wav(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        data = bytearray()
        for s in samples:
            v = max(-1.0, min(1.0, s))
            data += int(v * 32767).to_bytes(2, "little", signed=True)
        w.writeframes(bytes(data))


def env_ar(n, attack, release):
    """attack/release 包络：前 attack 个采样余弦渐入，末 release 个采样余弦渐出归零。"""
    e = [1.0] * n
    for i in range(min(attack, n)):
        e[i] = 0.5 - 0.5 * math.cos(math.pi * i / attack)
    for i in range(max(0, n - release), n):
        k = i - (n - release)
        e[i] = 0.5 + 0.5 * math.cos(math.pi * k / release)
    return e


def tone(freq, dur, amp=0.5, attack=0.006, release=0.012, noise=0.012):
    """圆润单音：基频 + 2/3 次谐波 + 极轻噪声瞬态，AR 包络（无咔哒）。"""
    n = int(SR * dur)
    out = []
    env = env_ar(n, int(SR * attack), int(SR * release))
    rng = random.Random(int(freq))
    for i in range(n):
        t = i / SR
        s = math.sin(2 * math.pi * freq * t)
        s += 0.15 * math.sin(2 * math.pi * freq * 2 * t)
        s += 0.08 * math.sin(2 * math.pi * freq * 3 * t)
        # 极轻噪声瞬态：仅开头 8ms，"气声"提升真实感
        if i < int(SR * 0.008):
            s += noise * (rng.random() * 2 - 1) * (1 - i / (SR * 0.008))
        out.append(amp * env[i] * s)
    return out


def note(freqs, total, gap=0.02, amp=0.35):
    """一串音符，每音符后接小停顿（带 AR 包络，拼接处归零无咔哒）。"""
    out = []
    per = total / len(freqs)
    for f in freqs:
        d = max(0.05, per - gap)
        out += tone(f, d, amp=amp)
        out += [0.0] * int(SR * gap)
    return out


def sweep(f0, f1, dur, amp=0.35, attack=0.008, release=0.02):
    """频率滑音（AR 包络，归零无咔哒）。"""
    n = int(SR * dur)
    out = []
    env = env_ar(n, int(SR * attack), int(SR * release))
    for i in range(n):
        t = i / SR
        f = f0 + (f1 - f0) * (t / dur)
        phase = 2 * math.pi * (f0 * t + 0.5 * (f1 - f0) * t * t / dur)
        s = math.sin(phase) + 0.12 * math.sin(2 * phase)
        out.append(amp * env[i] * s)
    return out


def rms_norm(samples, target=0.28):
    """RMS 响度归一化：不同 amp 的素材最终听感一致。"""
    if not samples:
        return samples
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    if rms < 1e-6:
        return samples
    gain = target / rms
    return [max(-1.0, min(1.0, s * gain)) for s in samples]


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(base, ".."))
    sounds_dir = os.path.join(root, "assets", "sounds")

    # 添加任务：短促上行双音（C5→G5，120ms 级）
    write_wav(
        os.path.join(sounds_dir, "add.wav"),
        rms_norm(note([523.25, 783.99], 0.24, 0.02, amp=0.32)),
    )

    # 完成：三音上行琶音 + 余音（C5-E5-G5）
    write_wav(
        os.path.join(sounds_dir, "complete.wav"),
        rms_norm(note([523.25, 659.25, 783.99], 0.32, 0.018, amp=0.34)),
    )

    # 恢复：下行的柔和回声（G5→E5，轻）
    write_wav(
        os.path.join(sounds_dir, "reopen.wav"),
        rms_norm(note([783.99, 659.25], 0.2, 0.02, amp=0.28)),
    )

    # 删除：低频短下扫（G4→C4，柔和克制，不尖锐）
    write_wav(
        os.path.join(sounds_dir, "delete.wav"),
        rms_norm(sweep(392.0, 261.63, 0.18, amp=0.3)),
    )

    # 点击/开关：短高频轻音（1200Hz，90ms，AR 包络更可闻）
    write_wav(
        os.path.join(sounds_dir, "click.wav"),
        rms_norm(tone(1200.0, 0.09, amp=0.28, attack=0.004, release=0.03), target=0.2),
    )

    # 拖放成功：柔和"叮"（A5 + 高八度 echo）
    write_wav(
        os.path.join(sounds_dir, "drop.wav"),
        rms_norm(
            tone(880.0, 0.1, amp=0.3, release=0.02)
            + [0.0] * int(SR * 0.015)
            + tone(1320.0, 0.16, amp=0.24, release=0.03)
        ),
    )

    # 跳过本次：轻上滑（A4→E5）
    write_wav(
        os.path.join(sounds_dir, "skip.wav"),
        rms_norm(sweep(440.0, 659.25, 0.14, amp=0.28, release=0.015)),
    )

    for name in [
        "add",
        "complete",
        "reopen",
        "delete",
        "click",
        "drop",
        "skip",
    ]:
        p = os.path.join(sounds_dir, name + ".wav")
        if os.path.exists(p):
            print(f"{os.path.getsize(p):6d} B  {os.path.relpath(p, root)}")


if __name__ == "__main__":
    main()
