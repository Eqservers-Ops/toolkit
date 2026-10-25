# EqServers Technical Support & Shift Toolkit

Official rapid diagnostic and server provisioning scripts for the EqServers shift engineering team.
Supports **HP ProLiant**, **Dell PowerEdge**, **Supermicro**, and **Huawei FusionServer** nodes.

## 1. Linux / Leaseweb Rescue Hardware Audit (HP, Dell, Supermicro, Huawei)
Run this single command inside SSH or Leaseweb Rescue Mode to inspect CPU, RAM DIMMs, RAID status (ssacli / storcli / perccli / mdadm), hidden RAID physical disk SMART health, and IPMI sensors:

    curl -sL [https://raw.githubusercontent.com/EqServers-Ops/toolkit/main/hw_diag.sh](https://raw.githubusercontent.com/EqServers-Ops/toolkit/main/hw_diag.sh) | bash

## 2. Windows Server 2019 / 2022 Post-Setup & Hotfix Check
Open PowerShell as Administrator and run:

    irm [https://raw.githubusercontent.com/EqServers-Ops/toolkit/main/win_setup.ps1](https://raw.githubusercontent.com/EqServers-Ops/toolkit/main/win_setup.ps1) | iex
