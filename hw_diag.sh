#!/usr/bin/env bash
# =====================================================================
# EqServers - Universal Bare-Metal Hardware Audit v2.2 (Production)
# HP / Dell / Supermicro / Huawei — Read-Only by Default
# Zero package installs or kernel module changes unless --install is passed
# =====================================================================

PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin:/opt/MegaRAID/storcli:/opt/MegaRAID/MegaCli"

ALLOW_INSTALL=0
if [ "${1:-}" = "--install" ]; then
    ALLOW_INSTALL=1
fi

# Optional package install ONLY when explicitly requested (e.g. Rescue Mode)
if [ "$ALLOW_INSTALL" -eq 1 ]; then
    for pkg_cmd in "ipmitool:ipmitool" "ethtool:ethtool" "lspci:pciutils" "smartctl:smartmontools"; do
        bin="${pkg_cmd%%:*}"
        pkg="${pkg_cmd##*:}"
        if ! command -v "$bin" &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq "$pkg" &>/dev/null
            elif command -v dnf &>/dev/null; then
                dnf install -y -q "$pkg" &>/dev/null
            elif command -v yum &>/dev/null; then yum install -y -q "$pkg" &>/dev/null; fi
        fi
    done
fi

# System & OS Metadata (DMI with sysfs read-only fallback)
VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | head -n 1 | xargs)
[ -z "$VENDOR" ] && [ -r /sys/class/dmi/id/sys_vendor ] && VENDOR=$(tr -d '\0' </sys/class/dmi/id/sys_vendor | xargs)

MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -n 1 | xargs)
[ -z "$MODEL" ] && [ -r /sys/class/dmi/id/product_name ] && MODEL=$(tr -d '\0' </sys/class/dmi/id/product_name | xargs)

SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | head -n 1 | xargs)
[ -z "$SERIAL" ] && [ -r /sys/class/dmi/id/product_serial ] && SERIAL=$(tr -d '\0' </sys/class/dmi/id/product_serial | xargs)

OS_INFO=$(grep -s "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
[ -z "$OS_INFO" ] && OS_INFO=$(uname -sr)
KERNEL_INFO=$(uname -r)

echo "================================================================="
echo " EQSERVERS HARDWARE DIAGNOSTIC REPORT v2.2"
echo " Vendor : ${VENDOR:-Unknown}"
echo " Model  : ${MODEL:-Unknown} (S/N: ${SERIAL:-N/A})"
echo " OS     : $OS_INFO | Kernel: $KERNEL_INFO"
echo " Host   : $(hostname) | Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "================================================================="

echo -e "\n[1] CPU & RAM SUMMARY:"
if command -v lscpu &>/dev/null; then
    lscpu | grep -E "^Model name:|^Socket\(s\):|^Core\(s\) per socket:|^Thread\(s\) per core:"
else
    grep -m 1 "model name" /proc/cpuinfo
fi
free -h | awk 'NR==1 || /Mem:/ || /Swap:/'
echo "Populated RAM DIMM Slots:"
if command -v dmidecode &>/dev/null; then
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
else
    echo "  [SKIP] dmidecode not installed."
fi

echo -e "\n[2] NETWORK INTERFACES & PORT SPEED CHECK:"
for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    iface="${path##*/}"
    case "$iface" in
        lo | docker* | veth* | br-* | virbr* | vnet* | tun* | tap*) continue ;;
    esac
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
PCI_STORAGE=""
if command -v lspci &>/dev/null; then
    PCI_STORAGE=$(lspci 2>/dev/null | grep -iE "RAID|SCSI|SAS|SATA|Non-Volatile|Smart Array|MegaRAID")
    if [ -n "$PCI_STORAGE" ]; then
        while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$PCI_STORAGE"
    else
        echo "  None detected."
    fi
else
    echo "  [SKIP] lspci not installed."
fi

RAID_CLI_FOUND=0
if (command -v ssacli &>/dev/null || command -v hpssacli &>/dev/null) && echo "$PCI_STORAGE" | grep -qi "Smart Array"; then
    HCLI=$(command -v ssacli || command -v hpssacli)
    RAID_CLI_FOUND=1
    echo ">>> HP Smart Array Status ($HCLI):"
    "$HCLI" ctrl all show status 2>/dev/null
    "$HCLI" ctrl all show config 2>/dev/null | grep -E "array|logicaldrive|physicaldrive"
elif command -v storcli &>/dev/null || command -v storcli64 &>/dev/null || command -v perccli &>/dev/null; then
    CLI=$(command -v storcli || command -v storcli64 || command -v perccli)
    RAID_CLI_FOUND=1
    echo ">>> LSI / PERC Hardware RAID Status ($CLI):"
    "$CLI" /c0 show 2>/dev/null | grep -E "Product Name|Status|BBU|CacheVault|Virtual Drives|Physical Drives" -A 15
elif command -v megacli &>/dev/null || command -v MegaCli64 &>/dev/null; then
    MCLI=$(command -v megacli || command -v MegaCli64)
    RAID_CLI_FOUND=1
    echo ">>> MegaCLI RAID Status:"
    "$MCLI" -AdpAllInfo -aALL 2>/dev/null | grep -E "Product Name|Degraded|Failed Disks|Memory Size"
    "$MCLI" -PDList -aALL 2>/dev/null | grep -E "Enclosure Device ID|Slot Number|Inquiry Data|Firmware state|Media Error Count|Predictive Failure Count"
elif command -v arcconf &>/dev/null; then
    RAID_CLI_FOUND=1
    echo ">>> Adaptec RAID Status (arcconf):"
    arcconf getconfig 1 2>/dev/null | grep -E "Controller Status|Status of logical device|State|S.M.A.R.T."
fi

if [ "$RAID_CLI_FOUND" -eq 0 ] && echo "$PCI_STORAGE" | grep -qiE "RAID|Smart Array|MegaRAID|PERC|Adaptec"; then
    echo "  [WARN] Hardware RAID controller detected but no vendor CLI (ssacli/storcli/megacli) is installed."
    echo "         Check SMART passthrough below or verify member drives via HP iLO / Dell iDRAC."
fi

if grep -q "md" /proc/mdstat 2>/dev/null; then
    echo ">>> Linux Software RAID (/proc/mdstat):"
    cat /proc/mdstat
fi

echo -e "\n[4] DISK SMART HEALTH (Reallocated, Pending, Uncorrectable, UDMA CRC, SSD Wear):"
SMART_GREP="Device Model|Model Number|Product:|Serial Number|test result|SMART Health Status|Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error|Reported_Uncorrect|Command_Timeout|Wear_Leveling_Count|Used_Rsvd_Blk|Runtime_Bad_Block|Media_Wearout|Percentage Used|Media and Data Integrity|Power_On_Hours|Grown_Defect|Elements in grown defect|Non-medium error"

if command -v smartctl &>/dev/null; then
    for disk in $(lsblk -dn -o NAME 2>/dev/null | grep -E '^sd|^nvme'); do
        echo "--- Block Device: /dev/$disk ($(lsblk -dn -o SIZE "/dev/$disk" 2>/dev/null)) ---"
        smartctl -i -H -A "/dev/$disk" 2>/dev/null | grep -E "$SMART_GREP"
    done

    MEGARAID_DEVS=$(smartctl --scan 2>/dev/null | grep "megaraid" | awk '{print $1, $2, $3}')
    if [ -n "$MEGARAID_DEVS" ]; then
        echo ">>> Physical Disks Behind Hardware MegaRAID / PERC Controller:"
        while read -r dev flag type; do
            echo "--- Hardware RAID Disk ($type) ---"
            smartctl -i -H -A "$dev" "$flag" "$type" 2>/dev/null | grep -E "$SMART_GREP"
        done <<<"$MEGARAID_DEVS"
    fi

    if echo "$PCI_STORAGE" | grep -qi "Smart Array" && [ -b /dev/sda ]; then
        echo ">>> Physical Disks Behind HP Smart Array Controller:"
        for i in {0..15}; do
            OUT=$(smartctl -i -H -A -d "cciss,$i" /dev/sda 2>/dev/null)
            if echo "$OUT" | grep -q -E "Device Model|Product:"; then
                echo "--- HP Smart Array Bay cciss,$i ---"
                echo "$OUT" | grep -E "$SMART_GREP"
            fi
        done
    fi
else
    echo "  [SKIP] smartctl is not installed (read-only mode: zero packages installed)."
fi

echo -e "\n[5] MEMORY (ECC/UMC/MCE) & DISK (UNC/ICRC/IO) KERNEL ERRORS:"
if ls /sys/devices/system/edac/mc/mc*/ce_count &>/dev/null; then
    CE=$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | awk '{s+=$1} END {print s}')
    UE=$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null | awk '{s+=$1} END {print s}')
    echo "  - EDAC RAM Error Counters : Correctable (CE) = ${CE:-0} | Uncorrectable (UE/UMC) = ${UE:-0}"
    for ch in /sys/devices/system/edac/mc/mc*/csrow*/ch*_ce_count; do
        [ -f "$ch" ] || continue
        CNT=$(cat "$ch" 2>/dev/null)
        if [ "${CNT:-0}" -gt 0 ]; then
            LBL=$(cat "${ch%_ce_count}_dimm_label" 2>/dev/null)
            echo "    [!] RAM Errors on Channel ($LBL): $CNT correctable errors"
        fi
    done
else
    echo "  - EDAC RAM Error Counters : Not exposed by kernel/BIOS"
fi

DMESG_RAW=$(dmesg -T 2>/dev/null || dmesg 2>/dev/null)
DMESG_ERRS=$(echo "$DMESG_RAW" | grep -iE "UMC|Uncorrected|Hardware Error|mce:|EDAC.*(CE|UE|error)|I/O error|medium error|blk_update_request|critical medium|error: \{.*(UNC|ICRC|ABRT)|resetting link" | grep -vE "EDAC MC: Ver|Giving out device" | tail -n 15)
if [ -n "$DMESG_ERRS" ]; then
    echo "  [WARN] Hardware / Memory / Disk Errors Found in dmesg:"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$DMESG_ERRS"
else
    echo "  [OK] Zero Memory (ECC/UMC/MCE) or Disk (UNC/ICRC/I/O) errors in dmesg."
fi

echo -e "\n[6] IPMI / iDRAC / iLO / iBMC SENSORS & SEL LOGS:"
echo ">>> CMOS / System Battery & RTC Status:"
if echo "$DMESG_RAW" | grep -qiE "rtc.*invalid|rtc.*fail|cmos.*error|cmos.*bad"; then
    echo "  [WARN] Kernel dmesg reports RTC/CMOS error!"
else
    RTC_TIME=$(cat /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/time 2>/dev/null | tr "\n" " ")
    echo "  [OK] Linux Hardware RTC Clock valid (${RTC_TIME:-Active})"
fi

if command -v ipmitool &>/dev/null; then
    if [ "$ALLOW_INSTALL" -eq 1 ]; then
        modprobe ipmi_devintf &>/dev/null
        modprobe ipmi_si &>/dev/null
    fi
    if [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ] || [ -e /dev/ipmidev/0 ]; then
        echo ">>> Out-of-Band BMC IP:"
        ipmitool lan print 2>/dev/null | grep -E "IP Address Source|IP Address   " | sed 's/^/  /'
        echo ">>> Thermal & Power Status:"
        ipmitool sdr type Temperature 2>/dev/null | grep -vE "Disabled|ns" | sed 's/^/  /'
        ipmitool sdr type "Power Supply" 2>/dev/null | grep -v "ns" | sed 's/^/  /'
        BATT_SDR=$(ipmitool sdr type Battery 2>/dev/null)
        if [ -n "$BATT_SDR" ]; then
            echo ">>> Battery Sensors:"
            while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$BATT_SDR"
        fi
        BATT_SEL=$(ipmitool sel elist 2>/dev/null | grep -iE "battery|cmos")
        if [ -n "$BATT_SEL" ]; then
            echo "  [WARN] IPMI SEL Battery/CMOS Events Found:"
            echo "$BATT_SEL" | tail -n 5 | sed 's/^/    /'
        else
            echo "  [OK] Zero CMOS/Battery failure events in IPMI SEL history."
        fi
        echo ">>> Last 10 Hardware Event Logs (SEL):"
        ipmitool sel elist 2>/dev/null | tail -n 10 | sed 's/^/  /'
    else
        echo "  [INFO] /dev/ipmi0 interface not loaded (read-only mode: kernel modules untouched)."
    fi
else
    echo "  [SKIP] ipmitool is not installed (read-only mode: zero packages installed)."
fi

echo "================================================================="
