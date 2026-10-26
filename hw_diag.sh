#!/usr/bin/env bash
# EqServers - Linux Hardware Diagnostic & Rescue Audit v2.3

# Ensure script is run as root for full SMART and hardware access
if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: Please run this script as root (sudo)."
  exit 1
fi

# Detect OS Details
OS_NAME="Unknown Linux"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$PRETTY_NAME"
elif [ -f /etc/redhat-release ]; then
    OS_NAME=$(cat /etc/redhat-release)
fi
KERNEL_VER=$(uname -r)
ARCH=$(uname -m)
UPTIME_STR=$(uptime -p 2>/dev/null || uptime)

# Detect Vendor / Model / Serial
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")
SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "Unknown")

echo "================================================================="
echo " EQSERVERS LINUX HARDWARE DIAGNOSTIC REPORT v2.3"
echo " Vendor : $VENDOR"
echo " Model  : $MODEL (S/N: $SERIAL)"
echo " OS     : $OS_NAME ($ARCH) | Kernel: $KERNEL_VER"
echo " Host   : $(hostname) | Uptime: $UPTIME_STR"
echo " Date   : $(date -u '+%Y-%m-%d %H:%M') UTC"
echo "================================================================="

echo -e "\n[1] CPU & PHYSICAL RAM SUMMARY:"
CPU_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:\s*//')
CPU_CORES=$(lscpu | grep "^Core(s) per socket:" | awk '{print $4}')
CPU_SOCKETS=$(lscpu | grep "^Socket(s):" | awk '{print $2}')
TOTAL_CORES=$((CPU_CORES * CPU_SOCKETS))
TOTAL_THREADS=$(lscpu | grep "^CPU(s):" | head -n 1 | awk '{print $2}')
echo "  CPU: $CPU_MODEL"
echo "  Cores / Threads: $TOTAL_CORES Cores / $TOTAL_THREADS Threads"

TOTAL_RAM=$(free -h | awk '/Mem:/ {print $2}')
FREE_RAM=$(free -h | awk '/Mem:/ {print $4}')
echo "  Memory: Total = $TOTAL_RAM | Free = $FREE_RAM"

if command -v dmidecode &>/dev/null; then
    echo "  Populated RAM DIMM Slots:"
    dmidecode -t memory 2>/dev/null | awk -F': ' '
    /Memory Device$/ {
        if (sz != "" && sz !~ /No Module|Not Installed/) {
            printf "    - Slot: %-12s | Size: %-8s | Speed: %-10s | Part: %s\n", loc, sz, spd, prt
        }
        sz=""; loc=""; spd=""; prt=""
    }
    /^[[:space:]]*Locator:/ {loc=$2}
    /^[[:space:]]*Size:/ {sz=$2}
    /^[[:space:]]*Speed:/ {spd=$2}
    /^[[:space:]]*Part Number:/ {prt=$2}
    END {
        if (sz != "" && sz !~ /No Module|Not Installed/) {
            printf "    - Slot: %-12s | Size: %-8s | Speed: %-10s | Part: %s\n", loc, sz, spd, prt
        }
    }'
fi

echo -e "\n[2] NETWORK INTERFACES & PORT SPEED CHECK:"
for nic in /sys/class/net/*; do
    iface=$(basename "$nic")
    if [ "$iface" = "lo" ]; then continue; fi
    status=$(cat "$nic/operstate" 2>/dev/null)
    if [ "$status" = "up" ]; then
        speed=$(cat "$nic/speed" 2>/dev/null)
        if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            speed_str="${speed} Mbps"
        else
            speed_str="Unknown/Virtual"
        fi
        mac=$(cat "$nic/address" 2>/dev/null)
        ip_addr=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | tr '\n' ' ')
        echo "  - $iface | Status: Up | Speed: $speed_str | MAC: $mac | IP: ${ip_addr:-No IPv4}"
    fi
done

echo -e "\n[3] STORAGE CONTROLLERS & PHYSICAL DISK HEALTH (SMART):"
if command -v lspci &>/dev/null; then
    echo ">>> Storage / RAID Controllers:"
    lspci | grep -iE 'raid|storage|sata|nvme|sas|scsi' | sed 's/^/  - /'
fi

if command -v smartctl &>/dev/null; then
    echo ">>> Physical Disks & SMART Health:"
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n1; do
        if [ -b "$disk" ]; then
            model=$(smartctl -i "$disk" 2>/dev/null | grep -iE "Device Model:|Model Number:|Product:" | head -n 1 | cut -d: -f2 | xargs)
            [ -z "$model" ] && model="Unknown Model"
            serial=$(smartctl -i "$disk" 2>/dev/null | grep -i "Serial Number:" | cut -d: -f2 | xargs)
            health=$(smartctl -H "$disk" 2>/dev/null | grep -iE "overall-health|SMART Health Status" | cut -d: -f2 | xargs)
            [ -z "$health" ] && health="N/A"
            temp=$(smartctl -A "$disk" 2>/dev/null | awk '/194 Temperature_Celsius|190 Airflow_Temperature_Cel/ {print $10; exit} /Temperature:/ {print $2; exit}')
            poh=$(smartctl -A "$disk" 2>/dev/null | awk '/9 Power_On_Hours/ {print $10; exit} /Power On Hours:/ {print $4; exit}')
            reallocated=$(smartctl -A "$disk" 2>/dev/null | awk '/5 Reallocated_Sector_Ct/ {print $10; exit}')
            pending=$(smartctl -A "$disk" 2>/dev/null | awk '/197 Current_Pending_Sector/ {print $10; exit}')

            echo "  --- Disk: $disk ($model) ---"
            echo "      Serial: ${serial:-N/A} | SMART Health: $health | Temp: ${temp:-N/A} C | PowerOnHours: ${poh:-N/A}"
            if [ -n "$reallocated" ] || [ -n "$pending" ]; then
                echo "      Reallocated Sectors: ${reallocated:-0} | Pending Sectors: ${pending:-0}"
            fi
        fi
    done
else
    echo "  [WARN] smartctl not found. Install smartmontools for full disk SMART health."
fi

echo -e "\n[4] KERNEL & HARDWARE (MCE / EXT4 / SCSI) SYSTEM LOGS (Last 24h):"
if command -v journalctl &>/dev/null; then
    HW_LOGS=$(journalctl -k --since "24 hours ago" -p 3..4 --no-pager 2>/dev/null | tail -n 10)
    if [ -n "$HW_LOGS" ]; then
        echo "  [WARN] Recent Kernel Errors / Hardware Faults Detected:"
        echo "$HW_LOGS" | sed 's/^/    /'
    else
        echo "  [OK] Zero critical kernel/hardware errors in the last 24 hours."
    fi
else
    echo "  [SKIP] journalctl unavailable."
fi
echo "================================================================="
