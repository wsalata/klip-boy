#!/bin/bash
# Installs Klip-Boy on the printer's computer next to Klipper, Moonraker and Mainsail
# (Raspberry Pi OS, MainsailOS or another Debian-based system), or removes it again:
#
#   curl -fsSL https://raw.githubusercontent.com/wsalata/klip-boy/main/install.sh | bash
#   bash install.sh --uninstall
#
# With --boot-splash (Raspberry Pi) it also replaces the boot screen with the Klip-Boy logo:
#   curl -fsSL https://raw.githubusercontent.com/wsalata/klip-boy/main/install.sh | bash -s -- --boot-splash
#
# Run it as the user Klipper runs as (not root); it asks for sudo where needed. Updates then
# come through Moonraker's update manager, like Klipper's and Mainsail's.
set -euo pipefail

REPO=wsalata/klip-boy
DIR="$HOME/klip-boy"
DATA="$HOME/printer_data"
CONFIG_DIR="$DATA/config"
MOONRAKER_CONF="$CONFIG_DIR/moonraker.conf"
ASVC="$DATA/moonraker.asvc"
SERVICE=/etc/systemd/system/klip-boy.service
POLKIT_RULE=/etc/polkit-1/rules.d/50-klip-boy.rules
STATE_DIR=/var/lib/klip-boy
SECTION="[update_manager klip-boy]"
THEME_DIR=/usr/share/plymouth/themes/klip-boy
EDID_HOOK=/etc/initramfs-tools/hooks/klip-boy-edid
SPLASH_STATE="$STATE_DIR/boot-splash"
USER=${USER:-$(id -un)}

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die() {
	printf '\033[1;31m%s\033[0m\n' "$*" >&2
	exit 1
}

[ "$(id -u)" -ne 0 ] || die "Run this as the user Klipper runs as, not as root."
[ -d "$DATA" ] || die "$DATA not found: install Klipper and Moonraker first (e.g. with KIAUH)."
command -v systemctl >/dev/null || die "systemd is required."

# Removes our section from moonraker.conf (up to the next section)
remove_update_section() {
	[ -f "$MOONRAKER_CONF" ] || return 0
	python3 - "$MOONRAKER_CONF" "$SECTION" <<'EOF'
import sys
path, section = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, skip = [], False
for line in lines:
    if line.strip().startswith("["):
        skip = line.strip() == section
    if not skip:
        out.append(line)
text = "\n".join(out).rstrip("\n") + "\n"
open(path, "w").write(text)
EOF
}

# The Raspberry Pi's boot partition (cmdline.txt, config.txt), empty elsewhere
boot_dir() {
	for d in /boot/firmware /boot; do
		if [ -f "$d/cmdline.txt" ] && [ -f "$d/config.txt" ]; then
			echo "$d"
			return
		fi
	done
}

# Edits cmdline.txt and config.txt for the boot splash ("apply") or undoes exactly what was
# added ("revert"), recording the changes in $SPLASH_STATE. Safe to run repeatedly.
edit_boot_files() {
	sudo python3 - "$1" "$2" "$SPLASH_STATE" "${3:-}" <<'EOF'
import os, shutil, sys

boot, mode, state_path, theme = sys.argv[1:5]
cmdline, config = os.path.join(boot, "cmdline.txt"), os.path.join(boot, "config.txt")
# No kernel messages, logos or blinking cursor on the screen; Plymouth shows the splash
SPLASH = ["quiet", "splash", "loglevel=3", "logo.nologo", "vt.global_cursor_default=0",
          "plymouth.ignore-serial-consoles"]
CONFIG_BLOCK = "\n\n[all]\n# Klip-Boy boot splash: no rainbow square\ndisable_splash=1\n"

state = {}
if os.path.exists(state_path):
    state = dict(line.split("=", 1) for line in open(state_path).read().splitlines() if "=" in line)
tokens = open(cmdline).read().split()
config_text = open(config).read()

if mode == "apply":
    for path in (cmdline, config):
        if not os.path.exists(path + ".klip-boy.bak"):
            shutil.copy2(path, path + ".klip-boy.bak")
    added = state.get("cmdline_added", "").split()
    # Boot messages go to tty3, out of sight
    if "console=tty1" in tokens:
        tokens = ["console=tty3" if t == "console=tty1" else t for t in tokens]
        state["console"] = "tty1"
    for t in SPLASH:
        if t not in tokens:
            tokens.append(t)
            added.append(t)
    state["cmdline_added"] = " ".join(dict.fromkeys(added))
    if not any(line.strip() == "disable_splash=1" for line in config_text.splitlines()):
        config_text = config_text.rstrip("\n") + CONFIG_BLOCK
        state["config_added"] = "1"
    if theme and "theme" not in state:
        state["theme"] = theme
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    open(state_path, "w").write("".join(f"{k}={v}\n" for k, v in state.items()))
else:
    added = set(state.get("cmdline_added", "").split())
    tokens = [t for t in tokens if t not in added]
    if state.get("console") == "tty1":
        tokens = ["console=tty1" if t == "console=tty3" else t for t in tokens]
    if state.get("config_added") == "1":
        config_text = config_text.replace(CONFIG_BLOCK, "\n")

open(cmdline, "w").write(" ".join(tokens) + "\n")
open(config, "w").write(config_text)
EOF
}

# Plymouth with the Klip-Boy theme, shown from early boot until the panel takes over
install_boot_splash() {
	local boot
	boot=$(boot_dir)
	if [ -z "$boot" ]; then
		warn "No Raspberry Pi boot partition (cmdline.txt, config.txt) found: skipping the boot splash."
		return
	fi
	say "Installing the boot splash"
	sudo apt-get install -y -qq plymouth
	sudo mkdir -p "$THEME_DIR"
	# From a copy of the repository next to this script (testing before a release), else from GitHub
	local here=""
	[ -f "${BASH_SOURCE[0]:-}" ] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packaging/plymouth"
	for f in klip-boy.plymouth klip-boy.script logo.png; do
		if [ -n "$here" ] && [ -f "$here/$f" ]; then
			sudo cp "$here/$f" "$THEME_DIR/$f"
		else
			sudo curl -fsSL -o "$THEME_DIR/$f" "https://raw.githubusercontent.com/$REPO/$VERSION/packaging/plymouth/$f"
		fi
	done
	local previous
	previous=$(plymouth-set-default-theme 2>/dev/null || true)
	[ "$previous" = klip-boy ] && previous=""
	# Plymouth puts the graphics driver into the initramfs, where it starts before the root
	# filesystem: a corrected EDID (drm.edid_firmware=, see README "Troubleshooting") must be
	# there too, or the screen stays black
	if compgen -G "/lib/firmware/edid/*.bin" >/dev/null; then
		sudo tee "$EDID_HOOK" >/dev/null <<'EOF'
#!/bin/sh
# Klip-Boy: corrected screen EDIDs (/lib/firmware/edid) for the graphics driver in the initramfs
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
for f in /lib/firmware/edid/*.bin; do
	# copy_file returns 1 when another hook has already added the file: that is fine
	[ -e "$f" ] && copy_file firmware "$f" || true
done
exit 0
EOF
		sudo chmod 755 "$EDID_HOOK"
	fi
	# Also rebuilds the initramfs, so the splash appears before the root filesystem is mounted
	sudo plymouth-set-default-theme -R klip-boy
	edit_boot_files "$boot" apply "$previous"
	say "Boot splash installed; backups: $boot/cmdline.txt.klip-boy.bak, $boot/config.txt.klip-boy.bak"
}

remove_boot_splash() {
	[ -e "$SPLASH_STATE" ] || return 0
	local boot previous
	boot=$(boot_dir)
	previous=$(sed -n 's/^theme=//p' "$SPLASH_STATE")
	[ -n "$boot" ] && edit_boot_files "$boot" revert
	if [ -n "$previous" ] && [ -d "/usr/share/plymouth/themes/$previous" ]; then
		sudo plymouth-set-default-theme -R "$previous" || true
	fi
	sudo rm -rf "$THEME_DIR"
	say "Boot splash removed"
}

uninstall() {
	say "Removing Klip-Boy"
	remove_boot_splash
	sudo systemctl disable --now klip-boy.service 2>/dev/null || true
	sudo rm -f "$SERVICE" "$POLKIT_RULE"
	sudo systemctl daemon-reload
	remove_update_section
	[ -f "$ASVC" ] && sed -i '/^klip-boy$/d' "$ASVC"
	rm -rf "$DIR"
	if [ -e "$STATE_DIR/klipperscreen-was-enabled" ]; then
		sudo systemctl enable --now KlipperScreen.service || true
		say "KlipperScreen enabled again"
	fi
	sudo rm -rf "$STATE_DIR"
	sudo systemctl restart moonraker.service || true
	say "Done. The panel settings stay in $CONFIG_DIR/klip-boy.toml."
}

BOOT_SPLASH=0
for arg in "$@"; do
	case "$arg" in
	--uninstall)
		uninstall
		exit 0
		;;
	--boot-splash) BOOT_SPLASH=1 ;;
	*) die "Unknown option: $arg (use --boot-splash or --uninstall)" ;;
	esac
done

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
arm64 | aarch64) ASSET=klip-boy-linux-arm64 ;;
armhf | armv7l) ASSET=klip-boy-linux-armhf ;;
amd64 | x86_64) ASSET=klip-boy-linux-amd64 ;;
*) die "Unsupported system architecture: $(uname -m)" ;;
esac

# Moonraker refuses to update an application that lives inside a git repository
if [ -d "$DIR/.git" ]; then
	die "$DIR is a git repository (the source code?). Move it away and run the installer again."
fi

say "Installing the libraries the panel needs"
sudo apt-get update -qq
sudo apt-get install -y -qq libinput10 libxkbcommon0 libudev1 libfontconfig1 fonts-dejavu-core

say "Downloading the latest release"
VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
	python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')
mkdir -p "$DIR"
curl -fL --progress-bar -o "$DIR/$ASSET.tmp" "https://github.com/$REPO/releases/download/$VERSION/$ASSET"
chmod 755 "$DIR/$ASSET.tmp"
mv "$DIR/$ASSET.tmp" "$DIR/$ASSET"
# Tells Moonraker's update manager what is installed (it rewrites the version on updates)
cat >"$DIR/release_info.json" <<EOF
{
  "project_name": "klip-boy",
  "project_owner": "${REPO%%/*}",
  "version": "$VERSION",
  "asset_name": "$ASSET"
}
EOF
say "Klip-Boy $VERSION installed in $DIR"

# Settings the panel cannot change itself; editable from Mainsail like printer.cfg
if [ ! -e "$CONFIG_DIR/klip-boy.env" ]; then
	cat >"$CONFIG_DIR/klip-boy.env" <<'EOF'
# Klip-Boy: settings applied when the panel starts. Restart it after changes
# (Mainsail: the power menu, or `sudo systemctl restart klip-boy`).
# Everything else is set on the panel (System -> Panel settings) and saved in klip-boy.toml.

# Screen rotation: 0, 90, 180 or 270
#SLINT_KMS_ROTATION=180

# UI scale; by default computed from the screen size (800x480 = 1)
#SLINT_SCALE_FACTOR=1.25
EOF
fi

say "Installing the klip-boy service"
sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=Klip-Boy touch screen panel
Documentation=https://github.com/$REPO
After=moonraker.service
Wants=moonraker.service
# Both draw directly on the screen
Conflicts=KlipperScreen.service
# With the boot splash (--boot-splash) the panel takes the screen over from Plymouth
Before=plymouth-quit.service plymouth-quit-wait.service

[Service]
Type=simple
User=$USER
SupplementaryGroups=video input render
Environment=KLIP_BOY_CONFIG=$CONFIG_DIR/klip-boy.toml
Environment=KLIP_BOY_MANAGE_NETWORK=1
EnvironmentFile=-/etc/default/locale
EnvironmentFile=-$CONFIG_DIR/klip-boy.env
# Ends the boot splash but keeps the logo on screen until the panel's first frame;
# as root ("+"), the only user Plymouth listens to, and ignored without Plymouth ("-")
ExecStartPre=-+/usr/bin/plymouth quit --retain-splash
ExecStart=$DIR/$ASSET
Restart=always
RestartSec=3
# Klipper must never wait for the screen
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF

# Network screen: lets this user change NetworkManager's settings without a login session
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
	sudo tee "$POLKIT_RULE" >/dev/null <<EOF
// Klip-Boy (running as $USER) may change NetworkManager settings from the panel
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 && subject.user == "$USER") {
        return polkit.Result.YES;
    }
});
EOF
else
	warn "NetworkManager is not running: the panel's Network screen will only show the status."
fi

# Updates from Mainsail (and the panel's Updates screen), restarts through Moonraker
if [ -f "$MOONRAKER_CONF" ] && ! grep -qxF "$SECTION" "$MOONRAKER_CONF"; then
	cat >>"$MOONRAKER_CONF" <<EOF

$SECTION
type: executable
channel: stable
repo: $REPO
path: $DIR
managed_services: klip-boy
EOF
fi
if [ -f "$ASVC" ] && ! grep -qx klip-boy "$ASVC"; then
	echo klip-boy >>"$ASVC"
fi

# Only one program can draw on the screen; --uninstall brings KlipperScreen back
if systemctl is-enabled --quiet KlipperScreen.service 2>/dev/null; then
	sudo mkdir -p "$STATE_DIR"
	sudo touch "$STATE_DIR/klipperscreen-was-enabled"
	sudo systemctl disable --now KlipperScreen.service
	say "KlipperScreen disabled"
fi

if [ "$BOOT_SPLASH" = 1 ]; then
	install_boot_splash
fi

sudo systemctl daemon-reload
sudo systemctl enable klip-boy.service
sudo systemctl restart moonraker.service
sudo systemctl restart klip-boy.service
say "Done. Klip-Boy is running; updates appear in Mainsail's update manager."
