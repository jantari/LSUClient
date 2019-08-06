<div>
<img align="left" src="logo_220px.png" alt="LSUClient PowerShell Module PNG Logo" style="padding-right: 40px"/>

# LSU Client

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
- Full Web-Proxy support
- Ability to download updates in parallel
- Accounts for and works around some bugs and mistakes in the official tool
- Free and Open-source

## Examples

Typical use for ones own computer:
```powershell
$updates = Get-LSUpdate
$updates | Save-LSUpdate -ShowProgress
$updates | Install-LSUpdate -Verbose
```

To install only packages that can be installed silently and non-interactively (e.g. for unattended, automated runs):
```powershell
$updates = Get-LSUpdate | Where { $_.Installer.Unattended }
$updates | Save-LSUpdate -Verbose
$updates | Install-LSUpdate -Verbose
```

By default, `Get-LSUpdate` will filter out packages that aren't applicable to the computer it's being run on.  
If you want to manually inspect all available packages and disable this behavior use:
```powershell
Get-LSUpdate -All
```

You will still get to see which packages were determined applicable and which ones weren't by the value of the `IsApplicable` boolean property on each package.
You may apply your own filtering logic before installing the packages.

For more details, available parameters and guidance on how to use them run `Get-Help` on the functions in this module.

## Misc

- This module does not clean up downloaded packages at any point. This is by design as it checks for previously downloaded packages and skips them. The default download location is `$env:TEMP\LSUPackages` - you may delete it yourself
- Only Windows 10 is supported. Windows 7 compatibility is theoretically feasible for as long as Lenovo provides support for it, but I won't do it. This module makes use of modern PowerShell and modern Windows features and I personally have no interest in Windows 7.
- If you explicitly `Save-LSUpdate` before using `Install-LSUpdate` the whole operation will be faster because when calling `Save-LSUpdate` directly it downloads the packages in parallel, but calling `Install-LSUpdate` first will download then install each package after the other
