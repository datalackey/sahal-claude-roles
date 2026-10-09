#!/usr/bin/env bash
set -euo pipefail

# --- Paths (you chose these) ---
VENV_DIR="$HOME/.local/venvs/nerd"
BIN_DIR="$HOME/scripts/DEVENV"
WRAPPER="$BIN_DIR/talk"
NERD_DIR="$HOME/nerd-dictation"
TMPDIR=$(mktemp -d -t nerdtmp.XXXXXX)
CONF_DIR="$HOME/.config/nerd-dictation"
MODEL_DIR="$CONF_DIR/model"
MODEL_URL="https://alphacephei.com/kaldi/models/vosk-model-small-en-us-0.15.zip"

echo "📦 Ensuring directories exist..."
mkdir -p "$VENV_DIR" "$BIN_DIR" "$CONF_DIR"

echo "🐍 Ensuring venv..."
if [ ! -d "$VENV_DIR/bin" ]; then
  python3 -m venv "$VENV_DIR"
fi
# activate venv
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

echo "⬆️  Upgrading pip tooling..."
pip install --upgrade pip wheel setuptools

echo "🧠 Installing Python deps (vosk)..."
pip install --upgrade vosk

echo "📥 Getting nerd-dictation (git repo, not a pip package)..."
if [ ! -d "$NERD_DIR/.git" ]; then
  git clone https://github.com/ideasman42/nerd-dictation.git "$NERD_DIR"
else
  (cd "$NERD_DIR" && git pull --ff-only || true)
fi

echo "🎙️ Ensuring Vosk model..."
if [ ! -d "$MODEL_DIR" ]; then
  TMP_ZIP="$CONF_DIR/model.zip"
  wget -qO "$TMP_ZIP" "$MODEL_URL"
  unzip -q "$TMP_ZIP" -d "$CONF_DIR"
  FOUND_DIR="$(find "$CONF_DIR" -maxdepth 1 -type d -name 'vosk-model-*' | head -n1 || true)"
  if [ -n "$FOUND_DIR" ]; then mv "$FOUND_DIR" "$MODEL_DIR"; fi
  rm -f "$TMP_ZIP"
fi


echo "🛠️  Writing wrapper: $WRAPPER"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Activate the nerd-dictation venv
# shellcheck disable=SC1090
source "$HOME/.local/venvs/nerd/bin/activate"

MODEL_DIR="${ND_MODEL_DIR:-$HOME/.config/nerd-dictation/model}"
DEVICE_ARG=""
if [[ -n "${ND_PULSE_SOURCE:-}" ]]; then
  DEVICE_ARG="--pulse-device-name=${ND_PULSE_SOURCE}"
fi

exec python3 "$HOME/nerd-dictation/nerd-dictation" "$@" --vosk-model-dir="$MODEL_DIR" $DEVICE_ARG
EOF
chmod +x "$WRAPPER"

echo "✅ Environment ready. Use:  talk begin  … then  talk end"
echo "   Tip: set a mic once (avoid monitors):"
echo "        echo 'export ND_PULSE_SOURCE=\"alsa_input.pci-0000_00_1f.3.analog-stereo\"' >> ~/.bashrc"
