#!/usr/bin/env python3
import argparse
import json
import os
import sys
import warnings

warnings.filterwarnings(
    "ignore",
    message=r"std\(\): degrees of freedom is <= 0",
    category=UserWarning,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    args = parser.parse_args()

    token = os.getenv("HUGGINGFACE_TOKEN", "").strip()
    if not token:
        print("HUGGINGFACE_TOKEN is missing.", file=sys.stderr)
        return 1

    try:
        import torch  # type: ignore
        from pyannote.audio import Pipeline  # type: ignore
    except Exception as exc:  # pragma: no cover
        print(f"Failed to import pyannote dependencies: {exc}", file=sys.stderr)
        return 1

    print("Loading diarization model...")
    prefer_mps = os.getenv("TRANSCRIBER_DIARIZATION_USE_MPS", "").strip().lower() in {"1", "true", "yes"}
    using_mps = False
    try:
        try:
            pipeline = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                token=token,
            )
        except TypeError:
            pipeline = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                use_auth_token=token,
            )
        if prefer_mps and torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            using_mps = True
            print("Diarization device: MPS")
        else:
            pipeline.to(torch.device("cpu"))
            print("Diarization device: CPU")
    except Exception as exc:  # pragma: no cover
        print(f"Failed to initialize pipeline: {exc}", file=sys.stderr)
        return 1

    print("Running speaker diarization...")
    try:
        diarize_output = pipeline(args.input)
        annotation = getattr(diarize_output, "speaker_diarization", diarize_output)
    except Exception as exc:  # pragma: no cover
        error_text = str(exc)
        if using_mps and (
            "validateComputeFunctionArguments" in error_text
            or "MPS" in error_text
            or "metal" in error_text.lower()
        ):
            try:
                print("MPS diarization failed, retrying on CPU...")
                pipeline.to(torch.device("cpu"))
                diarize_output = pipeline(args.input)
                annotation = getattr(diarize_output, "speaker_diarization", diarize_output)
            except Exception as cpu_exc:
                print(f"Diarization failed after CPU fallback: {cpu_exc}", file=sys.stderr)
                return 1
        else:
            print(f"Diarization failed: {exc}", file=sys.stderr)
            return 1

    intervals = []
    for segment, _, speaker in annotation.itertracks(yield_label=True):
        intervals.append(
            {
                "start": float(segment.start),
                "end": float(segment.end),
                "speaker_id": str(speaker),
            }
        )

    print(json.dumps({"intervals": intervals}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
