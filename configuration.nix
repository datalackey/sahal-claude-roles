{ config, pkgs, lib,  ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # ✅ Enable nix-command and flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;

  boot.kernel.sysctl."fs.inotify.max_user_watches" = 524288;

  time.timeZone = "America/Los_Angeles";

  systemd.tmpfiles.rules = [
    "d /tmp 1777 root root 20d"
  ];

  services.xserver = {
    enable = true;
    desktopManager.mate.enable = true;
    displayManager.lightdm.enable = true;
    videoDrivers = [ "nvidia" ];
  };

  services.ollama = {
    enable = true;
    # For now, we'll skip GPU acceleration since you just want to test
    # If you have an NVIDIA GPU and want to enable it later:
    # acceleration = "cuda";
  };


  # PRIME offload: Intel drives the display at all times; NVIDIA (Quadro
  # M4000M, Maxwell/GM204) stays idle unless explicitly invoked via
  # `nvidia-offload <cmd>`. open = false because Maxwell predates the open
  # kernel module's supported hardware (Turing+ only).
  hardware.nvidia = {
    modesetting.enable = true;
    open = false;
    # Suspend/resume state save-restore for the proprietary driver. Not
    # `finegrained` (runtime D3 power-off) -- that's Turing+ only and this
    # is a Maxwell M4000M. Recommended whenever prime.offload/reverseSync
    # is in play; suspected root cause of a black-screen-on-resume after
    # reverseSync was enabled without this set.
    powerManagement.enable = true;
    # nvidiaPackages.stable moved past 595.xx and dropped Maxwell (GM204)
    # support -- NVRM logs "No NVIDIA GPU found" and no-ops. legacy_580 is
    # nixpkgs' current LTSB branch covering Maxwell-Volta.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;

    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
      # External DP/HDMI ports on this laptop are wired directly to the
      # NVIDIA GPU (confirmed via `HDA NVidia HDMI/DP` audio codec on PCI
      # 01:00.1), not Intel. Plain offload never drives physical outputs,
      # so reverseSync is required to light them up. Experimental/buggy
      # upstream (known issues: crash on external-monitor unplug, possible
      # issues on sleep/wake) -- see devenv/claude/DECISIONS.md if this
      # gets promoted to a documented decision, and HOW-TO for the test
      # protocol.
      reverseSync.enable = true;
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  hardware.graphics.enable = true;

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.lightdm.enableGnomeKeyring = true;

  virtualisation.docker.enable = true;
  virtualisation.virtualbox.host.enable = true;
  virtualisation.virtualbox.host.enableExtensionPack = true;

  users.groups.chris = {};

  users.users.chris = {
    isNormalUser = true;
    group = "chris";
    extraGroups = [ "wheel" "networkmanager" "docker" "vboxusers" "lp" "scanner" "video" ];
    initialHashedPassword = lib.removeSuffix "\n" (builtins.readFile ./secrets/chris-password);
  };

  users.users.test = {
    isNormalUser = true;
    group = "chris";
    extraGroups = [ "wheel" "networkmanager" "docker" "vboxusers" "lp" "scanner" "video" ];
    initialHashedPassword = lib.removeSuffix "\n" (builtins.readFile ./secrets/chris-password);
  };

  users.users.alt = {
    isNormalUser = true;
    group = "chris";
    extraGroups = [ "wheel" "networkmanager" "docker" "vboxusers" "lp" "scanner" "video" ];
    initialHashedPassword = lib.removeSuffix "\n" (builtins.readFile ./secrets/chris-password);
  };

  # Force-syncs chris's MATE panel layout and window-manager keybindings onto
  # the test/alt accounts on every rebuild switch, so they always match
  # chris's current setup. This overwrites (not merges) those subtrees for
  # test/alt each time -- any customization they make themselves is clobbered
  # on the next switch. That's intentional: chris's saved state always wins.
  system.activationScripts.syncMatePanelToNewUsers.text = ''
    log=/var/log/sync-mate-panel.log
    echo "=== $(date -Iseconds) syncMatePanelToNewUsers ===" >> "$log"
    panelSrc=/home/chris/.config/dconf/user
    if [ ! -f "$panelSrc" ]; then
      echo "SKIP: $panelSrc not found" >> "$log"
    else
      for subtree in /org/mate/panel/ /org/mate/marco/; do
        dump=$(mktemp)
        HOME=/home/chris ${pkgs.dconf}/bin/dconf dump "$subtree" > "$dump" 2>>"$log"
        size=$(wc -c < "$dump")
        echo "dump $subtree: $size bytes" >> "$log"
        if [ -s "$dump" ]; then
          for u in test alt; do
            if ! id "$u" >/dev/null 2>&1; then
              echo "SKIP $u: no such user" >> "$log"
              continue
            fi
            h=$(getent passwd "$u" | cut -d: -f6)
            g=$(id -gn "$u")
            install -d -m 0700 -o "$u" -g "$g" "$h/.config/dconf" || echo "FAIL $u: install -d" >> "$log"
            # dconf load talks to dconf-service over D-Bus; there's no session
            # bus in an activation script, so it needs a throwaway one.
            if HOME="$h" PATH="${pkgs.dbus}/bin:$PATH" ${pkgs.dbus}/bin/dbus-run-session -- ${pkgs.dconf}/bin/dconf load "$subtree" < "$dump" >>"$log" 2>&1; then
              chown "$u":"$g" "$h/.config/dconf/user" 2>>"$log"
              chmod 0600 "$h/.config/dconf/user" 2>>"$log"
              echo "OK $u: loaded $subtree" >> "$log"
            else
              echo "FAIL $u: dconf load $subtree (exit $?)" >> "$log"
            fi
          done
        fi
        rm -f "$dump"
      done
    fi
  '';

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="backlight", RUN+="${pkgs.coreutils}/bin/chgrp video $sys$devpath/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w $sys$devpath/brightness"
  '';

  # mate-power-manager always shells out to mate-power-backlight-helper via
  # pkexec for brightness changes (no direct sysfs write, no toggle to skip
  # it), and pkexec resolves that call against the generic
  # org.freedesktop.policykit.exec action (auth_admin) instead of the
  # specific org.mate.power.backlight-helper action that's already
  # implicit-active=yes. Scoped to this one helper binary, active local
  # sessions, and the video group, so it doesn't grant blanket
  # password-less root exec.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.policykit.exec" &&
          action.lookup("program") &&
          action.lookup("program").indexOf("mate-power-backlight-helper") != -1 &&
          subject.active && subject.local &&
          subject.isInGroup("video")) {
        return polkit.Result.YES;
      }
    });
  '';

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };



services.printing = {
  enable = true;
  browsing = false;
  listenAddresses = [ "localhost:631" ];
};

# And make sure cups-browsed stays off
systemd.services.cups-browsed.enable = false;

# Declares the Brother MFC-J5010DW print queue via lpadmin at boot.
# CUPS 1.6+ dropped support for defining printers via a <Printer> block
# in cupsd.conf (that syntax only works in the runtime-managed
# printers.conf) — a prior HP <Printer> stanza here looked functional
# but was actually inert; the real registration happened via a one-off
# lpadmin call. This service makes that registration reproducible.
# MFC-J5010DW supports IPP Everywhere, so no vendor driver package is needed.
systemd.services.setup-brother-printer = {
  description = "Register Brother MFC-J5010DW CUPS queue";
  after = [ "cups.service" ];
  requires = [ "cups.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.cups}/bin/lpadmin -p BrotherMFCJ5010DW -E -v ipp://192.168.1.215/ipp/print -m everywhere";
  };
};



  hardware.sane.enable = true;
  # eSCL/WSD driverless scanning; the MFC-J5010DW supports eSCL so no
  # Brother driver package is needed. If scan quality disappoints,
  # hardware.sane.brscan5.enable = true; is the proprietary fallback.
  hardware.sane.extraBackends = [ pkgs.sane-airscan ];

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  services.resolved.enable = false;

  # ✅ NSS config for .local resolution
  system.nssModules = [ pkgs.nssmdns ];
  environment.extraOutputsToInstall = [ "out" "lib" ];


  #####################  AUDIO & SPEECH TO TEXT ################
  # ✅ PipeWire + PulseAudio compatibility

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ✅ ALSA softvol config to limit volume to safe levels
  environment.etc."asound.conf".text = ''
    pcm.!default {
        type plug
        slave.pcm "softvol"
    }

    pcm.softvol {
        type softvol
        slave {
            pcm "hw:0"
        }
        control {
            name "Master"
            card 0
        }
        max_dB -10.0
    }
  '';

  #####################  AUDIO & SPEECH TO TEXT (end) ################




  programs.bash.interactiveShellInit = ''
    eval "$(direnv hook bash)"
  '';

  programs.nix-ld.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  environment.systemPackages = with pkgs; [

    # cloud tools
    terraform
    doctl               

    appimage-run


    # AI
    pkgs.ollama


    poppler-utils


    # video related
    obs-studio      # screen recording; obs-click-pop script adds click highlighting
    vlc



    bitwarden-cli
    gnupg           # This block is for 'pass' protected secrets
    pass
    pinentry-curses

    gh          # github client tools

    nodejs_22               # needed for GAS development  -- clasp .. gcloud etc
    google-cloud-sdk

    vlc


    yt-dlp      # generic video downloader

    graphviz    # plant uml support, etc

    cargo           # so we can do: cargo install --git https://github.com/asciinema/agg 
    asciinema

    direnv
    tree
    xclip
    pciutils     # lspci etc. -- not included by default on NixOS

    alsa-utils

    temurin-bin-17

    zip
    unzip

    nautilus

    dejavu_fonts
    liberation_ttf
    freefont_ttf
    pkgs.nerd-fonts.ubuntu-mono
    ubuntu-classic

    kdePackages.kolourpaint
    kdePackages.breeze-icons
    kdePackages.kconfig
    kdePackages.kiconthemes
    kdePackages.kio

    adwaita-icon-theme
    mate.mate-icon-theme

    python3
    python3Packages.venvShellHook

    # browsers / email
    protonmail-bridge
    firefox
    google-chrome
    chromium

    # internet utils
    curl
    wget
    dig

    git
    vim-full
    jq
    openssh
    xclip
    fastfetch
    networkmanagerapplet

    dropbox
    mate.mate-indicator-applet

    docker-compose

    brasero
    wireshark
    lsscsi
    libappindicator-gtk3

    xsane
    simple-scan

    libreoffice 

    mpv

    vim
    (vim-full.overrideAttrs (old: { gui = "gtk"; }))

    nssmdns

    # >>> nerd-dictation (speech2text) deps >>>
    gcc                # ensures libstdc++ is available
    stdenv.cc.cc.lib   # libgcc_s/libc runtime
    pulseaudio         # pactl / CLI tools
    sox                # mic testing & capture
    xdotool            # type into X
    # <<< end >>>
  ];




  environment.variables = {
    JAVA_HOME = "${pkgs.temurin-bin-17}";
    # Combine SANE's default with the C++ runtime libs; force wins the conflict.
    # This preserves scanners (/etc/sane-libs) and gives Vosk/nerd-dictation 
    # libstdc++ & friends, without nix-shell.
    #
    LD_LIBRARY_PATH = lib.mkForce "/etc/sane-libs:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.gcc.cc.lib}/lib";
  };

  systemd.services."systemd-tmpfiles-clean".startAt = "daily";

  services.journald = {
    storage = "persistent";
    rateLimitInterval = "30s";
    rateLimitBurst = 1000;
  };

  ################################
  # User service: warm Vosk model once after login (low priority)
  ################################

  systemd.user.services.talk-warmup = {
    description = "Warm Vosk/nerd-dictation model cache once after login";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 19;
      IOSchedulingClass = "idle";
      ExecStart = "${pkgs.bash}/bin/bash -lc '/home/chris/scripts/DEVENV/talk begin --timeout=1 --full-sentence --numbers-as-digits'";
      WorkingDirectory = "/home/chris";

    };
  };


  system.stateVersion = "24.05";
}

