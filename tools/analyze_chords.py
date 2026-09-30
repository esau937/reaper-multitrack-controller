#!/usr/bin/env python3
"""Create a persistent chord map from the piano+bass render made by REAPER."""

import json
import os
import sys
import tempfile

import librosa
import numpy as np


PITCHES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def templates():
    result = []
    for root in range(12):
        for suffix, degrees in (("", (0, 4, 7)), ("m", (0, 3, 7))):
            vector = np.zeros(12, dtype=float)
            vector[list((root + degree) % 12 for degree in degrees)] = 1.0
            vector /= np.linalg.norm(vector)
            result.append((PITCHES[root] + suffix, root, vector))
    return result


TEMPLATES = templates()


def label_for(chroma, bass_chroma):
    energy = float(np.sum(chroma))
    if energy < 0.015:
        return "N"
    normalized = chroma / (np.linalg.norm(chroma) or 1.0)
    scores = []
    for name, root, template in TEMPLATES:
        # Piano defines the chord quality; the bass gives the root a gentle,
        # musically useful preference without forcing inversions into errors.
        score = float(np.dot(normalized, template)) + 0.16 * float(bass_chroma[root])
        scores.append((score, name))
    score, name = max(scores)
    return name if score >= 0.48 else "N"


def merge(events):
    merged = []
    for event in events:
        if event["end"] - event["start"] < 0.12:
            continue
        if merged and merged[-1]["chord"] == event["chord"]:
            merged[-1]["end"] = event["end"]
        else:
            merged.append(event)
    # Remove very brief changes surrounded by the same harmony.
    index = 1
    while index < len(merged) - 1:
        current = merged[index]
        if (current["end"] - current["start"] < 0.45 and
                merged[index - 1]["chord"] == merged[index + 1]["chord"] and
                current["chord"] != "N"):
            merged[index - 1]["end"] = merged[index + 1]["end"]
            del merged[index:index + 2]
        else:
            index += 1
    return [event for event in merged if event["chord"] != "N"]


def analyse(source, output, sources):
    audio, sample_rate = librosa.load(source, sr=22050, mono=True)
    hop = 2048
    chroma = librosa.feature.chroma_cqt(y=audio, sr=sample_rate, hop_length=hop)
    bass = librosa.feature.chroma_cqt(
        y=audio, sr=sample_rate, hop_length=hop, fmin=librosa.note_to_hz("C2"), n_octaves=3
    )
    labels = [label_for(chroma[:, frame], bass[:, frame]) for frame in range(chroma.shape[1])]
    times = librosa.frames_to_time(np.arange(len(labels) + 1), sr=sample_rate, hop_length=hop)
    events = []
    start = 0
    for index in range(1, len(labels) + 1):
        if index == len(labels) or labels[index] != labels[start]:
            events.append({"start": round(float(times[start]), 3), "end": round(float(times[index]), 3), "chord": labels[start]})
            start = index
    data = {
        "version": 1,
        "status": "automatic",
        "analyzer": "piano-bass chroma",
        "sources": sources,
        "events": merge(events),
    }
    directory = os.path.dirname(output) or "."
    fd, temporary = tempfile.mkstemp(prefix=".chords-", suffix=".json", dir=directory)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
    os.replace(temporary, output)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit("usage: analyze_chords.py input.wav output.json source-name [...]")
    source, output = sys.argv[1:3]
    try:
        analyse(source, output, sys.argv[3:])
    except Exception as error:
        with open(output + ".error", "w", encoding="utf-8") as handle:
            handle.write(str(error))
        raise
    finally:
        try:
            os.remove(source)
        except OSError:
            pass
