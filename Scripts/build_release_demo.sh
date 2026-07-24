#!/bin/bash
set -euo pipefail

if [[ "$#" -lt 4 || "$#" -gt 5 ]]; then
  echo "Usage: bash Scripts/build_release_demo.sh <welcome.mov> <typing.mov> <results.mov> <settings.mov> [output.mp4]" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WELCOME_CAPTURE="$1"
TYPING_CAPTURE="$2"
RESULTS_CAPTURE="$3"
SETTINGS_CAPTURE="$4"
OUTPUT_PATH="${5:-$REPO_ROOT/docs/assets/OpenFind-60s-demo.mp4}"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)"
OUTPUT_NAME="$(basename "$OUTPUT_PATH")"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.openfind-release-demo.XXXXXX")"
OVERLAY_DIR="$WORK_DIR/overlays"
ENCODED_VIDEO="$WORK_DIR/$OUTPUT_NAME"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR"/.openfind-release-demo.*)
      if [[ -d "$WORK_DIR" ]]; then
        /bin/rm -R "$WORK_DIR"
      fi
      ;;
    *)
      echo "Refusing to clean unexpected work directory: $WORK_DIR" >&2
      ;;
  esac
}
trap cleanup EXIT

for command_name in ffmpeg ffprobe swift; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 69
  fi
done

for input_path in \
  "$WELCOME_CAPTURE" \
  "$TYPING_CAPTURE" \
  "$RESULTS_CAPTURE" \
  "$SETTINGS_CAPTURE" \
  "$REPO_ROOT/Scripts/Assets/OpenFindIcon.png" \
  "$REPO_ROOT/docs/assets/openfind-search.png" \
  "$REPO_ROOT/docs/assets/openfind-interface-size.png" \
  "$REPO_ROOT/docs/assets/openfind-welcome.png"; do
  if [[ ! -f "$input_path" ]]; then
    echo "Missing demo input: $input_path" >&2
    exit 66
  fi
done

swift "$REPO_ROOT/Scripts/render_demo_overlays.swift" \
  "$OVERLAY_DIR" \
  "$REPO_ROOT/Scripts/Assets/OpenFindIcon.png"

ffmpeg -hide_banner -loglevel warning -y \
  -loop 1 -framerate 30 -t 4 -i "$OVERLAY_DIR/intro.png" \
  -i "$WELCOME_CAPTURE" \
  -loop 1 -framerate 30 -t 8 -i "$OVERLAY_DIR/caption-welcome.png" \
  -i "$TYPING_CAPTURE" \
  -loop 1 -framerate 30 -t 4 -i "$OVERLAY_DIR/caption-search-typing.png" \
  -i "$RESULTS_CAPTURE" \
  -loop 1 -framerate 30 -t 6 -i "$OVERLAY_DIR/caption-search-results.png" \
  -i "$SETTINGS_CAPTURE" \
  -loop 1 -framerate 30 -t 14 -i "$OVERLAY_DIR/caption-settings.png" \
  -loop 1 -framerate 30 -t 8 -i "$REPO_ROOT/docs/assets/openfind-search.png" \
  -loop 1 -framerate 30 -t 8 -i "$OVERLAY_DIR/caption-minimum.png" \
  -loop 1 -framerate 30 -t 8 -i "$REPO_ROOT/docs/assets/openfind-interface-size.png" \
  -loop 1 -framerate 30 -t 8 -i "$OVERLAY_DIR/caption-scale.png" \
  -loop 1 -framerate 30 -t 4 -i "$REPO_ROOT/docs/assets/openfind-welcome.png" \
  -loop 1 -framerate 30 -t 4 -i "$OVERLAY_DIR/caption-overview.png" \
  -loop 1 -framerate 30 -t 4 -i "$OVERLAY_DIR/outro.png" \
  -filter_complex "
    [0:v]scale=1920:1080,setsar=1,
      zoompan=z='1+0.035*on/119':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=4,setpts=PTS-STARTPTS,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=3.75:d=0.25[s0];

    [1:v]trim=start=2.5:end=10.5,setpts=PTS-STARTPTS,fps=30,
      crop=2260:1272:0:0,scale=1920:1080:flags=lanczos,setsar=1,
      zoompan=z='1+0.07*on/239':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=8,setpts=PTS-STARTPTS[welcome];
    [2:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[welcome_caption];
    [welcome][welcome_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=7.75:d=0.25[s1];

    [3:v]trim=start=5.5:end=9.5,setpts=PTS-STARTPTS,fps=30,
      crop=2260:1272:0:0,scale=1920:1080:flags=lanczos,setsar=1,
      zoompan=z='1+0.05*on/119':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=4,setpts=PTS-STARTPTS[typing];
    [4:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[typing_caption];
    [typing][typing_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=3.75:d=0.25[s2];

    [5:v]trim=start=3:end=9,setpts=PTS-STARTPTS,fps=30,
      crop=2260:1272:0:0,scale=1920:1080:flags=lanczos,setsar=1,
      zoompan=z='1+0.06*on/179':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=6,setpts=PTS-STARTPTS[results];
    [6:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[results_caption];
    [results][results_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=5.75:d=0.25[s3];

    [7:v]trim=start=4:end=18,setpts=PTS-STARTPTS,fps=30,
      crop=1800:1012:0:0,scale=1920:1080:flags=lanczos,setsar=1,
      zoompan=z='1+0.10*on/419':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=14,setpts=PTS-STARTPTS[settings];
    [8:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[settings_caption];
    [settings][settings_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=13.75:d=0.25[s4];

    [9:v]scale=1920:1080:force_original_aspect_ratio=increase,
      crop=1920:1080,setsar=1,
      zoompan=z='1+0.07*on/239':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=8,setpts=PTS-STARTPTS[minimum];
    [10:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[minimum_caption];
    [minimum][minimum_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=7.75:d=0.25[s5];

    [11:v]scale=1920:1080:force_original_aspect_ratio=increase,
      crop=1920:1080,setsar=1,
      zoompan=z='1+0.055*on/239':x='iw/2-(iw/zoom/2)':y='(ih-ih/zoom)*0.18':d=1:s=1920x1080:fps=30,
      trim=duration=8,setpts=PTS-STARTPTS[scale_scene];
    [12:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[scale_caption];
    [scale_scene][scale_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=7.75:d=0.25[s6];

    [13:v]scale=1920:1080:force_original_aspect_ratio=increase,
      crop=1920:1080,setsar=1,
      zoompan=z='1+0.035*on/119':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=4,setpts=PTS-STARTPTS[overview];
    [14:v]scale=1920:1080,setsar=1,format=rgba,setpts=PTS-STARTPTS[overview_caption];
    [overview][overview_caption]overlay=shortest=1:format=auto,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=3.75:d=0.25[s7];

    [15:v]scale=1920:1080,setsar=1,
      zoompan=z='1+0.055*on/119':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,
      trim=duration=4,setpts=PTS-STARTPTS,format=yuv420p,
      fade=t=in:st=0:d=0.25,fade=t=out:st=3.75:d=0.25[s8];

    [s0][s1][s2][s3][s4][s5][s6][s7][s8]
      concat=n=9:v=1:a=0[outv]
  " \
  -map "[outv]" \
  -frames:v 1800 \
  -c:v libx264 \
  -preset slow \
  -crf 18 \
  -pix_fmt yuv420p \
  -r 30 \
  -movflags +faststart \
  -an \
  "$ENCODED_VIDEO"

VIDEO_STREAM_PROBE="$(ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=codec_name,width,height,avg_frame_rate \
  -of csv=p=0 \
  "$ENCODED_VIDEO")"
VIDEO_DURATION="$(ffprobe -v error \
  -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 \
  "$ENCODED_VIDEO")"

if [[ "$VIDEO_STREAM_PROBE" != "h264,1920,1080,30/1" ]]; then
  echo "Unexpected demo video stream: $VIDEO_STREAM_PROBE" >&2
  exit 65
fi

if [[ "$VIDEO_DURATION" != "60.000000" ]]; then
  echo "Unexpected demo duration: $VIDEO_DURATION" >&2
  exit 65
fi

FREEZE_REPORT="$(ffmpeg -hide_banner -nostats \
  -i "$ENCODED_VIDEO" \
  -vf "freezedetect=n=-50dB:d=1.5" \
  -an \
  -f null - 2>&1)"

if [[ "$FREEZE_REPORT" == *"lavfi.freezedetect.freeze_start"* ]]; then
  echo "Demo contains a visually static span of at least 1.5 seconds:" >&2
  echo "$FREEZE_REPORT" >&2
  exit 65
fi

mv "$ENCODED_VIDEO" "$OUTPUT_PATH"
echo "Built $OUTPUT_PATH"
echo "Stream: $VIDEO_STREAM_PROBE"
echo "Duration: $VIDEO_DURATION"
echo "Freeze gate: no static span reached 1.5 seconds"
