#!/usr/bin/env python3
"""
Convert a 14-channel HeSuVi HRIR .wav (e.g. Apple_Pro2_Stereo.wav)
into src/ir_data.h matching PC HeSuVi (#2.0.0.1) stereo math exactly.

HeSuVi 14-channel order (per hesuvi.txt):
  Ch 0:  L0  (FL -> Left ear)
  Ch 1:  R1  (FL -> Right ear)
  Ch 2:  SL0 (SL -> Left ear)
  Ch 3:  SR1 (SL -> Right ear)
  Ch 4:  RL0 (RL -> Left ear)
  Ch 5:  RR1 (RL -> Right ear)
  Ch 6:  C0  (C  -> Left ear)
  Ch 7:  R0  (FR -> Right ear)
  Ch 8:  L1  (FR -> Left ear)
  Ch 9:  SR0 (SR -> Right ear)
  Ch 10: SL1 (SR -> Left ear)
  Ch 11: RR0 (RR -> Right ear)
  Ch 12: RL1 (RR -> Left ear)
  Ch 13: C1  (C  -> Right ear)

HeSuVi Stereo Upmix Matrix (matrix.txt):
  LVI  =  0.50*L
  RVI  =  0.50*R
  RLVI =  0.30*L - 0.20*R
  RRVI = -0.20*L + 0.30*R
  CVI  =  0.20*L + 0.20*R
  SLVI =  0.45*L - 0.25*R
  SRVI = -0.25*L + 0.45*R
"""

import argparse
import os
import sys
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly


def load_wav_float32(path: str):
    sr, data = wavfile.read(path)
    if data.dtype == np.int16:
        data = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        data = data.astype(np.float32) / 2147483648.0
    elif data.dtype == np.uint8:
        data = (data.astype(np.float32) - 128.0) / 128.0
    else:
        data = data.astype(np.float32)
    if data.ndim == 1:
        data = data[:, np.newaxis]
    return sr, data


def collapse_hesuvi_14ch(h: np.ndarray):
    """
    Collapse 14-channel HeSuVi HRIR [N, 14] into:
      - Matrix mode (exact PC HeSuVi matrix.txt + hesuvi.txt 14-ch conv + mix.txt)
      - Front mode  (exact PC HeSuVi with Matrix Upmix OFF: pure FL/FR)
    Returns dicts with keys ('LL', 'LR', 'RL', 'RR') where:
      OutL = L * LL + R * RL
      OutR = L * LR + R * RR
    """
    if h.shape[1] != 14:
        raise ValueError(f"Expected 14-channel HeSuVi WAV, got {h.shape[1]} channels")

    # Matrix mode (linearly identical to 14-channel HeSuVi stereo upmix)
    mat_ll = (
        0.50 * h[:, 0]
        + 0.45 * h[:, 2]
        - 0.25 * h[:, 10]
        + 0.30 * h[:, 4]
        - 0.20 * h[:, 12]
        + 0.20 * h[:, 6]
    )
    mat_rl = (
        0.50 * h[:, 8]
        - 0.25 * h[:, 2]
        + 0.45 * h[:, 10]
        - 0.20 * h[:, 4]
        + 0.30 * h[:, 12]
        + 0.20 * h[:, 6]
    )
    mat_lr = (
        0.50 * h[:, 1]
        + 0.45 * h[:, 3]
        - 0.25 * h[:, 9]
        + 0.30 * h[:, 5]
        - 0.20 * h[:, 11]
        + 0.20 * h[:, 13]
    )
    mat_rr = (
        0.50 * h[:, 7]
        - 0.25 * h[:, 3]
        + 0.45 * h[:, 9]
        - 0.20 * h[:, 5]
        + 0.30 * h[:, 11]
        + 0.20 * h[:, 13]
    )

    # Front mode (pure 1:1 FL/FR binaural)
    front_ll = h[:, 0].copy()
    front_lr = h[:, 1].copy()
    front_rl = h[:, 8].copy()
    front_rr = h[:, 7].copy()

    return (
        {"LL": mat_ll, "LR": mat_lr, "RL": mat_rl, "RR": mat_rr},
        {"LL": front_ll, "LR": front_lr, "RL": front_rl, "RR": front_rr},
    )


def resample_ir(ir_dict, src_sr: int, dst_sr: int, target_len: int):
    out = {}
    for k, v in ir_dict.items():
        if src_sr == dst_sr:
            r = v.astype(np.float64)
        else:
            # 48000 -> 44100 is 147 / 160; scale by (src_sr / dst_sr) to preserve impulse gain
            g = np.gcd(src_sr, dst_sr)
            up = dst_sr // g
            down = src_sr // g
            r = resample_poly(v.astype(np.float64), up, down) * (float(src_sr) / float(dst_sr))
        if len(r) < target_len:
            r = np.pad(r, (0, target_len - len(r)))
        elif len(r) > target_len:
            r = r[:target_len]
        out[k] = r.astype(np.float32)
    return out


def format_c_array(name: str, arr: np.ndarray, cols: int = 8) -> str:
    lines = [f"static const float {name}[SPATIAL_IR_LEN] = {{"]
    vals = [f"{float(x):.8e}f" for x in arr]
    for i in range(0, len(vals), cols):
        lines.append("    " + ", ".join(vals[i : i + cols]) + ",")
    lines.append("};")
    return "\n".join(lines)


def verify_matrix_equivalence(h: np.ndarray, mat_ir: dict):
    """Numerically verify that 4-ch True-Stereo collapse == full 14-ch HeSuVi PC graph."""
    rng = np.random.default_rng(42)
    L = rng.standard_normal(2048).astype(np.float64)
    R = rng.standard_normal(2048).astype(np.float64)

    # Full 14-channel PC HeSuVi graph
    LVI = 0.50 * L
    RVI = 0.50 * R
    RLVI = 0.30 * L - 0.20 * R
    RRVI = -0.20 * L + 0.30 * R
    CVI = 0.20 * L + 0.20 * R
    SLVI = 0.45 * L - 0.25 * R
    SRVI = -0.25 * L + 0.45 * R

    ch_in = [LVI, LVI, SLVI, SLVI, RLVI, RLVI, CVI, RVI, RVI, SRVI, SRVI, RRVI, RRVI, CVI]
    conv14 = [np.convolve(ch_in[i], h[:, i].astype(np.float64)) for i in range(14)]
    pc_out_l = conv14[0] + conv14[8] + conv14[2] + conv14[10] + conv14[4] + conv14[12] + conv14[6]
    pc_out_r = conv14[7] + conv14[1] + conv14[9] + conv14[3] + conv14[11] + conv14[5] + conv14[13]

    # Collapsed 4-channel True-Stereo
    ts_out_l = np.convolve(L, mat_ir["LL"].astype(np.float64)) + np.convolve(R, mat_ir["RL"].astype(np.float64))
    ts_out_r = np.convolve(L, mat_ir["LR"].astype(np.float64)) + np.convolve(R, mat_ir["RR"].astype(np.float64))

    max_err_l = float(np.max(np.abs(pc_out_l - ts_out_l)))
    max_err_r = float(np.max(np.abs(pc_out_r - ts_out_r)))
    print(f"[Verify] 14-ch HeSuVi vs 4-ch True-Stereo max error: L={max_err_l:.3e}, R={max_err_r:.3e}")
    assert max_err_l < 1e-5 and max_err_r < 1e-5, "Matrix collapse mismatch!"


def main():
    parser = argparse.ArgumentParser(description="Convert 14-ch HeSuVi WAV to C header ir_data.h")
    parser.add_argument("input_wav", help="Path to 14-channel HeSuVi WAV (e.g. Apple_Pro2_Stereo.wav)")
    parser.add_argument("output_h", help="Path to output header file (e.g. src/ir_data.h)")
    parser.add_argument("--ir-len", type=int, default=8400, help="IR length in samples (default: 8400, fits FFT_N=16384 with zero truncation)")
    args = parser.parse_args()

    sr, data = load_wav_float32(args.input_wav)
    print(f"Loaded {args.input_wav}: sr={sr} Hz, frames={data.shape[0]}, channels={data.shape[1]}")

    mat_raw, front_raw = collapse_hesuvi_14ch(data)
    verify_matrix_equivalence(data, mat_raw)

    ir_len = args.ir_len
    mat_48 = resample_ir(mat_raw, sr, 48000, ir_len)
    mat_44 = resample_ir(mat_raw, sr, 44100, ir_len)
    front_48 = resample_ir(front_raw, sr, 48000, ir_len)
    front_44 = resample_ir(front_raw, sr, 44100, ir_len)

    # Report frequency-domain peak gain to inform headroom choice
    for label, ir in [("Matrix 48k", mat_48), ("Matrix 44.1k", mat_44), ("Front 48k", front_48), ("Front 44.1k", front_44)]:
        H_ll = np.fft.rfft(ir["LL"], n=16384)
        H_rl = np.fft.rfft(ir["RL"], n=16384)
        # Correlated mono input worst-case magnitude |H_ll + H_rl|
        peak_db = 20.0 * np.log10(np.max(np.abs(H_ll + H_rl)) + 1e-12)
        rms_db = 20.0 * np.log10(np.sqrt(np.mean(np.abs(H_ll) ** 2 + np.abs(H_rl) ** 2)) + 1e-12)
        print(f"  {label:12s}: worst-case mono peak={peak_db:+.2f} dB, broadband RMS={rms_db:+.2f} dB")

    os.makedirs(os.path.dirname(os.path.abspath(args.output_h)), exist_ok=True)
    with open(args.output_h, "w", encoding="utf-8") as f:
        f.write("// Auto-generated by tools/wav_to_ir.py\n")
        f.write(f"// Source: {os.path.basename(args.input_wav)} ({sr} Hz, {data.shape[0]} frames, {data.shape[1]} ch)\n")
        f.write("// Exact PC HeSuVi (#2.0.0.1) 14-channel Stereo Matrix & Front True-Stereo IRs\n")
        f.write("#ifndef SPATIAL_IR_DATA_H\n#define SPATIAL_IR_DATA_H\n\n")
        f.write(f"#define SPATIAL_IR_LEN {ir_len}\n")
        f.write("#define SPATIAL_FFT_LOG2 14\n")
        f.write("#define SPATIAL_FFT_N 16384\n\n")

        f.write("// Mode 1: PC HeSuVi Stereo Matrix Upmix (matrix.txt + 14-ch conv + mix.txt)\n")
        for k in ("LL", "LR", "RL", "RR"):
            f.write(format_c_array(f"kIR48_Matrix_{k}", mat_48[k]) + "\n\n")
        for k in ("LL", "LR", "RL", "RR"):
            f.write(format_c_array(f"kIR44_Matrix_{k}", mat_44[k]) + "\n\n")

        f.write("// Mode 2: PC HeSuVi Pure Front Left/Right (FL/FR 1:1 True-Stereo)\n")
        for k in ("LL", "LR", "RL", "RR"):
            f.write(format_c_array(f"kIR48_Front_{k}", front_48[k]) + "\n\n")
        for k in ("LL", "LR", "RL", "RR"):
            f.write(format_c_array(f"kIR44_Front_{k}", front_44[k]) + "\n\n")

        f.write("#endif // SPATIAL_IR_DATA_H\n")

    print(f"Wrote {args.output_h} ({os.path.getsize(args.output_h) / 1024:.1f} KB)")


if __name__ == "__main__":
    main()
