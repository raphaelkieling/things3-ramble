import json
import pathlib
import re
import subprocess
import tempfile
import wave

root = pathlib.Path(__file__).resolve().parent
out = root / "audio"
out.mkdir(exist_ok=True)
for clip in json.loads((root / "corpus.json").read_text()):
    path = out / (clip["id"] + ".wav")
    with tempfile.TemporaryDirectory() as tmp:
        aiff = pathlib.Path(tmp) / "voice.aiff"
        subprocess.run(["say", "-v", clip["voice"], "-r", str(clip["speed"]), "-o", aiff, clip["text"]], check=True)
        cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff)]
        if clip["noise"]:
            cmd += ["-f", "lavfi", "-i", "anoisesrc=r=24000:a=0.026:c=pink:s=42",
                    "-filter_complex", "amix=inputs=2:duration=first:normalize=0"]
        subprocess.run(cmd + ["-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", str(path)], check=True)
        # Mark speech on the clean source so background noise cannot extend the boundary.
        scan = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(aiff), "-af",
                               "silencedetect=n=-42dB:d=0.08", "-f", "null", "-"], text=True, capture_output=True, check=True)
        with wave.open(str(path)) as audio:
            duration = audio.getnframes() / audio.getframerate()
        starts = [float(v) for v in re.findall(r"silence_start: ([\d.]+)", scan.stderr)]
        ends = [float(v) for v in re.findall(r"silence_end: ([\d.]+)", scan.stderr)]
        boundary = starts[-1] if starts and ends and ends[-1] >= duration - .01 else duration
        path.with_suffix(".end").write_text(str(round(boundary * 1000)))
