#!/usr/bin/env bash

# 📁 Validate that devenv is correctly linked
if [ ! -d "/etc/nixos/devenv" ]; then
  echo "/etc/nixos/devenv missing.  Suggestion: run the cmds below"
  echo "rm -rf /etc/nixos ; sudo ln -s ~/nixos-config /etc/nixos"
  exit 1
fi

# ✅ Check for SSH key
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  echo "❗ ssh key setup required. use nixos setup notes"
  echo "Press Enter after creating your SSH key to continue..."
  read -r
  if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    echo "❌ id_rsa still missing; aborting."
    exit 1
  fi
fi


# Install flatpak for intellij Idea ultimate.  This install method avoids .so library
# sharing which nixos makes tricky due to non-standard paths.  But it duplicates .so libs that
# otherwise would be shared...  That's the price we have to pay to run idea though.
#
flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y --user flathub com.jetbrains.IntelliJ-IDEA-Ultimate
flatpak list --user | grep IntelliJ || echo "⚠️ WARNING IntelliJ not found for user chris"

#  supress annoying nautilus file mgr warnings
touch ~/.gtk-bookmarks
mkdir -p ~/.cache/thumbnails/normal

# ✅ Restore MATE panel, terminal, etc config from dconf backup (first-run only —
# reruns should not clobber panel state you've since customized; use
# misc-utils/panel-restore.js to force-restore intentionally)
PANEL_RESTORE_MARKER="$HOME/.config/devenv/.panel-restored"
if [ ! -f "$PANEL_RESTORE_MARKER" ]; then
  dconf load / < /etc/nixos/devenv/mate-dconf-backup.ini
  dconf load /org/mate/panel/ < /etc/nixos/devenv/mate-panel-dconf-backup.ini
  mkdir -p "$(dirname "$PANEL_RESTORE_MARKER")"
  touch "$PANEL_RESTORE_MARKER"
else
  echo "skipping dconf panel/system restore (already run once — use panel-restore.js to force)"
fi

# ✅ Restore sound settings
sudo amixer set Master unmute
sudo amixer set Master 80%

echo "🔧 Checking Dropbox bootstrap..."

if [ ! -d "$HOME/.dropbox-dist" ]; then
  echo "📦 First-time Dropbox initialization... Takes about 5 minutes, then you will see OS prompt"
  cd /home/chris                    #   ensures Dropbox sets up its files under ~/.dropbox-dist and ~/Dropbox
  dropbox start -i
  echo "✅ Dropbox GUI should prompt for login. Once done, press Enter to continue..."
  read -r
else
  echo "✅ Dropbox already initialized."
  if ! pgrep -f ".dropbox-dist/.*/dropbox" >/dev/null 2>&1; then
    echo "🚀 Starting Dropbox daemon..."
    dropbox start
  else
    echo "⏭️  Dropbox daemon already running, skipping start."
  fi

fi

# Verify Dropbox actually started
for i in {1..12}; do   # wait up to 60s
    if pgrep -f ".dropbox-dist/.*/dropbox" >/dev/null 2>&1 && [ -S "$HOME/.dropbox/command_socket" ]; then
        echo "✅ Dropbox daemon is running and socket is ready."
        break
    else
        echo "… waiting for Dropbox daemon to come up ($i/12)"
        sleep 5
    fi
done

if ! pgrep -f ".dropbox-dist/.*/dropbox" >/dev/null 2>&1 || [ ! -S "$HOME/.dropbox/command_socket" ]; then
    echo "❌ Dropbox failed to start, aborting setup."
    exit 1
fi



echo "⚙️ Ensuring Dropbox autostarts on login..."

AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/dropbox.desktop" <<EOF
[Desktop Entry]
Type=Application
Exec=dropbox start
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Dropbox
Comment=Start Dropbox on login
EOF

chmod +x "$AUTOSTART_DIR/dropbox.desktop"

echo "✅ Dropbox autostart configured via desktop entry."



# ✅ Wait for Dropbox to finish syncing required files
REQUIRED_FILES=(
    $HOME/Dropbox/projects/devEnv/scripts
    $HOME/Dropbox/projects/devEnv/config/.ideavimrc 
    $HOME/Dropbox/projects/devEnv/config/vim 
    $HOME//Dropbox/projects/devEnv/config/ssh 
)

echo "⏳ Waiting for Dropbox to sync required files..."
for f in "${REQUIRED_FILES[@]}"; do
  until [ -f "$f" -o  -d "$f"  ]; do
    echo "… still waiting for $f"
    sleep 5
  done
  echo "✓ Found $f"
done

echo "🎯 Dropbox milestone reached — safe to continue."

bash /etc/nixos/devenv/claude/setup-claude-configs.sh --host-mode





# 📦 First-time Insync setup
echo "🔧 Checking Insync bootstrap..."

if [ ! -d "$HOME/.config/Insync" ]; then
  echo "📦 First-time Insync initialization..."
  (cd $HOME ; insync start &)		# running from /etc/nixos causes issues
  echo "✅ Insync GUI should prompt for login. Once done, press Enter to continue..."
  read -r
else
  echo "✅ Insync already initialized."
fi

echo "⚙️ Ensuring Insync autostarts on login..."

cat > "$AUTOSTART_DIR/insync.desktop" <<EOF

[Desktop Entry]
Type=Application
Exec=insync start
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Insync
Comment=Start Insync on login
EOF

chmod +x "$AUTOSTART_DIR/insync.desktop"

echo "✅ Insync autostart configured via desktop entry."


# 📦 Trezor Suite setup
echo "🔧 Checking Trezor Suite..."

TREZOR_DIR="$HOME/.local/share/trezor-suite"
TREZOR_APP="$TREZOR_DIR/Trezor-Suite-25.8.2-linux-x86_64.AppImage"

mkdir -p "$TREZOR_DIR"
if [ ! -f "$TREZOR_APP" ]; then
  echo "📥 Downloading Trezor Suite AppImage..."
  wget -q https://data.trezor.io/suite/releases/desktop/latest/Trezor-Suite-25.8.2-linux-x86_64.AppImage -O "$TREZOR_APP"
  chmod +x "$TREZOR_APP"
else
  echo "✅ Trezor Suite AppImage already present."
fi

# Ensure alias is present
if ! grep -q "alias trez=" "$HOME/.bashrc"; then
  echo "alias trez='pushd /home/chris ; nix-shell -p appimage-run --run \"appimage-run $TREZOR_APP\" ; popd'" >> "$HOME/.bashrc"
  echo "✅ Added trez alias to ~/.bashrc"
else
  echo "⏭️  trez alias already configured in ~/.bashrc"
fi


cd $HOME


rm -f ~/.gitignore
ln -s "$HOME/Dropbox/projects/devEnv/config/.gitignore" ~/.gitignore

# Git settings: ~/.gitconfig is a symlink to devenv/git.config, so a plain `git config --global`
# edits the tracked file (git follows the symlink). `git status` in /etc/nixos then shows what
# to commit so future machines inherit it. An existing regular file is backed up first.
# Safe to re-run.
GIT_DEVENV_CONFIG=/etc/nixos/devenv/git.config
if [ "$(readlink ~/.gitconfig 2>/dev/null)" != "$GIT_DEVENV_CONFIG" ]; then
  if [ -e ~/.gitconfig ] || [ -L ~/.gitconfig ]; then
    mv ~/.gitconfig ~/.gitconfig.bak.$(date +%Y%m%d%H%M%S)
  fi
  ln -s "$GIT_DEVENV_CONFIG" ~/.gitconfig
fi

## ssh config
rm -rf ~/.ssh
ln -s $HOME/Dropbox/projects/devEnv/config/ssh ~/.ssh
chmod 500  ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa*
chmod 700 ~/.ssh


rm -f $HOME/config
ln -s Dropbox/projects/devEnv/config/

rm -f $HOME/scripts
ln -s Dropbox/projects/devEnv/scripts

# This config setup should eventually be replaced by the script: setup-misc-configs.sh
#
rm -f $HOME/.vimrc
ln -s /etc/nixos/devenv/vim.rc  .vimrc

mkdir -p "$HOME/.config/direnv"
rm -f "$HOME/.config/direnv/direnvrc"
ln -s /etc/nixos/devenv/misc-configs/direnvrc "$HOME/.config/direnv/direnvrc"

mkdir -p "$HOME/.config/gtk-3.0"
rm -f "$HOME/.config/gtk-3.0/settings.ini"
ln -s /etc/nixos/devenv/misc-configs/gtk-3.0-settings.ini "$HOME/.config/gtk-3.0/settings.ini"

rm -f $HOME/.ideavimrc
ln -s Dropbox/projects/devEnv/config/.ideavimrc .ideavimrc

rm -rf $HOME/.vim
ln -s Dropbox/projects/devEnv/config/vim .vim

grep "config.bashrc"  ~/.bashrc
if [ "$?"  -eq  "0" ] ; then
	echo skipping bashrc config
else
	echo adding bashrc config
	echo ". \$HOME/config/bashrc" >> ~/.bashrc
fi
# END: This config setup should eventually be replaced by the script: setup-misc-configs


## Put repo-owned scripts (devenv/misc-utils) on PATH so they are callable by bare name.
grep -q "/etc/nixos/devenv/misc-utils" ~/.bashrc
if [ "$?" -eq "0" ] ; then
	echo skipping devenv/misc-utils PATH config
else
	echo adding devenv/misc-utils to PATH
	echo 'export PATH="/etc/nixos/devenv/misc-utils:$PATH"' >> ~/.bashrc
fi


## Password setup
/etc/nixos/devenv/change_passwd.sh

echo ""
echo "🔐 Manual step required — Claude OAuth login (needed for voice feature):"
echo "   $HOME/.npm-global/bin/claude login"

echo ""
echo "🔄 Loading your new environment (PATH, aliases) — no logout needed..."
exec "$SHELL" -l

