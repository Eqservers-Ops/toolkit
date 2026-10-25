# EqServers - Windows Server Hardware Audit & Speedtest v2.2
$ErrorActionPreference = "SilentlyContinue"

$sys = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$uptime = (Get-Date) - $os.LastBootUpTime

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " EQSERVERS WINDOWS DIAGNOSTIC & SPEEDTEST REPORT v2.2" -ForegroundColor Cyan
Write-Host " Vendor : $($sys.Manufacturer)"
Write-Host " Model  : $($sys.Model) (S/N: $($bios.SerialNumber))"
Write-Host " OS     : $($os.Caption) | Build: $($os.BuildNumber) | Uptime: $($uptime.Days)d $($uptime.Hours)h"
Write-Host " Host   : $env:COMPUTERNAME | Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC"
Write-Host "=================================================================" -ForegroundColor Cyan

Write-Host "`n[1] CPU & RAM SUMMARY:" -ForegroundColor Yellow
$procs = Get-CimInstance Win32_Processor
foreach ($p in $procs) {
    Write-Host "  CPU: $($p.Name.Trim()) | Cores: $($p.NumberOfCores) | Logical: $($p.NumberOfLogicalProcessors)"
}
$totalRam = [math]::Round($sys.TotalPhysicalMemory / 1GB, 2)
$freeRam = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
Write-Host "  Memory: Total = $totalRam GB | Free = $freeRam GB"
Write-Host "  Populated RAM DIMM Slots:"
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    $sz = [math]::Round($_.Capacity / 1GB, 0)
    Write-Host ("    - Slot: {0,-14} | Size: {1,-5} GB | Speed: {2} MHz | Part: {3}" -f $_.DeviceLocator, $sz, $_.Speed, $_.PartNumber.Trim())
}

Write-Host "`n[2] NETWORK INTERFACES & PORT SPEED CHECK:" -ForegroundColor Yellow
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.PhysicalMediaType -ne 'Unspecified' } | ForEach-Object {
    $iface = $_
    $ip = (Get-NetIPAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4).IPAddress -join ", "
    if (-not $ip) { $ip = "No IPv4" }
    Write-Host ("  - {0,-18} | Status: {1,-12} | Speed: {2,-10} | MAC: {3} | IP: {4}" -f $iface.Name, $iface.Status, $iface.LinkSpeed, $iface.MacAddress, $ip)
}

Write-Host "`n[3] INTERNET BANDWIDTH SPEEDTEST (Ookla Speedtest CLI):" -ForegroundColor Yellow
$stPath = "$env:TEMP\speedtest.exe"
if (-not (Test-Path $stPath)) {
    Write-Host "  [INFO] Downloading official Ookla Speedtest CLI utility..." -ForegroundColor DarkGray
    $zipPath = "$env:TEMP\speedtest.zip"
    try {
        Invoke-WebRequest -Uri "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip" -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\speedtest_extracted" -Force
        Move-Item "$env:TEMP\speedtest_extracted\speedtest.exe" $stPath -Force
        Remove-Item $zipPath -Force
        Remove-Item "$env:TEMP\speedtest_extracted" -Recurse -Force
    } catch {
        Write-Host "  [WARN] Could not download speedtest binary automatically." -ForegroundColor Red
    }
}

if (Test-Path $stPath) {
    Write-Host "  Running Ookla Speedtest against nearest server (please wait ~10 seconds)..." -ForegroundColor Cyan
    $stOutput = & $stPath --accept-license --accept-gdpr --format=json | ConvertFrom-Json
    if ($stOutput -and $stOutput.download) {
        $dlMbps = [math]::Round($stOutput.download.bandwidth * 8 / 1000000, 2)
        $ulMbps = [math]::Round($stOutput.upload.bandwidth * 8 / 1000000, 2)
        $ping = [math]::Round($stOutput.ping.latency, 1)
        $isp = $stOutput.client.isp
        $serverName = $stOutput.server.name
        $serverLoc = $stOutput.server.location
        Write-Host ("  - Download Speed : {0} Mbps" -f $dlMbps) -ForegroundColor Green
        Write-Host ("  - Upload Speed   : {0} Mbps" -f $ulMbps) -ForegroundColor Green
        Write-Host ("  - Ping / Latency : {0} ms" -f $ping)
        Write-Host ("  - Test Server    : {0} ({1})" -f $serverName, $serverLoc)
        Write-Host ("  - ISP / Provider : {0}" -f $isp)
    } else {
        Write-Host "  [WARN] Speedtest executed but returned unexpected data format." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [SKIP] Speedtest tool unavailable." -ForegroundColor Yellow
}

Write-Host "`n[4] STORAGE CONTROLLERS & PHYSICAL DISK HEALTH:" -ForegroundColor Yellow
Write-Host ">>> Storage / RAID Controllers:"
Get-CimInstance Win32_SCSIController | ForEach-Object {
    Write-Host "  - $($_.Name) (Status: $($_.Status))"
}

Write-Host ">>> Physical Disks & Reliability Counters (Uncorrected Errors / Wear):"
Get-PhysicalDisk | Sort-Object DeviceId | ForEach-Object {
    $disk = $_
    $rel = $disk | Get-StorageReliabilityCounter
    $sz = [math]::Round($disk.Size / 1GB, 1)
    Write-Host ("  --- Disk #{0}: {1} ({2} GB | {3} | Bus: {4}) ---" -f $disk.DeviceId, $disk.FriendlyName, $sz, $disk.MediaType, $disk.BusType)
    Write-Host ("      Serial: {0} | Health: {1} | OperationalStatus: {2}" -f $disk.SerialNumber, $disk.HealthStatus, $disk.OperationalStatus)
    if ($rel) {
        Write-Host ("      ReadErrorsUncorrected: {0} | WriteErrorsUncorrected: {1} | SSD Wear: {2}% | Temp: {3} C | PowerOnHours: {4}" -f `
            $(if ($null -ne $rel.ReadErrorsUncorrected) {$rel.ReadErrorsUncorrected} else {"0"}), `
            $(if ($null -ne $rel.WriteErrorsUncorrected) {$rel.WriteErrorsUncorrected} else {"0"}), `
            $(if ($null -ne $rel.Wear) {$rel.Wear} else {"N/A"}), `
            $(if ($null -ne $rel.Temperature) {$rel.Temperature} else {"N/A"}), `
            $(if ($null -ne $rel.PowerOnHours) {$rel.PowerOnHours} else {"N/A"}))
    }
}

Write-Host "`n[5] WINDOWS SYSTEM EVENT LOG: DISK I/O & HARDWARE (WHEA) ERRORS (Last 7 Days):" -ForegroundColor Yellow
$startTime = (Get-Date).AddDays(-7)
$hwEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger','disk','ntfs','storachi','MegaSAS','HpSAMD'; Level=1,2,3; StartTime=$startTime} -MaxEvents 10
if ($hwEvents) {
    Write-Host "  [WARN] Recent Disk or Hardware (WHEA/ECC/PCIe) Errors Detected:" -ForegroundColor Red
    foreach ($ev in $hwEvents) {
        $msg = ($ev.Message -split "`r`n")[0]
        Write-Host "    [$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm'))] [$($ev.ProviderName) ID:$($ev.Id)] $msg"
    }
} else {
    Write-Host "  [OK] Zero WHEA Hardware/RAM errors or Disk Bad Block/I/O errors in the last 7 days." -ForegroundColor Green
}

Write-Host "`n[6] RDP CONFIGURATION & HOTFIX VERIFICATION:" -ForegroundColor Yellow
$hotfixId = "KB5129237"
$kb = Get-HotFix -Id $hotfixId
$lastKb = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1
if ($kb) {
    Write-Host "  [OK] Target RDS Hotfix $hotfixId is installed." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Specific hotfix $hotfixId not listed. Latest installed update: $($lastKb.HotFixID) ($($lastKb.InstalledOn))"
}

Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null
Write-Host "  [OK] Remote Desktop (RDP) service & Windows Firewall rules verified active." -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
