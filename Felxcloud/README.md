# VMware Tools Removal Script

This script removes VMware Tools from a Windows server running in a CloudStack KVM environment. It is intended for local server cleanup and is designed to stop services, remove drivers, delete registry entries, and remove installed VMware directories.

File:
- `Felxcloud/UnInstall_VMtools_Local_NOreboots.ps1`

## Purpose

The script:
- verifies the server is running on the expected CloudStack KVM hypervisor model
- checks whether VMware Tools is installed
- stops and removes VMware-related services
- removes VMware virtual NIC drivers (such as `vmxnet3`)
- deletes VMware registry keys and startup entries
- removes local VMware installation folders under `C:\Program Files`
- writes a transcript log to `C:\Temp\Rehome\Task1_VMtools_Uninstall_script_log.txt`

## Important notes

- This script is intended for Windows systems running VMware Tools in a KVM/CloudStack-managed environment.
- It performs a manual cleanup of VMware Tools and may leave residual items depending on system state.
- A server reboot is recommended after execution to complete removal and ensure the system is fully clean.
- The script explicitly checks the system model and exits early if the machine is not identified as a CloudStack KVM hypervisor.

## Requirements

- Windows PowerShell
- Local administrator privileges
- VMware Tools installed on the target server

## Execution

Run the script in an elevated PowerShell session:

```powershell
.\UnInstall_VMtools_Local_NOreboots.ps1
```

## Behavior summary

1. Creates the `C:\Temp\Rehome` folder if it does not exist.
2. Starts a transcript log for troubleshooting.
3. Checks the machine model.
4. Finds VMware Tools installation metadata from the Windows Installer database.
5. Stops VMware services and removes them.
6. Removes VMware device drivers.
7. Deletes VMware registry keys and startup items.
8. Removes VMware program folders.
9. Validates whether VMware Tools was removed.
10. Stops the transcript log.

## Log file

The script logs output to:

```text
C:\Temp\Rehome\Task1_VMtools_Uninstall_script_log.txt
```

## Warning

This script removes system components related to VMware Tools. Use it only on systems that are intentionally being decommissioned or re-imaged, and validate the server state before use.

## Authoring notes

This script was created for local server cleanup operations and is intended to help administrators remove VMware Tools from Windows machines without a full scripted installation process.
