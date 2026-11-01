#!/usr/bin/env python3
"""Inputs for scripts/movie_probe_avc.c: an H.264 clip made here with ffmpeg (libx264, High profile, B-frames, two IDRs,
640x360 so the coded picture is taller than the movie), written as the probe's samples twice, and ffmpeg's own decode.

  lp.bin      4-byte length-prefixed samples, SPS and PPS only in the avcC record (passed as the format's "avcc")
  annexb.bin  start-code samples, SPS and PPS in-band before the first slice, no codec data in the format
  ref.nv12    every frame in presentation order, packed NV12

Sample file: b"AVCP", u32 width, height, samples, avcC length, the avcC record, then per sample (decode order)
u32 size, i64 presentation time in microseconds, the bytes.
usage: movie_probe_avc_inputs.py <output folder>
"""
import json
import struct
import subprocess
import sys
from pathlib import Path

W, H, FRAMES = 640, 360, 75


def box(data, name):
    at = data.find(name)
    if at < 4:
        raise SystemExit(f'no {name.decode()} box in the clip')
    size = struct.unpack('>I', data[at - 4:at])[0]
    return data[at + 4:at - 4 + size]


def main(out):
    out.mkdir(parents=True, exist_ok=True)
    mp4 = out / 'clip.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'testsrc2=size={W}x{H}:rate=30', '-frames:v', str(FRAMES),
                    '-c:v', 'libx264', '-profile:v', 'high', '-bf', '3', '-g', '40', '-pix_fmt', 'yuv420p', mp4], check=True)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', mp4, '-pix_fmt', 'nv12', '-f', 'rawvideo', out / 'ref.nv12'], check=True)
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts,pos,size',
                            '-show_entries', 'stream=time_base', '-of', 'json', mp4], check=True, capture_output=True, text=True)
    info = json.loads(probe.stdout)
    num, den = map(int, info['streams'][0]['time_base'].split('/'))
    data = mp4.read_bytes()
    avcc = box(data, b'avcC')
    sps_n = struct.unpack('>H', avcc[6:8])[0]
    sps = avcc[8:8 + sps_n]
    pps_n = struct.unpack('>H', avcc[9 + sps_n:11 + sps_n])[0]
    pps = avcc[11 + sps_n:11 + sps_n + pps_n]
    samples = [(data[int(p['pos']):int(p['pos']) + int(p['size'])], int(p['pts']) * num * 1000000 // den) for p in info['packets']]

    def annexb(sample, first):
        units, at = [], 0
        while at < len(sample):
            n = struct.unpack('>I', sample[at:at + 4])[0]
            units.append(sample[at + 4:at + 4 + n]); at += 4 + n
        if first:
            units = [sps, pps] + units
        return b''.join(b'\0\0\0\1' + u for u in units)

    for name, record, convert in (('lp.bin', avcc, lambda s, i: s), ('annexb.bin', b'', annexb)):
        with open(out / name, 'wb') as f:
            f.write(b'AVCP' + struct.pack('<IIII', W, H, len(samples), len(record)) + record)
            for i, (s, pts) in enumerate(samples):
                s = convert(s, i == 0)
                f.write(struct.pack('<Iq', len(s), pts) + s)
    (out / 'meta.txt').write_text(f'{W} {H} {len(samples)}\n')
    print(f'{len(samples)} samples of {W}x{H} H.264, avcC {len(avcc)} bytes, in {out}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]))
