BeforeAll {
    # Function to test
    . "$PSScriptRoot/../private/Split-ExecutableAndArguments.ps1"
}

Describe 'Split-ExecutableAndArguments' {
    It 'File that exists by absolute path' {
        $split = Split-ExecutableAndArguments -Command "$env:SystemRoot\System32\ipconfig.exe -all" -WorkingDirectory "$env:SystemRoot\System32"

        $split | Should -Not -Be $null
        $split[0] | Should -BeLike '*ipconfig.exe'
        $split[1] | Should -BeExactly '-all'
    }
    It 'File that exists by relative path' {
        $split = Split-ExecutableAndArguments -Command "ipconfig.exe -all" -WorkingDirectory "$env:SystemRoot\System32"

        $split | Should -Not -Be $null
        $split[0] | Should -BeLike '*ipconfig.exe'
        $split[1] | Should -BeExactly '-all'
    }
    It "File that doesn't exist by absolute path" {
        $split = Split-ExecutableAndArguments -Command "$env:SystemRoot\doesntexist.mock" -WorkingDirectory "$env:SystemRoot\System32"

        $split | Should -Be $null
    }
    It "File that doesn't exist by relative path" {
        $split = Split-ExecutableAndArguments -Command "doesntexist.mock" -WorkingDirectory "$env:SystemRoot\System32"

        $split | Should -Be $null
    }
}
