#!/usr/bin/env bash
# EqServers - Universal Bare-Metal Hardware Audit (HP / Dell / Supermicro / Huawei)

VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | head -n 1)
MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -n 1)
SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | head -n 1)

echo "================================================================="
echo " EQSERVERS HARDWARE DIAGNOSTIC REPORT"
echo " Vendor : $VENDOR"
echo " Model  : $MODEL (S/N: $SERIAL)"
echo " Host   : $(hostname) | Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "================================================================="

echo -e "\n[1] CPU & RAM SUMMARY:"
lscpu | grep -E "Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core"
free -h | awk 'NR==1 || /Mem:/ || /Swap:/'
echo "Populated RAM Slots:"
dmidecode -t memory 2>/dev/null | grep -E "Size: [0-9]+|Locator:|Speed: [0-9]+" | paste - - - | sed 's/\t/ | /g' | grep -v "No Module Installed"

echo -e "\n[2] HARDWARE & SOFTWARE RAID STATUS:"
if command -v ssacli &>/dev/null && [[ "$VENDOR" =~ (HP|HPE|Hewlett) ]]; then
    echo ">>> Detected HP Smart Array - Running ssacli:"
    ssacli ctrl all show status
    ssacli ctrl all show config | grep -E "logicaldrive|physicaldrive"
elif command -v storcli &>/dev/null || command -v storcli64 &>/dev/null || command -v perccli &>/dev/null; then
    CLI=$(command -v storcli || command -v storcli64 || command -v perccli)
    echo ">>> Detected LSI/PERC RAID (Dell/Huawei/Supermicro) - Running $CLI:"
    $CLI /c0 show | grep -E "Product Name|Status|BBU|CacheVault|Virtual Drives|Physical Drives" -A 15
elif command -v megacli &>/dev/null || command -v MegaCli64 &>/dev/null; then
    MCLI=$(command -v megacli || command -v MegaCli64)
    echo ">>> Running MegaCLI Summary:"
    $MCLI -AdpAllInfo -aALL | grep -E "Product Name|Degraded|Failed Disks|Memory Size"
    $MCLI -PDList -aALL | grep -E "Enclosure Device ID|Slot Number|Inquiry Data|Firmware state|Media Error Count|Predictive Failure Count"
else
    echo ">>> No Hardware RAID CLI found (HBA / Direct Attached / NVMe)."
fi

if grep -q "md" /proc/mdstat 2>/dev/null; then
    echo ">>> Linux Software RAID (/proc/mdstat):"
    cat /proc/mdstat
fi

echo -e "\n[3] PHYSICAL DISK SMART HEALTH (Direct + Hidden RAID Drives):"
for disk in $(lsblk -dn -o NAME | grep -E '^sd|^nvme'); do
    echo "--- Direct Device: /dev/$disk ---"
    smartctl -i -H -A /dev/$disk | grep -E "Device Model|Model Number|Serial Number|test result|Reallocated_Sector|Media_Wearout|Percentage Used|Power_On_Hours|Grown_Defect"
done

MEGARAID_DEVS=$(smartctl --scan | grep "megaraid" | awk '{print $1, $2, $3}')
if [ -n "$MEGARAID_DEVS" ]; then
    echo ">>> Scanning Physical Disks Behind MegaRAID/PERC (Dell/Huawei/Supermicro):"
    while read -r dev flag type; do
        echo "--- RAID Disk ($type) ---"
        smartctl -i -H -A "$dev" "$flag" "$type" | grep -E "Device Model|Product:|Serial|test result|Reallocated_Sector|Power_On_Hours|Media_Wearout|Elements in grown defect"
    done <<< "$MEGARAID_DEVS"
fi

if [[ "$VENDOR" =~ (HP|HPE|Hewlett) ]] && [ -b /dev/sda ]; then
    echo ">>> Scanning Physical Disks Behind HP Smart Array:"
    for i in {0..11}; do
        OUT=$(smartctl -i -H -A -d cciss,$i /dev/sda 2>/dev/null)
        if echo "$OUT" | grep -q -E "Device Model|Product:"; then
            echo "--- HP RAID Bay cciss,$i ---"
            echo "$OUT" | grep -E "Device Model|Product:|Serial|test result|Reallocated_Sector|Power_On_Hours|Grown_Defect"
        fi
    done
fi

echo -e "\n[4] IPMI / iDRAC / iLO / iBMC SENSORS & SEL LOGS:"
if command -v ipmitool &>/dev/null; then
    echo ">>> Out-of-Band BMC IP:"
    ipmitool lan print | grep -E "IP Address Source|IP Address   "
    echo ">>> Thermal & Power Status:"
    ipmitool sdr type Temperature | grep -v "Disabled\|ns"
    ipmitool sdr type "Power Supply" | grep -v "ns"
    echo ">>> Last 10 Hardware Event Logs (SEL):"
    ipmitool sel elist | tail -n 10
else
    echo "ipmitool not installed."
fi
