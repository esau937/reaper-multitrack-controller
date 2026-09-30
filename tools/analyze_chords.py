#!/usr/bin/env python3
"""Create a persistent chord map without native audio-analysis dependencies."""
import json, os, sys, tempfile, wave
import numpy as np

PITCHES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")

def read_wav(path):
    with wave.open(path, "rb") as handle:
        channels, width, rate = handle.getnchannels(), handle.getsampwidth(), handle.getframerate()
        raw = handle.readframes(handle.getnframes())
    if width == 3:
        bytes_ = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        values = bytes_[:, 0].astype(np.int32) | (bytes_[:, 1].astype(np.int32) << 8) | (bytes_[:, 2].astype(np.int32) << 16)
        values = np.where(values & 0x800000, values - 0x1000000, values) / 8388608.0
    elif width == 2:
        values = np.frombuffer(raw, dtype="<i2").astype(float) / 32768.0
    elif width == 4:
        values = np.frombuffer(raw, dtype="<i4").astype(float) / 2147483648.0
    else:
        raise RuntimeError("Formato WAV não suportado")
    return values.reshape(-1, channels).mean(axis=1), rate

def make_templates():
    result = []
    for root in range(12):
        for suffix, degrees in (("", (0, 4, 7)), ("m", (0, 3, 7))):
            vector = np.zeros(12, dtype=float)
            vector[list((root + degree) % 12 for degree in degrees)] = 1.0
            result.append((PITCHES[root] + suffix, root, vector / np.linalg.norm(vector)))
    return result
TEMPLATES = make_templates()

def chroma(frame, rate, bass=False):
    spectrum = np.abs(np.fft.rfft(frame * np.hanning(len(frame))))
    frequencies = np.fft.rfftfreq(len(frame), 1.0 / rate)
    low, high = (32.7, 261.6) if bass else (55.0, 4186.0)
    valid = (frequencies >= low) & (frequencies <= high)
    frequencies, spectrum = frequencies[valid], spectrum[valid]
    midi = np.rint(69 + 12 * np.log2(frequencies / 440.0)).astype(int) % 12
    result = np.bincount(midi, weights=spectrum, minlength=12).astype(float)
    return result / (np.linalg.norm(result) or 1.0)

def label_for(harmony, bass):
    if float(np.sum(harmony)) < 0.01: return "N"
    score, name = max((float(np.dot(harmony, template)) + 0.16 * float(bass[root]), chord)
                      for chord, root, template in TEMPLATES)
    return name if score >= 0.48 else "N"

def merge(events):
    merged = []
    for event in events:
        if event["end"] - event["start"] < .12: continue
        if merged and merged[-1]["chord"] == event["chord"]: merged[-1]["end"] = event["end"]
        else: merged.append(event)
    index = 1
    while index < len(merged) - 1:
        event = merged[index]
        if event["end"] - event["start"] < .45 and event["chord"] != "N" and merged[index-1]["chord"] == merged[index+1]["chord"]:
            merged[index-1]["end"] = merged[index+1]["end"]
            del merged[index:index+2]
        else: index += 1
    return [event for event in merged if event["chord"] != "N"]

def analyse(source, output, sources):
    audio, rate = read_wav(source)
    frame_size, hop = 4096, 2048
    if len(audio) < frame_size: audio = np.pad(audio, (0, frame_size-len(audio)))
    labels, times = [], []
    for start in range(0, len(audio) - frame_size + 1, hop):
        frame = audio[start:start+frame_size]
        labels.append(label_for(chroma(frame, rate), chroma(frame, rate, True)))
        times.append(start / rate)
    times.append(len(audio) / rate)
    events, first = [], 0
    for index in range(1, len(labels)+1):
        if index == len(labels) or labels[index] != labels[first]:
            events.append({"start":round(times[first],3), "end":round(times[index],3), "chord":labels[first]})
            first = index
    data = {"version":1, "status":"automatic", "analyzer":"piano-bass spectral", "sources":sources, "events":merge(events)}
    directory = os.path.dirname(output) or "."
    fd, temporary = tempfile.mkstemp(prefix=".chords-", suffix=".json", dir=directory)
    with os.fdopen(fd, "w", encoding="utf-8") as handle: json.dump(data, handle, ensure_ascii=False, separators=(",",":"))
    os.replace(temporary, output)

if __name__ == "__main__":
    if len(sys.argv) < 4: raise SystemExit("usage: analyze_chords.py input.wav output.json source-name [...]")
    source, output = sys.argv[1:3]
    try: analyse(source, output, sys.argv[3:])
    except Exception as error:
        with open(output+".error", "w", encoding="utf-8") as handle: handle.write(str(error))
        raise
    finally:
        try: os.remove(source)
        except OSError: pass
