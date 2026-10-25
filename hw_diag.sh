#!/usr/bin/env bash
# EqServers - Universal Bare-Metal Hardware Audit v2.0 (HP / Dell / Supermicro / Huawei)

# Auto-install lightweight missing diag tools silently if running on live OS
for pkg_cmd in "ipmitool:ipmitool" "ethtool:ethtool" "lspci:pciutils" "smartctl:smartmontools"; do
    bin="${pkg_cmd%%:*}"
    pkg="${pkg_cmd##*:}"
    if ! command -v "$bin" &>/dev/null; then
        if command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq "$pkg" &>/dev/null;
        elif command -v dnf &>/dev/null; then dnf install -y -q "$pkg" &>/dev/null;
        elif command -v yum &>/dev/null; then yum install -y -q "$pkg" &>/dev/null; fi
    fi
done

VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | head -n 1 | xargs)
MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -n 1 | xargs)
SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | head -n 1 | xargs)

echo "================================================================="
echo " EQSERVERS HARDWARE DIAGNOSTIC REPORT v2.0"
echo " Vendor : $VENDOR"
echo " Model  : $MODEL (S/N: $SERIAL)"
echo " Host   : $(hostname) | Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "================================================================="

echo -e "\n[1] CPU & RAM SUMMARY:"
lscpu | grep -E "^Model name:|^Socket\(s\):|^Core\(s\) per socket:|^Thread\(s\) per core:"
free -h | awk 'NR==1 || /Mem:/ || /Swap:/'
echo "Populated RAM DIMM Slots:"
dmidecode -t memory 2>/dev/null | awk '
  /Memory Device$/,/^$/ {
    if ($1 == "Size:" && $2 != "No" && $2 != "Installed") size=$2" "$3;
    if ($1 == "Locator:") loc=$2" "$3;
    if ($1 == "Type:" && $2 != "Unknown") type=$2;
    if ($1 == "Speed:" && $2 != "Unknown") speed=$2" "$3;
    if ($0 == "" && size != "") {
      printf "  - Slot: %-12s | Size: %-8s | Type: %-5s | Speed: %s\n", loc, size, type, speed;
      size=""; loc=""; type=""; speed="";
    }
  }'

echo -e "\n[2] NETWORK INTERFACES & PORT SPEED CHECK:"
for iface in $(ls /sys/class/net/ | grep -vE '^lo$|^docker|^veth|^br-|^virbr|^vnet|^tun|^tap'); do
    STATE=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null)
    MAC=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
    IP=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | paste -sd "," -)
    [ -z "$IP" ] && IP="No IPv4"
    if command -v ethtool &>/dev/null; then
        SPEED=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}')
        DUPLEX=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Duplex:/ {print $2}')
        LINK=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Link detected:/ {print $2}')
        printf "  - %-10s | Link: %-3s (%-4s) | Speed: %-10s | Duplex: %-4s | MAC: %s | IP: %s\n" "$iface" "${LINK:-N/A}" "$STATE" "${SPEED:-Unknown}" "${DUPLEX:-N/A}" "$MAC" "$IP"
    else
        SPEED=$(cat /sys/class/net/"$iface"/speed 2>/dev/null)
        printf "  - %-10s | State: %-4s | Speed: %-6s Mbps | MAC: %s | IP: %s\n" "$iface" "$STATE" "${SPEED:-N/A}" "$MAC" "$IP"
    fi
done

echo -e "\n[3] RAID CONTROLLER & ARRAY STATUS:"
echo ">>> PCIe Storage / RAID Controllers Detected (lspci):"
lspci 2>/dev/null | grep -iE "RAID|SCSI|SAS|SATA|Non-Volatile|Hewlett-Packard Company Smart Array|MegaRAID" | sed 's/^/  /'

if command -v ssacli &>/dev/null && lspci 2>/dev/null | grep -qi "Smart Array"; then
    echo ">>> HP Smart Array Status (ssacli):"
    ssacli ctrl all show status
    ssacli ctrl all show config | grep -E "logicaldrive|physicaldrive"
elif command -v storcli &>/dev/null || command -v storcli64 &>/dev/null || command -v perccli &>/dev/null; then
    CLI=$(command -v storcli || command -v storcli64 || command -v perccli)
    echo ">>> LSI / PERC Hardware RAID Status ($CLI):"
    $CLI /c0 show | grep -E "Product Name|Status|BBU|CacheVault|Virtual Drives|Physical Drives" -A 15
elif command -v megacli &>/dev/null || command -v MegaCli64 &>/dev/null; then
    MCLI=$(command -v megacli || command -v MegaCli64)
    echo ">>> MegaCLI RAID Status:"
    $MCLI -AdpAllInfo -aALL | grep -E "Product Name|Degraded|Failed Disks|Memory Size"
    $MCLI -PDList -aALL | grep -E "Enclosure Device ID|Slot Number|Inquiry Data|Firmware state|Media Error Count|Predictive Failure Count"
fi

if grep -q "md" /proc/mdstat 2>/dev/null; then
    echo ">>> Linux Software RAID (/proc/mdstat):"
    cat /proc/mdstat
fi

echo -e "\n[4] DISK SMART HEALTH (Reallocated, Pending, Uncorrectable, UDMA CRC, Wear):"
SMART_GREP="Device Model|Model Number|Product:|Serial Number|test result|SMART Health Status|Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error|Reported_Uncorrect|Media_Wearout|Percentage Used|Media and Data Integrity|Power_On_Hours|Grown_Defect|Elements in grown defect|Non-medium error"

# 1. Direct block devices (skip virtual RAID logical volumes if underlying drives are scanned below)
for disk in $(lsblk -dn -o NAME | grep -E '^sd|^nvme'); do
    echo "--- Block Device: /dev/$disk ($(lsblk -dn -o SIZE /dev/$disk)) ---"
    smartctl -i -H -A /dev/$disk | grep -E "$SMART_GREP"
done

# 2. Hidden drives behind MegaRAID / Dell PERC / Huawei / Supermicro LSI
MEGARAID_DEVS=$(smartctl --scan | grep "megaraid" | awk '{print $1, $2, $3}')
if [ -n "$MEGARAID_DEVS" ]; then
    echo ">>> Physical Disks Behind Hardware MegaRAID / PERC Controller:"
    while read -r dev flag type; do
        echo "--- Hardware RAID Disk ($type) ---"
        smartctl -i -H -A "$dev" "$flag" "$type" | grep -E "$SMART_GREP"
    done <<< "$MEGARAID_DEVS"
fi

# 3. Hidden drives behind HP Smart Array (cciss) - only runs if Smart Array PCIe card is present
if lspci 2>/dev/null | grep -qi "Smart Array" && [ -b /dev/sda ]; then
    echo ">>> Physical Disks Behind HP Smart Array Controller:"
    for i in {0..15}; do
        OUT=$(smartctl -i -H -A -d cciss,$i /dev/sda 2>/dev/null)
        if echo "$OUT" | grep -q -E "Device Model|Product:"; then
            echo "--- HP Smart Array Bay cciss,$i ---"
            echo "$OUT" | grep -E "$SMART_GREP"
        fi
    done
fi

echo -e "\n[5] UMC / ECC MEMORY, CPU MCE & DISK I/O KERNEL ERRORS:"
# Check EDAC memory controller counters
if ls /sys/devices/system/edac/mc/mc*/ce_count &>/dev/null; then
    CE=$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | awk '{s+=$1} END {print s}')
    UE=$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null | awk '{s+=$1} END {print s}')
    echo "  - EDAC RAM Error Counters : Correctable (CE) = ${CE:-0} | Uncorrectable (UE/UMC) = ${UE:-0}"
else
    echo "  - EDAC RAM Error Counters : Not exposed by kernel/BIOS"
fi

# Scan kernel ring buffer (dmesg) for UMC, MCE, ECC, I/O, and RAID errors
DMESG_ERRS=$(dmesg -T 2>/dev/null | grep -iE "UMC|Uncorrected|Hardware Error|MCE|EDAC|I/O error|medium error|blk_update_request|resetting link|SMART" | tail -n 15)
if [ -n "$DMESG_ERRS" ]; then
    echo "  [WARN] Recent Hardware/Disk Errors Found in dmesg:"
    echo "$DMESG_ERRS" | sed 's/^/    /'
else
    echo "  [OK] Zero UMC, ECC, MCE, or Disk I/O errors detected in dmesg."
fi

echo -e "\n[6] IPMI / iDRAC / iLO / iBMC SENSORS & SEL LOGS:"
if command -v ipmitool &>/dev/null; then
    modprobe ipmi_devintf &>/dev/null
    modprobe ipmi_si &>/dev/null
    echo ">>> Out-of-Band BMC IP:"
    ipmitool lan print 2>/dev/null | grep -E "IP Address Source|IP Address   " | sed 's/^/  /'
    echo ">>> Thermal & Power Status:"
    ipmitool sdr type Temperature 2>/dev/null | grep -vE "Disabled|ns" | sed 's/^/  /'
    ipmitool sdr type "Power Supply" 2>/dev/null | grep -v "ns" | sed 's/^/  /'
    echo ">>> Last 10 Hardware Event Logs (SEL):"
    ipmitool sel elist 2>/dev/null | tail -n 10 | sed 's/^/  /'
else
    echo "  ipmitool could not be installed or no BMC interface present."
fi
