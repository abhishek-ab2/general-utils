#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF_FILE="$CONF_DIR/90-combine-all-outputs.conf"

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
  desc=$(pw-cli info "$name" 2>/dev/null | grep -m1 'node.description' | cut -d'"' -f2 || true)
  printf "  %d) %s  [%s]\n" "$((i+1))" "${desc:-unknown}" "$name"
done
echo
read -rp "Enter the numbers to combine, separated by spaces (e.g. 1 3): " -a PICKS

MATCHES=""
for p in "${PICKS[@]}"; do
  idx=$((p-1))
  [[ $idx -ge 0 && $idx -lt ${#SINKS[@]} ]] || { echo "Invalid choice: $p"; exit 1; }
  name="${SINKS[$idx]}"
  if [[ $name == bluez_output.* ]]; then
    # Bluetooth names can end in .1/.2 depending on profile, so match any suffix
    pattern="~${name%.*}.*"
  else
    pattern="$name"
  fi
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

ID=$(wpctl status -n | grep -m1 'combine_all_outputs' | grep -oE '[0-9]+' | head -1 || true)
if [[ -n "${ID:-}" ]]; then
  wpctl set-default "$ID"
  echo "Default output set to 'Combined Outputs' (id $ID)"
else
  echo "Combined sink not found. Check: journalctl --user -u pipewire -n 50"
fi
