<div>
<img align="left" src="logo_220px.png" alt="LSUClient PowerShell Module PNG Logo" style="padding-right: 40px"/>

# LSUClient

![PowerShell Gallery](https://img.shields.io/powershellgallery/dt/LSUClient?label=PowerShell%20Gallery&logo=Powershell&logoColor=FFFFFF&style=flat)  
A PowerShell module that partially reimplements the "Lenovo System Update" program for convenient,
automatable and worry-free driver and system updates for Lenovo computers.

```powershell
Install-Module -Name 'LSUClient'
```
</div>

<br>

## Highlight features

- Does driver, BIOS/UEFI and firmware updates
- Run locally or through PowerShell remoting on another machine
- Allows for fully silent and unattended updates
- Supports not only business computers but consumer lines too (e.g. IdeaPad)
- Full Web-Proxy support including authentication
- Concise, helpful and easy-to-read output
- Ability to download updates in parallel
- Accounts for and works around some bugs and mistakes in the official tool
- Free and open-source

## Examples and tips

<b>Typical use for one's own computer:</b>
```powershell
$updates = Get-LSUpdate
$updates | Save-LSUpdate -ShowProgress
$updates | Install-LSUpdate -Verbose
```

<b>To select only packages that can be installed silently and non-interactively:</b>
```powershell
$updates = Get-LSUpdate | Where-Object { $_.Installer.Unattended }
$updates | Save-LSUpdate -Verbose
$updates | Install-LSUpdate -Verbose
```

By default, `Get-LSUpdate` only returns "needed" updates. Needed updates are those
that are applicable to the system but not yet installed. To get all available packages instead,
use `Get-LSUpdate -All`. If you later want to filter out unneeded packages, just check the
`IsApplicable` and `IsInstalled` properties. The default logic is equivalent to:
`Get-LSUpdate -All | Where-Object { $_.IsApplicable -and -not $_.IsInstalled }`

### To get all possible updates and apply custom logic to decide which ones to install:
```powershell
$updates = Get-LSUpdate -All
```
If you do this, take note of the `IsApplicable` and `IsInstalled` properties.

### Dealing with BIOS/UEFI updates

It is important to know that some Lenovo computers require a reboot to apply BIOS updates while other models require a shutdown - the BIOS will then wake the machine from the power-off state, apply the update and boot into Windows.
So as to not interrupt a deployment or someone working, this module will never initiate reboots or shutdowns on its own - however it's easy for you to:

1. Run `Install-LSUpdate` with the `-SaveBIOSUpdateInfoToRegistry` switch
2. If any BIOS/UEFI update was successfully installed this switch will write some information to the registry under `HKLM\Software\LSUClient\BIOSUpdate`,
including the String `"ActionNeeded"` which will contain `"REBOOT"` or `"SHUTDOWN"` depending on which is required to apply the update.
3. At any later point during your script, task sequence or deployment package you can check for and read this registry-key and gracefully initiate the power-cycle
on your terms. I recommend clearing the registry values under `HKLM\Software\LSUClient\BIOSUpdate` afterwards so you know the update is no longer pending.

If you want to exclude BIOS/UEFI updates, simply do so by their category:
```powershell
$updates = Get-LSUpdate | Where-Object { $_.Category -ne 'BIOS UEFI' }
```

<br>

For more details, available parameters and guidance on how to use them run `Get-Help` on the functions in this module.

## Misc

- Only Windows 10 is supported.
- This module does not clean up downloaded packages at any point. This is by design as it checks for previously downloaded packages and skips them. The default download location is `$env:TEMP\LSUPackages` - you may delete it yourself
- If you explicitly `Save-LSUpdate` before using `Install-LSUpdate` the whole operation will be faster because when calling `Save-LSUpdate` explicitly it downloads the packages in parallel, but calling `Install-LSUpdate` first will download then install each package after the other
