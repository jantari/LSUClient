BeforeAll {
    # Function to test
    . "$PSScriptRoot/../private/Resolve-CmdVariable.ps1"
}

Describe 'Resolve-CmdVariable' {
    It 'Correctly inserts variable values' {
        $resolved = Resolve-CmdVariable -String 'String with an inserted "%TESTVARIABLE%"' -ExtraVariables @{'TESTVARIABLE' = 'VALUE'}

        $resolved | Should -BeExactly 'String with an inserted "VALUE"'
    }
    It "Undefined variable isn't replaced" {
        $resolved = Resolve-CmdVariable -String 'String with an inserted "%TESTVARIABLE%"' -ExtraVariables @{}

        $resolved | Should -BeExactly 'String with an inserted "%TESTVARIABLE%"'
    }
}
