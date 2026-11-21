#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/lightdm/lightdm.conf"
BACKUP="${CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"

echo "========== CORRECTION LIGHTDM / FRAMEBUFFER =========="

if [[ ! -f "$CONFIG" ]]; then
    echo "ERREUR : $CONFIG introuvable."
    exit 1
fi

if ! grep -q '^\[LightDM\]' "$CONFIG"; then
    echo "ERREUR : section [LightDM] introuvable."
    exit 1
fi

echo "[1/5] Sauvegarde..."
sudo cp -a "$CONFIG" "$BACKUP"
echo "Backup : $BACKUP"

echo
echo "[2/5] Configuration LightDM..."

sudo python3 - "$CONFIG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text()
lines = content.splitlines()

section = None
found_section = False
found_option = False
output = []

for line in lines:
    match = re.match(r'^\s*\[([^]]+)\]\s*$', line)

    if match:
        if section == "LightDM" and not found_option:
            output.append("logind-check-graphical=false")

        section = match.group(1)
        if section == "LightDM":
            found_section = True

        output.append(line)
        continue

    if section == "LightDM" and re.match(
        r'^\s*logind-check-graphical\s*=',
        line
    ):
        output.append("logind-check-graphical=false")
        found_option = True
    else:
        output.append(line)

if section == "LightDM" and not found_option:
    output.append("logind-check-graphical=false")

if not found_section:
    raise SystemExit("Section [LightDM] not found. No change made.")

path.write_text("\n".join(output) + "\n")
PY

echo
echo "[3/5] Configuration rotation tactile HyperPixel 180°..."

sudo mkdir -p /etc/X11/xorg.conf.d

sudo tee /etc/X11/xorg.conf.d/99-hyperpixel-touch.conf >/dev/null <<'EOF'
Section "InputClass"
    Identifier "HyperPixel Touch Rotation"
    MatchProduct "EP0110M09"
    Option "TransformationMatrix" "-1 0 1 0 -1 1 0 0 1"
EndSection
EOF

echo "Rotation tactile 180° enregistrée."

echo
echo "[4/5] Application immédiate..."

TOUCH_ID=$(DISPLAY=:0 xinput list --id-only "11-0048 EP0110M09" 2>/dev/null || true)

if [[ -n "${TOUCH_ID}" ]]; then
    DISPLAY=:0 xinput set-prop "$TOUCH_ID" \
        "Coordinate Transformation Matrix" \
        -1 0 1 \
        0 -1 1 \
        0 0 1 || true

    echo "Rotation appliquée au périphérique ID $TOUCH_ID"
else
    echo "Touchscreen non trouvé dans la session X. La rotation sera appliquée au prochain démarrage."
fi

echo
echo "[5/5] Vérification puis redémarrage de LightDM..."

sudo grep -A 8 '^\[LightDM\]' "$CONFIG"

echo
sudo systemctl restart lightdm

sleep 5

echo
echo "========== ETAT LIGHTDM =========="
sudo systemctl status lightdm --no-pager -l

echo
echo "========== PROCESSUS GRAPHIQUES =========="
ps -ef | grep -E 'lightdm|Xorg|pi-greeter|startx-rpd' | grep -v grep || true

echo
echo "========== LOG LIGHTDM =========="
sudo tail -80 /var/log/lightdm/lightdm.log

echo
echo "========== FIN =========="