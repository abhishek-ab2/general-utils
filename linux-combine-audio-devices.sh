#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF_FILE="$CONF_DIR/90-combine-all-outputs.conf"
DEFAULT_VOLUME=40   # per-device volume (%) after combining

usage() {
  cat <<EOF
Usage: $(basename "$0") [--set-volume]

  (no option)    Pick output devices and combine them into "Combined Outputs"
  --set-volume   Interactively set the master and per-device volume levels
                 of an existing "Combined Outputs" sink
EOF
}

SET_VOLUME=false
case "${1:-}" in
  "") ;;
  --set-volume) SET_VOLUME=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac

# Print the wpctl id of the first node whose name starts with $1
node_id() {
  wpctl status -n | grep -m1 -oE "[0-9]+\. $1" | grep -oE '^[0-9]+' || true
}

describe() {
  pw-cli info "$1" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2 || true
}

# Current volume of node $1 as a whole percentage
get_pct() {
  wpctl get-volume "$1" | awk '{printf "%d", $2 * 100 + 0.5}'
}

# Ask for a new volume for node $1 (labelled $2), showing the current one as default
prompt_volume() {
  local cur vol
  cur=$(get_pct "$1")
  while true; do
    read -rp "  $2 [$cur%]: " vol
    vol="${vol%\%}"
    [[ -z $vol ]] && return
    [[ $vol =~ ^[0-9]+$ ]] && (( vol <= 150 )) && break
    echo "    Enter a number from 0 to 150"
  done
  wpctl set-volume "$1" "${vol}%"
}

set_volume() {
  local id line sid sink desc
  id=$(node_id combine_all_outputs)
  [[ -n $id ]] || { echo "Combined sink not found. Run $(basename "$0") without options first."; exit 1; }

  mapfile -t STREAMS < <(
    wpctl status -n | grep -oE '[0-9]+\. output\.combine_all_outputs_[^ ]+' | awk '!seen[$0]++'
  )

  echo "Set volume levels (Enter keeps the current value):"
  prompt_volume "$id" "Combined Outputs (master)"
  for line in "${STREAMS[@]}"; do
    sid="${line%%.*}"
    sink="${line#*output.combine_all_outputs_}"
    desc=$(describe "$sink")
    prompt_volume "$sid" "${desc:-$sink}"
  done
}

if $SET_VOLUME; then
  set_volume
  exit 0
fi

# Collect current output devices (excluding the combined sink itself)
mapfile -t SINKS < <(
  wpctl status -n | awk '/Sinks:/{f=1;next} /Sources:/{exit} f' \
  | grep -oE '(alsa_output|bluez_output)[^ ]+' | sort -u
)

if (( ${#SINKS[@]} == 0 )); then
  echo "No output devices found. Connect your devices and try again."
  exit 1
fi

echo "Available output devices:"
for i in "${!SINKS[@]}"; do
  name="${SINKS[$i]}"
  desc=$(describe "$name")
  printf "  %d) %s  [%s]\n" "$((i+1))" "${desc:-unknown}" "$name"
done
echo
read -rp "Enter the numbers to combine, separated by spaces (e.g. 1 3): " -a PICKS

MATCHES=""
PICKED=()
for p in "${PICKS[@]}"; do
  idx=$((p-1))
  [[ $idx -ge 0 && $idx -lt ${#SINKS[@]} ]] || { echo "Invalid choice: $p"; exit 1; }
  name="${SINKS[$idx]}"
  if [[ $name == bluez_output.* ]]; then
    # Bluetooth names can end in .1/.2 depending on profile, so match any suffix
    base="${name%.*}"
    pattern="~$base.*"
  else
    base="$name"
    pattern="$name"
  fi
  PICKED+=("$base")
  MATCHES+="                    { media.class = \"Audio/Sink\"  node.name = \"$pattern\" }"$'\n'
done

mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF
context.modules = [
{   name = libpipewire-module-combine-stream
    args = {
        combine.mode = sink
        node.name = "combine_all_outputs"
        node.description = "Combined Outputs"
        combine.latency-compensate = true
        combine.props = { audio.position = [ FL FR ] }
        stream.props = { stream.dont-remix = true }
        stream.rules = [
            {   matches = [
$MATCHES                ]
                actions = { create-stream = { } }
            }
        ]
    }
}
]
EOF

echo "Wrote $CONF_FILE"
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
sleep 3

ID=$(node_id combine_all_outputs)
if [[ -z $ID ]]; then
  echo "Combined sink not found. Check: journalctl --user -u pipewire -n 50"
  exit 1
fi
wpctl set-default "$ID"
echo "Default output set to 'Combined Outputs' (id $ID)"

# Volumes multiply: Combined sink x per-device stream x device sink.
# Pin the Combined sink and each device sink at 100%, and start every device's
# combine stream at DEFAULT_VOLUME; those streams are what --set-volume adjusts.
for base in "${PICKED[@]}"; do
  stream_id=$(node_id "output.combine_all_outputs_$base")
  sink_id=$(node_id "$base")
  # Lower the stream before raising the sink, so nothing gets loud in between
  [[ -n $stream_id ]] && wpctl set-volume "$stream_id" "${DEFAULT_VOLUME}%"
  [[ -n $sink_id ]] && wpctl set-volume "$sink_id" 1.0
done
wpctl set-volume "$ID" 1.0
echo "Each device set to ${DEFAULT_VOLUME}%. Run '$(basename "$0") --set-volume' to adjust them."
