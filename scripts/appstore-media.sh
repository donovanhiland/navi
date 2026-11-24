#!/bin/zsh
# Builds the App Store screenshots (1320 × 2868, 6.9") and the app preview
# (886 × 1920, 30 fps, silent AAC) for Navi for iPhone into iOS/AppStore/.
#
# Input: a folder of real 3x Simulator captures from an iPhone 17 Pro Max
# running the Debug app with `-NaviDemo YES` (a scripted dictation through the
# real keyboard and app link), in dark mode, status bar at 9:41:
#   home.png            the Navi app
#   apple-keyboard.png  Messages with Apple's keyboard up
#   listen.png          the Navi pad with every live word shown
#   cleanup.png         the pad showing the cleanup (struck filler)
#   typed.png           the cleaned text in the Messages field
#   flow.mp4            one take: field tap, globe, talk, Done, typed text
#
# Needs: ImageMagick (magick) and ffmpeg.
# Usage: scripts/appstore-media.sh <captures-folder>
set -euo pipefail

root=${0:A:h:h}
raw=${1:?Usage: scripts/appstore-media.sh <captures-folder>}
raw=${raw:A}
out="$root/iOS/AppStore"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for file in home.png apple-keyboard.png listen.png cleanup.png typed.png flow.mp4; do
  [[ -f "$raw/$file" ]] || { echo "Missing $raw/$file" >&2; exit 1; }
done
command -v magick >/dev/null || { echo "Needs ImageMagick (brew install imagemagick)" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "Needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

font=/System/Library/Fonts/SFNS.ttf
ink='#07080C'
backlink='rectangle 20,105 175,160'

mkdir -p "$out/screenshots" "$out/preview"

rounded() {
  local width=$1 height=$2 radius=$3 name=$4
  magick -size ${width}x${height} xc:black -fill white \
    -draw "roundrectangle 0,0,$((width - 1)),$((height - 1)),$radius,$radius" "$work/$name-mask.png"
  magick -size ${width}x${height} xc:none -fill none -stroke 'rgba(255,255,255,0.16)' -strokewidth 3 \
    -draw "roundrectangle 1,1,$((width - 2)),$((height - 2)),$radius,$radius" "$work/$name-ring.png"
}

rounded 1040 2260 126 shot
screenshot() {
  local source=$1 name=$2 title=$3 subtitle=$4 cover=${5:-$backlink}
  magick "$raw/$source" -fill black -draw "$cover" -resize 1040x2260! \
    "$work/shot-mask.png" -alpha off -compose CopyOpacity -composite "$work/$name.png"
  magick -size 1320x2868 xc:$ink \
    -font $font -fill white -pointsize 92 -gravity north -annotate +0+190 "$title" \
    -fill 'rgba(255,255,255,0.62)' -pointsize 48 -annotate +0+335 "$subtitle" \
    "$work/$name.png" -gravity north -geometry +0+590 -composite \
    "$work/shot-ring.png" -gravity north -geometry +0+590 -composite \
    -alpha off -strip "$out/screenshots/$name.png"
}

echo "› Screenshots"
screenshot listen.png 01-talk "Talk. Navi types." "Live words as you speak, right in the keyboard"
screenshot cleanup.png 02-cleanup "Ums out. Periods in." "Navi cleans up filler and fixes capitals"
screenshot typed.png 03-typed "Lands where you type" "Messages, Notes, Mail, any text field"
screenshot apple-keyboard.png 04-globe "Keep Apple's keyboard" "Navi is one tap away on the globe key"
screenshot home.png 05-private "Stays on your iPhone" "Speech and cleanup run on device. No cloud." "point 0,0"

echo "› App preview"
rounded 720 1564 86 phone
captions=("Keep Apple's keyboard" "Tap the globe and talk" "Ums out. Periods in." "Typed right where you are")
for index in {1..4}; do
  magick -size 886x200 xc:none -font $font -fill white -pointsize 58 -gravity center \
    -annotate +0+0 "${captions[$index]}" "$work/caption$index.png"
done
ffmpeg -v error -y -ss 2 -i "$raw/flow.mp4" -i "$work/phone-mask.png" -i "$work/phone-ring.png" \
  -i "$work/caption1.png" -i "$work/caption2.png" -i "$work/caption3.png" -i "$work/caption4.png" \
  -f lavfi -i anullsrc=r=44100:cl=stereo -filter_complex "\
[0:v]drawbox=x=20:y=105:w=155:h=55:color=black:t=fill,scale=720:1564,format=rgba,tpad=stop_mode=clone:stop_duration=2[phone];\
[1:v]format=gray[mask];[phone][mask]alphamerge[rounded];\
color=c=0x07080C:s=886x1920:r=30[bg];\
[bg][rounded]overlay=x=(W-w)/2:y=290:shortest=1[a];[a][2:v]overlay=x=(W-w)/2:y=290[b];\
[b][3:v]overlay=0:70:enable='lt(t,3.4)'[c1];\
[c1][4:v]overlay=0:70:enable='between(t,3.4,12.2)'[c2];\
[c2][5:v]overlay=0:70:enable='gt(t,12.2)*lt(t,14.2)'[c3];\
[c3][6:v]overlay=0:70:enable='gte(t,14.2)',fps=30,format=yuv420p[v]" \
  -map "[v]" -map 7:a -c:v libx264 -profile:v high -level 4.0 -b:v 10M -preset slow \
  -c:a aac -b:a 256k -shortest -movflags +faststart "$out/preview/navi-preview-886x1920.mp4"
ffmpeg -v error -y -ss 13 -i "$out/preview/navi-preview-886x1920.mp4" -frames:v 1 "$out/preview/poster.png"

echo "› Done: $out/screenshots and $out/preview"
