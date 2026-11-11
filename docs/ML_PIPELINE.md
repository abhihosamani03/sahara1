# Machine Learning Pipeline & Edge Optimization

## 1. Model Selection Matrix

**On tooling choice:** the problem statement names "TensorFlow Lite for Microcontrollers, PyTorch Mobile or
similar" as recommended frameworks. This repo uses ONNX Runtime Mobile / sherpa-onnx instead — justified under
the "or similar" clause because it is open-source, fully offline-capable, and has first-class Android bindings
with built-in INT8 quantization support (see §3 below). If a judge asks why not the literally-named tools:
TFLite Micro targets microcontroller-class hardware (far below an Android phone's capability and awkward for
Kotlin/JNI integration), and PyTorch Mobile has weaker out-of-the-box support for the specific VITS/Conformer
architectures AI4Bharat publishes. State this reasoning explicitly in your submission rather than leaving the
substitution unexplained.

| Component | Model Family | Notes |
|---|---|---|
| VAD | Silero VAD | Tiny, well-tested, ONNX export available |
| STT | AI4Bharat IndicConformer or IndicWhisper (tiny/base) | IndicConformer generally faster for real-time; IndicWhisper generally more robust to noise. Benchmark both on your actual target languages before committing — do not assume the published numbers transfer to your specific test set |
| TTS | AI4Bharat Indic-TTS (VITS architecture) | Single-pass generation, mobile-friendly |
| Vocoder | HiFi-GAN (bundled in VITS ONNX export) | — |
| Translation (optional, differentiator) | AI4Bharat IndicTrans2 | Only needed if you build the cross-language relay feature |
| Distress classifier (optional, differentiator) | Small fine-tuned keyword/intent classifier on STT output text | Train on a labeled set of distress phrases per language — this is NOT off-the-shelf, budget real time for it |

## 2. Why Not Raw AI4Bharat Server Models
AI4Bharat's published PyTorch checkpoints target server-class GPUs. Deploying them as-is will exceed RAM/CPU budgets on a low-end phone and violate the footprint metric. Every model must go through the compression pipeline below before it touches a device.

## 3. Compression Pipeline

1. **Export to ONNX** from the PyTorch checkpoint.
2. **Dynamic INT8 quantization** — reduces size ~65-75%, roughly halves inference latency, with typically small WER degradation (verify per-language; degradation is NOT uniform across scripts and can be worse for languages with smaller training data, e.g. Odia).
3. **Validate WER delta** pre/post quantization on a held-out test set before shipping — do not assume quantization is "free."

```python
# scripts/quantize_models.py
import os
from onnxruntime.quantization import quantize_dynamic, QuantType

def compress_model(input_model_path: str, output_model_path: str):
    quantize_dynamic(
        model_input=input_model_path,
        model_output=output_model_path,
        weight_type=QuantType.QInt8,
        optimize_model=True,
    )
    orig = os.path.getsize(input_model_path) / (1024 * 1024)
    quant = os.path.getsize(output_model_path) / (1024 * 1024)
    print(f"{input_model_path}: {orig:.1f}MB -> {quant:.1f}MB "
          f"(1 - quant/orig)*100:.1f}% reduction")

if __name__ == "__main__":
    compress_model("models/vits-kannada.onnx", "models/vits-kannada.int8.onnx")
```

## 4. Deployment Asset Layout

```
assets/models/
├── vad/
│   └── silero_vad.onnx
├── stt/
│   ├── hi/  (tokens.txt, encoder.int8.onnx, decoder.int8.onnx)
│   ├── kn/  (tokens.txt, encoder.int8.onnx, decoder.int8.onnx)
│   └── ...  (remaining languages)
└── tts/
    ├── hi/  (tokens.txt, vits-hi.int8.onnx)
    ├── kn/  (tokens.txt, vits-kn.int8.onnx)
    └── ...  (remaining languages)
```

## 5. Memory Footprint Rules
- Never hold more than one language's STT+TTS weights resident (see ARCHITECTURE.md §2.2).
- Use `mmap` for tensor loading so the OS pages memory dynamically instead of a full heap allocation.
- Lock microphone capture at 16 kHz mono — upsampling or stereo capture wastes bandwidth and RAM for zero accuracy benefit.

## 6. Tokenizer / Script Correctness (the part most teams get wrong)
Each Indic script (Devanagari, Kannada, Malayalam, Odia, Bengali, Tamil, Telugu scripts) has its own phoneme mapping and tokenizer vocabulary. Do not assume a tokenizer trained for one script works for another, and do not let a generic/English-default tokenizer silently attach to a non-English model — this produces confident-looking garbled output rather than an obvious crash, which is worse for a live demo. Explicitly verify tokens.txt matches the model for every language before integration testing, not after.

## 7. Benchmark Harness
`scripts/benchmark_latency.py` should report, per language, on real target-class hardware (not just your dev laptop or a flagship test phone):
- STT RTF
- TTS RTF
- WER against a held-out labeled test set
- Peak RAM during inference
- Cold-load time when switching languages

Publish these numbers in your documentation — accuracy evaluation (the 40% quality weight) will want to see methodology, not just a claimed percentage.
