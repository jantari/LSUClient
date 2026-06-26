BeforeAll {
    # Function to test
    . "$PSScriptRoot/../private/Resolve-CmdVariable.ps1"
}

Describe 'Resolve-CmdVariable' {
    It "Undefined variable isn't replaced" {
        $resolved = Resolve-CmdVariable -String 'String with an inserted "%6A616E74617269%"' -ExtraVariables @{}

        $resolved | Should -BeExactly 'String with an inserted "%6A616E74617269%"'
    }
    It 'Correctly inserts variable values' {
        $resolved = Resolve-CmdVariable -String 'String with an inserted "%4C5355436C69656E74%"' -ExtraVariables @{'4C5355436C69656E74' = 'VALUE'}

        $resolved | Should -BeExactly 'String with an inserted "VALUE"'
    }
}
