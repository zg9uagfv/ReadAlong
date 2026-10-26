"""One-process, incremental WhisperMLX transcription for ReadAlong."""

import argparse
import json
import os
from pathlib import Path

from whispermlx.alignment import align, load_align_model
from whispermlx.asr import load_model
from whispermlx.audio import SAMPLE_RATE, load_audio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("output_dir")
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-dir", default=None)
    parser.add_argument("--chunk-seconds", type=float, default=60.0)
    parser.add_argument("--chunk-count", type=int, required=True)
    args = parser.parse_args()

    audio = load_audio(args.audio)
    samples_per_chunk = int(args.chunk_seconds * SAMPLE_RATE)
    if samples_per_chunk <= 0 or args.chunk_count <= 0:
        raise ValueError("Chunk duration and count must be positive")

    # Keep both pipelines alive across chunks. mlx_whisper caches the MLX
    # weights in this process, while the VAD and alignment models load once.
    asr = load_model(
        args.model,
        device="mps",
        language="en",
        vad_method="pyannote",
        download_root=args.model_dir,
    )
    align_model, align_metadata = load_align_model(
        "en", "mps", model_dir=args.model_dir
    )

    for index in range(args.chunk_count):
        chunk = audio[index * samples_per_chunk : (index + 1) * samples_per_chunk]
        segments = []
        if len(chunk):
            result = asr.transcribe(
                chunk, batch_size=8, chunk_size=30, print_progress=False, verbose=False
            )
            segments = result["segments"]
        if segments:
            segments = align(
                segments, align_model, align_metadata, chunk, "mps",
                interpolate_method="nearest", print_progress=False,
            )["segments"]

        payload = {
            "text": " ".join(segment["text"].strip() for segment in segments),
            "segments": segments,
        }
        destination = Path(args.output_dir) / f"chunk_{index:04d}.json"
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, destination)


if __name__ == "__main__":
    main()
