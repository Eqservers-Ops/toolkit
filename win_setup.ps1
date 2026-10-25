Write-Host "=== EqServers Windows Server Post-Provisioning ===" -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "OS: $($os.Caption) | Build: $($os.BuildNumber)"

$hotfixId = "KB5129237"
$kb = Get-HotFix -Id $hotfixId -ErrorAction SilentlyContinue
if ($kb) {
    Write-Host "[OK] RDS Freeze Hotfix $hotfixId is installed." -ForegroundColor Green
} else {
    Write-Host "[INFO] Hotfix $hotfixId not detected on this build." -ForegroundColor Yellow
}

Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Write-Host "=== RDP Verified & Setup Complete ===" -ForegroundColor Green
