#!/usr/bin/env python3
import argparse
import gzip
import json
import math
import re
import sys
from collections import Counter


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--language", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--prompt", default="")
    args = parser.parse_args()

    initial_prompt = args.prompt.strip() or None
    if initial_prompt:
        preview = initial_prompt[:120] + ("…" if len(initial_prompt) > 120 else "")
        print(f"Using initial prompt: {preview}")

    try:
        from mlx_whisper import transcribe  # type: ignore
    except Exception as exc:  # pragma: no cover
        print(f"Failed to import mlx_whisper: {exc}", file=sys.stderr)
        return 1

    print("Running whisper transcription...")
    try:
        result = transcribe(
            args.input,
            path_or_hf_repo=args.model,
            language=args.language,
            initial_prompt=initial_prompt,
            word_timestamps=True,
            hallucination_silence_threshold=2.0,
            compression_ratio_threshold=2.2,
        )
    except Exception as exc:  # pragma: no cover
        print(f"Transcription failed: {exc}", file=sys.stderr)
        return 1

    raw_segments = [s for s in result.get("segments", []) if isinstance(s, dict)]
    bad_indices = [i for i, s in enumerate(raw_segments) if is_bad_segment(s)]

    if bad_indices:
        print(
            f"Detected {len(bad_indices)} suspicious segment(s) out of {len(raw_segments)}; "
            f"re-running those clips with condition_on_previous_text=False..."
        )
        raw_segments = retry_bad_segments(
            segments=raw_segments,
            bad_indices=bad_indices,
            audio_path=args.input,
            model=args.model,
            language=args.language,
            initial_prompt=initial_prompt,
            transcribe_fn=transcribe,
        )

    payload = {
        "segments": [normalize_segment(item) for item in raw_segments],
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def is_bad_segment(segment: dict) -> bool:
    text = str(segment.get("text", "")).strip()
    if not text:
        return False
    if compression_ratio(text) > 2.4:
        return True
    if has_repetition(text):
        return True
    return False


def compression_ratio(text: str) -> float:
    raw = text.encode("utf-8")
    if not raw:
        return 0.0
    compressed = gzip.compress(raw)
    return len(raw) / max(len(compressed), 1)


def has_repetition(text: str) -> bool:
    words = re.findall(r"\w+", text.lower(), flags=re.UNICODE)
    if len(words) < 4:
        return False

    run = 1
    for i in range(1, len(words)):
        if words[i] == words[i - 1]:
            run += 1
            if run >= 4:
                return True
        else:
            run = 1

    for n in range(3, 8):
        if len(words) < n * 3:
            continue
        grams = [tuple(words[i:i + n]) for i in range(len(words) - n + 1)]
        most = Counter(grams).most_common(1)
        if most and most[0][1] >= 3:
            return True

    return False


def retry_bad_segments(segments, bad_indices, audio_path, model, language, initial_prompt, transcribe_fn):
    groups = []
    current = []
    for idx in bad_indices:
        if not current or idx == current[-1] + 1:
            current.append(idx)
        else:
            groups.append(current)
            current = [idx]
    if current:
        groups.append(current)

    new_segments = list(segments)
    retry_supported = True

    for group in reversed(groups):
        if not retry_supported:
            break

        first_idx, last_idx = group[0], group[-1]
        try:
            start = float(segments[first_idx].get("start", 0.0))
            end = float(segments[last_idx].get("end", 0.0))
        except Exception:
            continue
        if not (math.isfinite(start) and math.isfinite(end)) or end <= start:
            continue

        pad = 0.5
        clip_start = max(0.0, start - pad)
        clip_end = end + pad

        try:
            replacement_result = transcribe_fn(
                audio_path,
                path_or_hf_repo=model,
                language=language,
                initial_prompt=initial_prompt,
                word_timestamps=True,
                condition_on_previous_text=False,
                clip_timestamps=[clip_start, clip_end],
                hallucination_silence_threshold=2.0,
                compression_ratio_threshold=2.2,
            )
        except TypeError as exc:
            print(f"Retry not supported by mlx_whisper ({exc}); keeping original output.")
            retry_supported = False
            break
        except Exception as exc:
            print(f"Retry failed for [{start:.1f}-{end:.1f}]: {exc}; keeping original.")
            continue

        replacement = [s for s in replacement_result.get("segments", []) if isinstance(s, dict)]
        if not replacement:
            print(f"Retry for [{start:.1f}-{end:.1f}] returned nothing; keeping original.")
            continue
        if any(is_bad_segment(s) for s in replacement):
            print(f"Retry for [{start:.1f}-{end:.1f}] still flagged; keeping original.")
            continue

        new_segments[first_idx:last_idx + 1] = replacement
        print(f"Replaced suspicious segment(s) at [{start:.1f}-{end:.1f}].")

    return new_segments


def normalize_segment(item: dict) -> dict:
    text = str(item.get("text", ""))
    segment = {
        "start": safe_float(item.get("start", 0.0)),
        "end": safe_float(item.get("end", 0.0)),
        "text": text,
    }

    words = item.get("words")
    if isinstance(words, list):
        normalized_words = []
        for word_item in words:
            if not isinstance(word_item, dict):
                continue
            normalized_words.append({
                "start": safe_float(word_item.get("start", 0.0)),
                "end": safe_float(word_item.get("end", 0.0)),
                "word": str(word_item.get("word", "")),
            })
        segment["words"] = normalized_words

    return segment


def safe_float(value, default=0.0):
    try:
        numeric = float(value)
    except Exception:
        return default
    if not math.isfinite(numeric):
        return default
    return numeric


if __name__ == "__main__":
    raise SystemExit(main())
