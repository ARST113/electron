#!/usr/bin/env bash
# Generate original HDR10, HLG and SDR samples without movie footage.
set -euo pipefail
mkdir -p fixtures
ffmpeg -hide_banner -encoders | grep -q 'libx265' || { echo "libx265 encoder unavailable"; exit 1; }
ffmpeg -hide_banner -encoders | grep -q 'libx264' || { echo "libx264 encoder unavailable"; exit 1; }

ffmpeg -nostdin -hide_banner -loglevel warning -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=3' \
  -an -c:v libx264 -threads 2 -preset ultrafast -crf 27 \
  -pix_fmt yuv420p -movflags +faststart fixtures/sdr-h264.mp4

ffmpeg -nostdin -hide_banner -loglevel warning -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=3' \
  -an -c:v libx265 -threads 2 -preset ultrafast -crf 25 \
  -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params 'pools=none:frame-threads=1:hdr10=1:repeat-headers=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400' \
  -movflags +faststart fixtures/hdr10-hevc.mp4

ffmpeg -nostdin -hide_banner -loglevel warning -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=3' \
  -an -c:v libx265 -threads 2 -preset ultrafast -crf 25 \
  -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params 'pools=none:frame-threads=1:repeat-headers=1' \
  -movflags +faststart fixtures/hlg-hevc.mp4

ffmpeg -nostdin -hide_banner -loglevel error -y \
  -i fixtures/hdr10-hevc.mp4 -map 0:v:0 -c:v copy fixtures/hdr10-hevc.mkv

for f in fixtures/*; do
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,pix_fmt,width,height,color_range,color_space,color_transfer,color_primaries,side_data_list \
    -of json "$f" > "$f.ffprobe.json"
done

python3 - <<'PY'
import json
from pathlib import Path
expected = {
  'hdr10-hevc.mp4': 'smpte2084',
  'hdr10-hevc.mkv': 'smpte2084',
  'hlg-hevc.mp4': 'arib-std-b67',
}
for name, transfer in expected.items():
    stream = json.loads(Path('fixtures', name + '.ffprobe.json').read_text())['streams'][0]
    assert stream['codec_name'] == 'hevc', (name, stream)
    assert stream['pix_fmt'] == 'yuv420p10le', (name, stream)
    assert stream['color_primaries'] == 'bt2020', (name, stream)
    assert stream['color_transfer'] == transfer, (name, stream)
    assert stream['color_space'] == 'bt2020nc', (name, stream)
    print('PASS fixture:', name, stream['codec_name'], stream['pix_fmt'], stream['color_primaries'], stream['color_transfer'])
PY
ls -lh fixtures/*.mp4 fixtures/*.mkv
