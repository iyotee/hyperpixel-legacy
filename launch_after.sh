
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

echo "[1/4] Sauvegarde..."
sudo cp -a "$CONFIG" "$BACKUP"
echo "Backup : $BACKUP"

echo
echo "[2/4] Configuration..."

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
echo "[3/4] Vérification..."
sudo grep -A 8 '^\[LightDM\]' "$CONFIG"

echo
echo "[4/4] Redémarrage de LightDM..."
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
