#!/bin/bash
# Builds the Fa promo audio: voiceover segments (macOS say), a mixed 19 s VO
# track per language, and an ffmpeg-composed synth music bed.
#
# Upgrade path (see CREATIVE.md "TTS route"): replace the `say` calls with a
# hosted TTS (OpenAI tts-1-hd / ElevenLabs) writing the SAME segment files,
# then re-run this script — offsets and mixing stay identical.
set -euo pipefail
cd "$(dirname "$0")/.."

VO=assets/voiceover
AU=assets/audio
mkdir -p "$VO" "$AU" build/audio

DUR=19.0

# segment: <lang> <idx> <start_seconds> <text>
segments=(
  "en 1 0.40 A dashboard that is truly yours."
  "en 2 3.00 Your own apps, built by chat."
  "en 3 6.20 Fa lives inside every app you create."
  "en 4 9.40 It draws, speaks and plays."
  "en 5 12.50 Any provider — your keys never leave the Keychain."
  "en 6 15.70 Fa — AI Agent."
  "ru 1 0.40 Дашборд, который по-настоящему ваш."
  "ru 2 3.00 Свои приложения — созданные в чате."
  "ru 3 6.20 Fa живёт внутри каждого приложения."
  "ru 4 9.40 Он рисует, говорит и играет."
  "ru 5 12.50 Любой провайдер — ключи остаются в Keychain."
  "ru 6 15.70 Fa — ваш AI-агент."
)

voice_for() { [ "$1" = en ] && echo Samantha || echo Milena; }

for line in "${segments[@]}"; do
  lang=$(cut -d' ' -f1 <<<"$line"); idx=$(cut -d' ' -f2 <<<"$line")
  text=$(cut -d' ' -f4- <<<"$line")
  out="$VO/${lang}_0${idx}.m4a"
  if [ ! -s "$out" ]; then
    say -v "$(voice_for "$lang")" -r 172 -o "$out" "$text"
  fi
done

# --- mix VO segments onto a 19 s timeline per language -----------------------
for lang in en ru; do
  inputs=(); chain=""; labels=""
  i=0
  for line in "${segments[@]}"; do
    l=$(cut -d' ' -f1 <<<"$line"); [ "$l" = "$lang" ] || continue
    idx=$(cut -d' ' -f2 <<<"$line"); start=$(cut -d' ' -f3 <<<"$line")
    ms=$(python3 -c "print(int(float('$start')*1000))")
    f="build/audio/${lang}_${idx}.wav"
    ffmpeg -y -v error -i "$VO/${lang}_0${idx}.m4a" -ar 48000 -ac 1 \
      -af "highpass=f=80, acompressor=threshold=-20dB:ratio=3:attack=8:release=120, volume=1.6" "$f"
    inputs+=(-i "$f")
    chain+="[$i:a]adelay=${ms}|${ms}[d$i];"
    labels+="[d$i]"
    i=$((i+1))
  done
  ffmpeg -y -v error "${inputs[@]}" \
    -filter_complex "${chain}${labels}amix=inputs=$i:normalize=0, apad, atrim=0:$DUR [a]" \
    -map "[a]" -ar 48000 -ac 2 "$VO/vo_${lang}.wav"
  ffmpeg -y -v error -i "$VO/vo_${lang}.wav" -c:a aac -b:a 192k "$VO/vo_${lang}.m4a"
  echo "vo_${lang}: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VO/vo_${lang}.m4a") s"
done

# --- music bed: A-minor synth pad, 19 s --------------------------------------
# Detuned sines → lowpass → slow tremolo pump → light echo; swell at the end
# card (14.8 s), fade out by 19 s.
ffmpeg -y -v error -filter_complex "
aevalsrc='0.30*sin(2*PI*110*t) + 0.22*sin(2*PI*164.81*t) + 0.20*sin(2*PI*220*t) + 0.13*sin(2*PI*261.63*t) + 0.10*sin(2*PI*220.9*t+1.3) + 0.08*sin(2*PI*330.2*t)':s=48000:d=$DUR [pad];
aevalsrc='0.05*sin(2*PI*659.25*t)*(0.5+0.5*sin(2*PI*0.11*t))':s=48000:d=$DUR [air];
[pad] lowpass=f=750, tremolo=f=0.3125:d=0.35 [padt];
[air] lowpass=f=2400 [airf];
[padt][airf] amix=inputs=2:normalize=0,
  aecho=0.7:0.85:90:0.28,
  volume='if(lt(t,1.2), t/1.2, if(lt(t,14.8), 1.0, if(lt(t,17.4), 1.0+0.45*(t-14.8)/2.6, max(0.0, 1.45*(1-(t-17.4)/1.6)))))':eval=frame,
  atrim=0:$DUR [m]" \
  -map "[m]" -ar 48000 -ac 2 "$AU/music_bed.wav"
ffmpeg -y -v error -i "$AU/music_bed.wav" -c:a aac -b:a 192k "$AU/music_bed.m4a"
echo "music: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AU/music_bed.m4a") s"
