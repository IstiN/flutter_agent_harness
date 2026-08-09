#!/bin/bash
# Builds the Fa promo v2 music bed: a 120 bpm synth pulse (kick + hats +
# bass + A-minor pad) with accent ticks at the cut beats and a swell into
# the end card. No samples — everything is ffmpeg-synthesized (royalty-safe).
#
# Beat grid: 120 bpm = 0.5 s per beat. Cut accents at 2 / 7 / 11 / 15 / 19 /
# 23 / 26 s (the scene boundaries from CREATIVE_V2.md).
set -euo pipefail
cd "$(dirname "$0")/.."

AU=assets/audio
mkdir -p "$AU" build/audio

DUR=30.0

# --- pass 1: the pulse bed --------------------------------------------------
ffmpeg -y -v error -filter_complex "
aevalsrc='sin(2*PI*55*t) * (lt(mod(t,0.5),0.16) * exp(-mod(t,0.5)*18))':s=48000:d=$DUR [kick];
aevalsrc='0.5*sin(2*PI*110*t) * lt(mod(t,0.5),0.10)':s=48000:d=$DUR [bass];
anoisesrc=color=pink:duration=$DUR [n];
[n] highpass=f=7000, tremolo=f=4:d=0.9, volume=0.045 [hats];
aevalsrc='0.20*sin(2*PI*220*t) + 0.15*sin(2*PI*261.63*t) + 0.11*sin(2*PI*329.63*t)':s=48000:d=$DUR [pad];
[pad] lowpass=f=950, volume='if(lt(t,1.0), t, if(lt(t,26), 1.0, min(1.6, 1.0+0.6*(t-26)/2)))':eval=frame [padv];
[kick][bass][hats][padv] amix=inputs=4:normalize=0,
volume='if(lt(t,27.6), 1.0, max(0.0, 1-(t-27.6)/2.4))':eval=frame,
atrim=0:$DUR [bed]" \
  -map "[bed]" -ar 48000 -ac 2 build/audio/bed.wav

# --- pass 2: accent ticks over the bed --------------------------------------
inputs=(-i build/audio/bed.wav)
chain=""
labels="[0:a]"
j=0
for t in 2 7 11 15 19 23 26; do
  f="build/audio/tick_$j.wav"
  ffmpeg -y -v error -f lavfi -i "anoisesrc=color=white:duration=0.09" \
    -af "highpass=f=1800, lowpass=f=5200, volume=1.6, afade=t=out:st=0:d=0.09" "$f"
  inputs+=(-i "$f")
  ms=$((t * 1000))
  chain+="[$((j+1)):a]adelay=$ms|$ms[t$j];"
  labels+="[t$j]"
  j=$((j+1))
done
ffmpeg -y -v error "${inputs[@]}" \
  -filter_complex "${chain}${labels}amix=inputs=$((j+1)):normalize=0, loudnorm=I=-17:TP=-1.5:LRA=9, atrim=0:$DUR [a]" \
  -map "[a]" -ar 48000 -ac 2 "$AU/music_v2.wav"
ffmpeg -y -v error -i "$AU/music_v2.wav" -c:a aac -b:a 192k "$AU/music_v2.m4a"
echo "music v2: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AU/music_v2.m4a") s"
