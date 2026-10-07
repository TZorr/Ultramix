#!/usr/bin/env python3
#
# Tools/convert-demucs.py
# Ultramix
#
# Turns the htdemucs weights (Demucs v4, Meta, MIT) into the Core ML model
# Ultramix separates stems with, checks it against PyTorch, and writes the
# reference values the Swift side is verified against.
#
# Only the network goes into Core ML. Everything around it stays outside, so
# that the app runs it with Swift and vDSP alone:
#
#   - the short-time Fourier transforms (`_spec` and `_ispec`), which Core ML
#     has no faithful equivalent of;
#   - the mean/std normalisation of both inputs and its undoing on the
#     outputs: in half precision a sum over 2.75 million spectrum values
#     overflows, and outside the graph it is two numbers per segment;
#   - the chunking, overlap and weighting of `apply_model`.
#
# The model takes one 7.8 s segment (343 980 frames at 44.1 kHz) and gives
# back only drums, bass and vocals; Ultramix makes "other" as the mix minus
# those three, so its own estimate of it is not needed.
#
#   inputs   mix   [1, 2, 343980]        (mix - meant) / (1e-5 + stdt)
#            spec  [1, 4, 2048, 336]     (cac - mean) / (1e-5 + std)
#   outputs  time  [1, 3, 2, 343980]     times stdt plus meant
#            freq  [1, 12, 2048, 336]    times std plus mean, then _ispec
#
# `cac` is the spectrum with real and imaginary parts as channels, in the
# order L.re, L.im, R.re, R.im; `freq` holds the same four per stem, stems
# in the order drums, bass, vocals. A stem is time + _ispec(freq).
#
# Setup, once (the Python that comes with Xcode is enough):
#   /usr/bin/python3 -m venv ~/.venvs/demucs
#   ~/.venvs/demucs/bin/pip install torch==2.5.1 torchaudio==2.5.1 \
#       coremltools==8.3.0 "numpy<2" demucs==4.0.1
#
# Usage, from the project folder:
#   ~/.venvs/demucs/bin/python Tools/convert-demucs.py
#       [--precision mixed|fp16|fp32]   default mixed (see convert)
#       [--song <Cache/<id>.f32>]       also compare on a real song
#       [--seconds N]                   how much of it, default 60
#       [--bench]                       time a segment per compute unit
#
# Run the model on the CPU and GPU only (`.cpuAndGPU`): the Neural Engine
# computes everything in half precision whatever the model says, and the
# group norms overflow there.
#
# The first run downloads the weights (about 80 MB) into torch's hub cache.
# Writes Ultramix/Resources/Demucs_htdemucs.mlpackage and
# Tools/demucs-reference.json.
#

import argparse
import json
import math
import os
import sys
import time

import numpy as np
import torch

SR = 44100
L = 343980                       # int(39/5 * 44100), htdemucs's segment
STORED = ["drums", "bass", "vocals"]
OVERLAP = 0.25
ACCEPT_SNR = 35.0                # dB, Core ML against PyTorch, per stem...
ACCEPT_BELOW_MIX = 65.0          # ...or an error this far below the mix, for
                                 # a stem that is all but silent in the take

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "Ultramix", "Resources", "Demucs_htdemucs.mlpackage")
REFERENCE = os.path.join(ROOT, "Tools", "demucs-reference.json")


# MARK: - The model

def load_htdemucs():
    from demucs.pretrained import get_model
    bag = get_model("htdemucs")
    assert len(bag.models) == 1, "htdemucs is expected to be a single model"
    assert all(w == 1.0 for w in bag.weights[0])
    model = bag.models[0].eval()
    assert int(model.segment * model.samplerate) == L and model.samplerate == SR
    assert model.cac and model.nfft == 4096 and model.hop_length == 1024
    return model


class HTDemucsCore(torch.nn.Module):
    """HTDemucs.forward between the normalisation and its undoing."""

    def __init__(self, model):
        super().__init__()
        self.m = model
        self.pick = [model.sources.index(s) for s in STORED]

    def forward(self, mix, spec):
        m = self.m
        x, xt = spec, mix
        B, C, Fq, T = x.shape

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                # Broadcast rather than expand_as: tracing folds the
                # expanded tensor into a 33 MB constant.
                emb = m.freq_emb(frs).t()[None, :, :, None]
                x = x + m.freq_emb_scale * emb
            saved.append(x)

        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)

        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    xt, _ = tdec(xt, saved_t.pop(-1), length_t)
        assert not saved and not saved_t and not lengths_t

        S = len(m.sources)
        x = x.reshape(B, S, C, Fq, T)
        xt = xt.reshape(B, S, 2, L)
        time_out = torch.cat([xt[:, i:i + 1] for i in self.pick], dim=1)
        freq_out = torch.cat([x[:, i:i + 1] for i in self.pick], dim=1)
        return time_out, freq_out.reshape(B, len(self.pick) * C, Fq, T)


# MARK: - What Swift will do around the network

def spec(model, segment):
    """[2, L] float32 -> complex [2, 2048, 336], Demucs's own _spec."""
    with torch.no_grad():
        return model._spec(torch.from_numpy(segment)[None])[0].numpy()


def cac(z):
    """complex [2, F, T] -> [4, F, T] as L.re, L.im, R.re, R.im."""
    return np.stack([z[0].real, z[0].imag, z[1].real, z[1].imag]).astype(np.float32)


def ispec(model, freq):
    """[4, F, T] cac of one stem -> [2, L], Demucs's own _ispec."""
    z = (freq[0::2] + 1j * freq[1::2]).astype(np.complex64)
    with torch.no_grad():
        return model._ispec(torch.from_numpy(z)[None], L)[0].numpy()


def normalise(a):
    """Mean and std (unbiased) over all of `a`, as HTDemucs.forward has them."""
    a64 = a.astype(np.float64)
    mean = a64.mean()
    std = a64.std(ddof=1)
    return ((a64 - mean) / (1e-5 + std)).astype(np.float32), mean, std


def separate_segment(model, run_core, segment):
    """One [2, L] segment -> [3, 2, L] stems, the pipeline Swift reproduces."""
    z = spec(model, segment)
    spec_n, mean, std = normalise(cac(z))
    mix_n, meant, stdt = normalise(segment)
    t, f = run_core(mix_n[None], spec_n[None])
    t = t[0].astype(np.float64) * stdt + meant
    f = (f[0].astype(np.float64) * std + mean).astype(np.float32)
    out = np.empty((len(STORED), 2, L), dtype=np.float64)
    for s in range(len(STORED)):
        out[s] = t[s] + ispec(model, f[4 * s:4 * s + 4])
    return out


def chunk_weight():
    w = np.concatenate([np.arange(1, L // 2 + 1), np.arange(L - L // 2, 0, -1)]).astype(np.float64)
    return w / w.max()


def separate(model, run_core, wav, progress=None):
    """[2, N] -> [3, 2, N], apply_model(shifts=0, split=True, overlap=0.25)
    with separate.py's normalisation around it."""
    ref = wav.astype(np.float64).mean(0)
    gmean, gstd = ref.mean(), ref.std(ddof=1)
    w = ((wav.astype(np.float64) - gmean) / gstd).astype(np.float32)
    n = w.shape[1]
    stride = int((1 - OVERLAP) * L)
    weight = chunk_weight()
    out = np.zeros((len(STORED), 2, n))
    total = np.zeros(n)
    offsets = list(range(0, n, stride))
    for k, offset in enumerate(offsets):
        length = min(n - offset, L)
        delta = L - length
        start = offset - delta // 2
        segment = np.zeros((2, L), dtype=np.float32)
        lo, hi = max(0, start), min(n, start + L)
        segment[:, lo - start:hi - start] = w[:, lo:hi]
        y = separate_segment(model, run_core, segment)[..., delta // 2:delta // 2 + length]
        out[..., offset:offset + length] += weight[:length] * y
        total[offset:offset + length] += weight[:length]
        if progress:
            progress(k + 1, len(offsets))
    assert total.min() > 0
    return out / total * gstd + gmean


def torch_reference(bag_model, wav):
    """The same through Demucs's own apply_model, as the truth."""
    from demucs.apply import apply_model, BagOfModels
    ref = torch.from_numpy(wav).mean(0)
    gmean, gstd = ref.mean(), ref.std()
    x = (torch.from_numpy(wav) - gmean) / gstd
    with torch.no_grad():
        y = apply_model(BagOfModels([bag_model]), x[None], shifts=0, split=True, overlap=OVERLAP)[0]
    y = y * gstd + gmean
    pick = [bag_model.sources.index(s) for s in STORED]
    return y[pick].double().numpy()


# MARK: - The test signal Swift regenerates

def test_signal(seconds):
    """Kick, snare noise, bass and a vibrato voice from closed formulas in
    Double, so Swift can build the same samples. Interleaving aside, the
    Swift side must compute exactly this:

      t  = n / 44100, tb = t mod 0.5, ts = (t - 0.5) mod 1  (floor modulo)
      noise[n]: s = 0x12345678; per sample s = 1664525 s + 1013904223 (mod 2^32),
                value = (s >> 8) / 8388608 - 1
      kick  = 0.8 exp(-30 tb) sin(2 pi (55 tb + 2.5 (1 - exp(-40 tb))))
      snare = 0.3 exp(-25 ts) noise
      bass  = 0.35 (0.6 + 0.4 exp(-8 tb)) sin(2 pi 55 t)
      voice = 0.12 (0.5 - 0.5 cos(2 pi t / 4)) sum_{h=1..6} sin(2 pi 220 h t + h 0.2 sin(2 pi 5 t)) / h
      left  = 0.5 (kick + 0.9 snare + bass + 0.8 voice)
      right = 0.5 (kick + 1.1 snare + bass + 1.2 voice), each cast to Float
    """
    n = int(round(seconds * SR))
    t = np.arange(n, dtype=np.float64) / SR
    tb = np.mod(t, 0.5)
    ts = np.mod(t - 0.5, 1.0)
    noise = np.empty(n)
    s = 0x12345678
    for i in range(n):
        s = (1664525 * s + 1013904223) & 0xFFFFFFFF
        noise[i] = (s >> 8) / 8388608.0 - 1.0
    kick = 0.8 * np.exp(-30 * tb) * np.sin(2 * np.pi * (55 * tb + 2.5 * (1 - np.exp(-40 * tb))))
    snare = 0.3 * np.exp(-25 * ts) * noise
    bass = 0.35 * (0.6 + 0.4 * np.exp(-8 * tb)) * np.sin(2 * np.pi * 55 * t)
    vib = 0.2 * np.sin(2 * np.pi * 5 * t)
    voice = sum(np.sin(2 * np.pi * 220 * h * t + h * vib) / h for h in range(1, 7))
    voice = 0.12 * (0.5 - 0.5 * np.cos(2 * np.pi * t / 4)) * voice
    left = 0.5 * (kick + 0.9 * snare + bass + 0.8 * voice)
    right = 0.5 * (kick + 1.1 * snare + bass + 1.2 * voice)
    return np.stack([left, right]).astype(np.float32)


# MARK: - Conversion

def convert(core, precision):
    import coremltools as ct
    mix = torch.zeros(1, 2, L)
    spc = torch.zeros(1, 4, 2048, 336)
    torch.backends.mha.set_fastpath_enabled(False)
    with torch.no_grad():
        traced = torch.jit.trace(core, (mix, spc), check_trace=False)
    if precision == "fp32":
        cp = ct.precision.FLOAT32
    elif precision == "fp16":
        cp = ct.precision.FLOAT16
    else:
        # Half precision only where the weights and the work are. The group
        # norms come apart into separate ops on the way, and squaring their
        # inputs (up to about 3000 in the transformer) overflows fp16, which
        # tops out at 65504; everything outside these four stays fp32.
        half = {"conv", "conv_transpose", "linear", "matmul"}
        cp = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type in half)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=mix.shape, dtype=np.float32),
                ct.TensorType(name="spec", shape=spc.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="time", dtype=np.float32),
                 ct.TensorType(name="freq", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=cp,
    )
    mlmodel.author = "Demucs v4 htdemucs by Alexandre Défossez et al. (Meta); conversion for Ultramix"
    mlmodel.license = "MIT"
    mlmodel.short_description = ("htdemucs network without STFT and normalisation: "
                                 "drums, bass, vocals of one 7.8 s segment at 44.1 kHz")
    mlmodel.version = "htdemucs/" + precision
    return mlmodel


def coreml_runner(mlmodel):
    def run(mix_n, spec_n):
        out = mlmodel.predict({"mix": mix_n, "spec": spec_n})
        return out["time"], out["freq"]
    return run


def torch_runner(core):
    def run(mix_n, spec_n):
        with torch.no_grad():
            t, f = core(torch.from_numpy(mix_n), torch.from_numpy(spec_n))
        return t.numpy(), f.numpy()
    return run


# MARK: - Checks

def snr(ref, est):
    ref = np.asarray(ref, dtype=np.float64)
    err = np.asarray(est, dtype=np.float64) - ref
    return 10 * math.log10(max(np.sum(ref ** 2), 1e-30) / max(np.sum(err ** 2), 1e-30))


def snrs(ref, est):
    return [snr(ref[s], est[s]) for s in range(len(STORED))]


def judge(title, ref, est, mix):
    """Per stem: SNR against the PyTorch stem, and the error below the mix.
    A stem passes on either; a near-silent stem's SNR says nothing."""
    mix_energy = np.sum(np.asarray(mix, dtype=np.float64) ** 2)
    stem_snr = snrs(ref, est)
    below = [10 * math.log10(mix_energy / max(np.sum((np.asarray(est[s], dtype=np.float64) - ref[s]) ** 2), 1e-30))
             for s in range(len(STORED))]
    print(f"  {title}: " + ", ".join(f"{n} {a:5.1f} dB ({b:5.1f} below mix)"
                                     for n, a, b in zip(STORED, stem_snr, below)))
    ok = all(np.isfinite(a) and (a >= ACCEPT_SNR or b >= ACCEPT_BELOW_MIX) for a, b in zip(stem_snr, below))
    return {"snr": stem_snr, "error_below_mix": below, "passed": bool(ok)}


def report(title, values):
    print(f"  {title}: " + ", ".join(f"{n} {v:6.1f} dB" for n, v in zip(STORED, values)))


def windowed_rms(stems, window=SR // 4):
    n = stems.shape[-1] // window
    return [[float(np.sqrt(np.mean(stems[s][:, k * window:(k + 1) * window].astype(np.float64) ** 2)))
             for k in range(n)] for s in range(len(STORED))]


def reference_values(model, core):
    """Numbers the Swift harness checks its STFT, model and pipeline against."""
    sig12 = test_signal(12)
    seg = sig12[:, :L].copy()
    z = spec(model, seg)
    f_probe = [0, 3, 47, 200, 1023, 2047]
    t_probe = [0, 1, 100, 335]
    stft = {
        "energy": float(np.sum(np.abs(z.astype(np.complex128)) ** 2)),
        "probes": [[c, f, t, float(z[c, f, t].real), float(z[c, f, t].imag)]
                   for c in range(2) for f in f_probe for t in t_probe],
    }
    # A spectrum that is no STFT of anything, as the network's outputs are.
    ff = np.arange(2048)[:, None]
    tt = np.arange(336)[None, :]
    mask = (0.5 + 0.5 * np.cos(0.01 * ff + 0.1 * tt)).astype(np.float32)
    masked = cac(z) * mask[None]
    y = ispec(model, masked)
    s_probe = [0, 1, 1000, 171990, L - 1]
    istft = {
        "mask": "0.5 + 0.5 cos(0.01 f + 0.1 t), applied to all four cac channels",
        "energy": float(np.sum(y.astype(np.float64) ** 2)),
        "probes": [[c, i, float(y[c, i])] for c in range(2) for i in s_probe],
    }
    # The network on the first segment of the 12 s signal as the pipeline
    # feeds it: globally normalised, then normalised again per segment.
    ref = sig12.astype(np.float64).mean(0)
    gseg = ((seg.astype(np.float64) - ref.mean()) / ref.std(ddof=1)).astype(np.float32)
    spec_n, mean, std = normalise(cac(spec(model, gseg)))
    mix_n, meant, stdt = normalise(gseg)
    t_out, f_out = torch_runner(core)(mix_n[None], spec_n[None])
    network = {
        "segment_norm": {"mean": float(mean), "std": float(std), "meant": float(meant), "stdt": float(stdt)},
        "time_rms": [float(np.sqrt(np.mean(t_out[0, s].astype(np.float64) ** 2))) for s in range(3)],
        "freq_rms": [float(np.sqrt(np.mean(f_out[0, 4 * s:4 * s + 4].astype(np.float64) ** 2))) for s in range(3)],
        "time_probes": [[s, c, i, float(t_out[0, s, c, i])] for s in range(3) for c in range(2) for i in s_probe],
    }
    sig20 = test_signal(20)
    full = torch_reference(model, sig20)
    pipeline = {"seconds": 20, "window": SR // 4, "rms": windowed_rms(full)}
    signal = {
        "seconds": [12, 20],
        "first": [[float(sig12[c, i]) for i in (0, 1, 2, 22050, 44100)] for c in range(2)],
        "sum_squares_12s": [float(np.sum(sig12[c].astype(np.float64) ** 2)) for c in range(2)],
    }
    return {"source": "demucs 4.0.1 htdemucs, torch 2.5.1, fp32 CPU", "stems": STORED,
            "signal": signal, "stft": stft, "istft": istft, "network": network, "pipeline": pipeline}, sig20, full


def read_f32(path, seconds):
    raw = np.fromfile(path, dtype=np.float32, count=int(seconds * SR) * 2)
    return np.ascontiguousarray(raw.reshape(-1, 2).T)


def bench(mlmodel_path):
    import coremltools as ct
    mix = np.random.default_rng(1).standard_normal((1, 2, L)).astype(np.float32)
    spc = np.random.default_rng(2).standard_normal((1, 4, 2048, 336)).astype(np.float32)
    for name in ("CPU_AND_GPU", "CPU_ONLY"):
        t0 = time.time()
        m = ct.models.MLModel(mlmodel_path, compute_units=getattr(ct.ComputeUnit, name))
        load = time.time() - t0
        m.predict({"mix": mix, "spec": spc})
        t0 = time.time()
        for _ in range(3):
            m.predict({"mix": mix, "spec": spc})
        per = (time.time() - t0) / 3
        print(f"  {name:12s} load {load:5.1f} s, {per:5.2f} s per segment "
              f"(~{per * SR * 300 / (0.75 * L):5.1f} s for a 5-minute song)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--precision", choices=["mixed", "fp16", "fp32"], default="mixed")
    ap.add_argument("--song", help="raw interleaved stereo Float32 at 44.1 kHz (an Ultramix Cache/<id>.f32)")
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--bench", action="store_true")
    args = ap.parse_args()
    torch.set_num_threads(max(1, os.cpu_count() - 2))

    print("Loading htdemucs")
    model = load_htdemucs()
    params = sum(p.numel() for p in model.parameters())
    print(f"  {params:,} parameters: {params * 2 / 1e6:.0f} MB at fp16, {params * 4 / 1e6:.0f} MB at fp32")
    core = HTDemucsCore(model).eval()

    print("PyTorch: cut model against HTDemucs.forward, one segment")
    seg = test_signal(12)[:, :L].copy()
    with torch.no_grad():
        whole = model(torch.from_numpy(seg)[None])[0].double().numpy()[core.pick]
    cut = separate_segment(model, torch_runner(core), seg)
    report("cut vs forward", snrs(whole, cut))
    assert min(snrs(whole, cut)) > 60, "the cut model does not reproduce HTDemucs.forward"

    print("Reference values")
    reference, sig20, full = reference_values(model, core)
    ours = separate(model, torch_runner(core), sig20)
    report("our chunking vs apply_model", snrs(full, ours))
    assert min(snrs(full, ours)) > 60, "the chunking does not reproduce apply_model"

    print(f"Converting ({args.precision})")
    t0 = time.time()
    mlmodel = convert(core, args.precision)
    print(f"  {time.time() - t0:.0f} s")
    tmp = os.path.join(ROOT, "build", "demucs", os.path.basename(PACKAGE))
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    if os.path.exists(tmp):
        import shutil
        shutil.rmtree(tmp)
    mlmodel.save(tmp)

    print("Core ML vs PyTorch")
    import coremltools as ct
    run = coreml_runner(ct.models.MLModel(tmp, compute_units=ct.ComputeUnit.CPU_AND_GPU))
    results = {"precision": args.precision,
               "segment": judge("one segment     ", whole, separate_segment(model, run, seg), seg),
               "test_signal": judge("20 s test signal", full, separate(model, run, sig20), sig20)}
    if args.song:
        wav = read_f32(args.song, args.seconds)
        print(f"  song: {wav.shape[1] / SR:.0f} s of {os.path.basename(args.song)}, PyTorch first")
        t0 = time.time()
        ref = torch_reference(model, wav)
        print(f"  PyTorch {time.time() - t0:.0f} s")
        t0 = time.time()
        est = separate(model, run, wav)
        print(f"  Core ML pipeline {time.time() - t0:.0f} s")
        results["song"] = judge("song            ", ref, est, wav)
    reference["conversion"] = results

    with open(REFERENCE, "w") as f:
        json.dump(reference, f, indent=1)
        f.write("\n")
    print(f"Wrote {os.path.relpath(REFERENCE, ROOT)}")

    if not all(r["passed"] for r in results.values() if isinstance(r, dict)):
        print(f"REJECTED: a stem is below {ACCEPT_SNR} dB SNR and not {ACCEPT_BELOW_MIX} dB below the mix;"
              f" try --precision fp32."
              f" The package is left at {os.path.relpath(tmp, ROOT)}")
        sys.exit(1)
    import shutil
    if os.path.exists(PACKAGE):
        shutil.rmtree(PACKAGE)
    shutil.move(tmp, PACKAGE)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(PACKAGE) for f in fs)
    print(f"Accepted. Wrote {os.path.relpath(PACKAGE, ROOT)} ({size / 1e6:.0f} MB)")

    if args.bench:
        print("Benchmark")
        bench(PACKAGE)


if __name__ == "__main__":
    main()
