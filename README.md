<h1 align="center">LSUClient</h1>

<p align="center">
  <img src="https://img.shields.io/powershellgallery/dt/LSUClient?label=PowerShell%20Gallery&amp;logo=Powershell&amp;logoColor=FFFFFF&amp;style=flat" alt="PowerShell Gallery">
  <img src="https://img.shields.io/powershellgallery/v/lsuclient?label=Latest&amp;logo=powershell&amp;logoColor=FFF" alt="PowerShell Gallery Version">
  <img src="https://img.shields.io/github/v/release/jantari/lsuclient?label=Latest&amp;logo=github" alt="GitHub release (latest by date)">
</p>
<p align="center">
  <img src="logo_220px.png" alt="LSUClient PowerShell Module PNG Logo" />
</p>
<p align="center">
  Orchestrate driver, BIOS/UEFI and firmware updates for Lenovo computers - with PowerShell!
</p>

## Installation

```powershell
Install-Module -Name 'LSUClient'
```

## Highlight features

- Does driver, BIOS/UEFI, firmware and utility software updates
- Allows for fully silent and unattended update runs
- Work with updates and even their results as PowerShell objects to build any custom logic imaginable
- Fetch the latest updates directly from Lenovo or use an internal repository of your own for more control
- Can work alongside, but does not require Lenovo System Update or any other external program
- Run locally or manage/report on an entire fleet of computers remotely
- Full Web-Proxy support including authentication
- Supports not only business computers but consumer lines too (e.g. IdeaPad)
- Free and open-source!

## Examples and tips

<b>See available updates:</b>
```powershell
Get-LSUpdate
```

<b>Find and install available updates:</b>
```powershell
$updates = Get-LSUpdate
$updates | Install-LSUpdate -Verbose
```

<b>Install only packages that can be installed silently and non-interactively:</b>
```powershell
$updates = Get-LSUpdate | Where-Object { $_.Installer.Unattended }
$updates | Save-LSUpdate -Verbose
$updates | Install-LSUpdate -Verbose
```

Filtering out non-unattended packages like this is strongly recommended when using this module in MDT, SCCM, PDQ,
remote execution via PowerShell Remoting, ssh or any other situation in which you run these commands remotely
or as part of an automated process. Packages with installers that are not unattended may force reboots or
attempt to start a GUI setup on the machine and, if successful, halt until someone clicks through the dialogs.

<b>To get all available packages:</b>
```powershell
$updates = Get-LSUpdate -All
```
By default, `Get-LSUpdate` only returns "needed" updates. Needed updates are those that are applicable to
the system and not yet installed. If you want to retrieve all available packages instead, use `Get-LSUpdate -All`.
To filter out unneeded packages later, just look at the `IsApplicable` and `IsInstalled` properties.
The default logic is equivalent to:
`Get-LSUpdate -All | Where-Object { $_.IsApplicable -and -not $_.IsInstalled }`

<b>Download drivers for another computer:</b>
```powershell
Get-LSUpdate -Model 20LS -All | Save-LSUpdate -Path 'C:\20LS_Drivers' -ShowProgress
```
Using the `-Model` parameter of `Get-LSUpdate` you can retrieve packages for another computer model.
In this case you almost always want to use `-All` too so that the packages found are not filtered against your computer and all packages are downloaded.

---

For further documentation please see [the documentation site](https://jantari.github.io/LSUClient-docs/) and
run `Get-Help -Detailed` on the functions in this module.

## Misc

- Only Windows 10 and Windows 11 are supported
- This module does not clean up downloaded packages and installers at any point. The default download location is `$env:TEMP\LSUPackages` - you may delete it yourself
- By default this module reaches out to https://download.lenovo.com and must be able to download `.xml`, `.exe` and `.inf` files from that domain for successful operation. Alternatively, a custom package repository can be used for completely internal or offline operation with the `-Repository` parameter of `Get-LSUpdate`. A custom repository can be served over HTTP(S) or just be a filesystem path - local or UNC.

