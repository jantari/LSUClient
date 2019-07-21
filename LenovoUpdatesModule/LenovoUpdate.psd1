@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'LenovoUpdate.psm1'
     
    # Version number of this module.
    ModuleVersion = '1.0'
     
    # ID used to uniquely identify this module
    GUID = 'bcfb7105-352c-4c41-b099-e587e451a732'
     
    # Author of this module
    Author = 'jantari'
     
    # Copyright statement for this module
    Copyright = '(c) 2019 jantari'
     
    # Description of the functionality provided by this module
    Description = 'Find and install driver and firmware updates for Lenovo computers'
     
    # Minimum version of the Windows PowerShell engine required by this module
    PowerShellVersion = '5.0'
     
    # Minimum version of Microsoft .NET Framework required by this module
    # DotNetFrameworkVersion = ''

    # Script files (.ps1) that are run in the caller's environment prior to importing this module.
    # ScriptsToProcess = @()
     
    # Type files (.ps1xml) to be loaded when importing this module
    # TypesToProcess = @()
     
    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess = @('LenovoUpdate.Format.ps1xml')

    # Functions to export from this module
    FunctionsToExport = @('Get-LenovoUpdate', 'Save-LenovoUpdate', 'Install-LenovoUpdate')

    # Cmdlets to export from this module
    CmdletsToExport = @()
     
    # Variables to export from this module
    VariablesToExport = @()
     
    # Aliases to export from this module
    AliasesToExport = @()

    # List of all files packaged with this module
    # FileList = @()
     
    # Private data to pass to the module specified in RootModule/ModuleToProcess
    # PrivateData = ''
     
    # HelpInfo URI of this module
    # HelpInfoURI = 'https://www.github.com/jantari/LenovoUpdate'
     
    # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
    # DefaultCommandPrefix = ''
}