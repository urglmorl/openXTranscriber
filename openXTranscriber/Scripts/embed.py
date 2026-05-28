#!/usr/bin/env python3
"""Извлекает усреднённые эмбеддинги голоса (по одному на спикера).

Принимает на вход WAV-файл (16 kHz, mono) и JSON со списком интервалов
диаризации. Для каждого SPEAKER_XX берёт самые длинные сегменты в пределах
бюджета (по умолчанию 30 секунд), считает эмбеддинг моделью
pyannote/wespeaker-voxceleb-resnet34-LM, нормализует и усредняет.

Выходной JSON:
    {"embeddings": [{"speaker_id", "embedding": [...], "samples", "total_seconds",
                     "sample_start", "sample_end"}]}
"""
import argparse
import json
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="WAV 16k mono path")
    parser.add_argument("--intervals", required=True, help="Path to intervals JSON or '-' for stdin")
    parser.add_argument("--max-seconds-per-speaker", type=float, default=30.0)
    parser.add_argument("--min-segment-seconds", type=float, default=0.6)
    parser.add_argument(
        "--model",
        default="pyannote/wespeaker-voxceleb-resnet34-LM",
        help="Hugging Face repo id for the speaker embedding model",
    )
    args = parser.parse_args()

    token = os.getenv("HUGGINGFACE_TOKEN", "").strip()
    if not token:
        print("HUGGINGFACE_TOKEN is missing.", file=sys.stderr)
        return 1

    try:
        if args.intervals == "-":
            raw = sys.stdin.read()
        else:
            with open(args.intervals, "r", encoding="utf-8") as fh:
                raw = fh.read()
        parsed = json.loads(raw)
        if isinstance(parsed, dict) and "intervals" in parsed:
            intervals = parsed["intervals"]
        elif isinstance(parsed, list):
            intervals = parsed
        else:
            raise ValueError("Intervals JSON must be a list or {intervals: [...]}.")
    except Exception as exc:
        print(f"Failed to read intervals: {exc}", file=sys.stderr)
        return 1

    try:
        import numpy as np  # type: ignore
        import torch  # type: ignore
        from pyannote.audio import Inference, Model  # type: ignore
        from pyannote.core import Segment  # type: ignore
    except Exception as exc:  # pragma: no cover
        print(f"Failed to import dependencies: {exc}", file=sys.stderr)
        return 1

    print(f"Loading embedding model {args.model}...")
    try:
        try:
            model = Model.from_pretrained(args.model, token=token)
        except TypeError:
            model = Model.from_pretrained(args.model, use_auth_token=token)
    except Exception as exc:  # pragma: no cover
        print(f"Failed to load embedding model: {exc}", file=sys.stderr)
        return 1

    prefer_mps = os.getenv("TRANSCRIBER_EMBED_USE_MPS", "").strip().lower() in {"1", "true", "yes"}
    using_mps = False
    try:
        if prefer_mps and torch.backends.mps.is_available():
            model.to(torch.device("mps"))
            using_mps = True
            print("Embedding device: MPS")
        else:
            model.to(torch.device("cpu"))
            print("Embedding device: CPU")
    except Exception as exc:  # pragma: no cover
        print(f"Failed to move model to device: {exc}", file=sys.stderr)

    inference = Inference(model, window="whole")

    by_speaker: dict[str, list[tuple[float, float]]] = {}
    for item in intervals:
        if not isinstance(item, dict):
            continue
        sid = str(item.get("speaker_id", "SPEAKER_00"))
        try:
            s = float(item.get("start", 0.0))
            e = float(item.get("end", 0.0))
        except Exception:
            continue
        if e - s < args.min_segment_seconds:
            continue
        by_speaker.setdefault(sid, []).append((s, e))

    if not by_speaker:
        print(json.dumps({"embeddings": []}, ensure_ascii=False))
        return 0

    print(f"Computing embeddings for {len(by_speaker)} speakers...")
    embeddings_out: list[dict] = []

    for sid, segs in by_speaker.items():
        # Самые длинные сегменты: они стабильнее и содержат меньше пауз.
        segs.sort(key=lambda x: x[1] - x[0], reverse=True)
        budget = args.max_seconds_per_speaker
        chosen: list[tuple[float, float]] = []
        for s, e in segs:
            if budget <= 0:
                break
            duration = e - s
            if duration <= budget:
                chosen.append((s, e))
                budget -= duration
            else:
                chosen.append((s, s + budget))
                budget = 0.0

        embs: list = []
        for s, e in chosen:
            try:
                emb = inference.crop(args.input, Segment(s, e))
            except Exception as exc:  # pragma: no cover
                error_text = str(exc)
                if using_mps and ("MPS" in error_text or "metal" in error_text.lower()):
                    try:
                        model.to(torch.device("cpu"))
                        using_mps = False
                        emb = inference.crop(args.input, Segment(s, e))
                    except Exception as cpu_exc:
                        print(f"Embedding failed for {sid} [{s:.2f}-{e:.2f}]: {cpu_exc}", file=sys.stderr)
                        continue
                else:
                    print(f"Embedding failed for {sid} [{s:.2f}-{e:.2f}]: {exc}", file=sys.stderr)
                    continue
            arr = np.asarray(emb, dtype=np.float64).reshape(-1)
            norm = float(np.linalg.norm(arr))
            if norm <= 0:
                continue
            embs.append(arr / norm)

        if not embs:
            continue

        centroid = np.mean(np.stack(embs, axis=0), axis=0)
        norm = float(np.linalg.norm(centroid))
        if norm > 0:
            centroid = centroid / norm

        # Самый длинный сегмент используется как образец для прослушивания.
        sample = max(chosen, key=lambda x: x[1] - x[0])
        embeddings_out.append({
            "speaker_id": sid,
            "embedding": [float(x) for x in centroid.tolist()],
            "samples": len(embs),
            "total_seconds": float(sum(e - s for s, e in chosen)),
            "sample_start": float(sample[0]),
            "sample_end": float(sample[1]),
        })

    print(json.dumps({"embeddings": embeddings_out}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
