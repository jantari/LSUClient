BeforeAll {
    # Dependency
    . "$PSScriptRoot/../private/Compare-Version.ps1"
    # Function to test
    . "$PSScriptRoot/../private/Test-VersionPattern.ps1"
}

Describe 'Test-VersionPattern' {
    It 'Equal versions' {
        Test-VersionPattern -LenovoString '10.0.0.1' -SystemString '10.0.0.1' | Should -Be 0
    }

    It 'Lenovo Pattern - Less than' {
        Test-VersionPattern -LenovoString '^10.0.0.1' -SystemString '10.0.2.2' | Should -Be -1
    }

    It 'Lenovo Pattern - Less than' {
        Test-VersionPattern -LenovoString '^10.0.0.1' -SystemString '8.0' | Should -Be 0
    }

    It 'Lenovo Pattern - Higher than' {
        Test-VersionPattern -LenovoString '10.0.0.1^' -SystemString '8.0' | Should -Be -1
    }

    It 'Lenovo Pattern - Range A to B' {
        Test-VersionPattern -LenovoString '10.1^20.4.5' -SystemString '16.111.0.9' | Should -Be 0
    }

    It 'Lenovo Pattern - Range A to B' {
        Test-VersionPattern -LenovoString '10.1^20.4.5' -SystemString '8.0.2' | Should -Be -1
    }

    It 'Lenovo Pattern Unsupported' {
        Test-VersionPattern -LenovoString '^1^' -SystemString '8.0' | Should -Be -2
    }

    It 'Lenovo Pattern Unsupported' {
        Test-VersionPattern -LenovoString '-100' -SystemString '8.0' | Should -Be -2
    }

    It 'System Pattern Unsupported' {
        Test-VersionPattern -LenovoString '1.0' -SystemString '8.0-beta' | Should -Be -2
    }

    It 'Hexadecimal comparison - Equal' {
        Test-VersionPattern -LenovoString '221b' -SystemString '8731' | Should -Be 0
        Test-VersionPattern -LenovoString '1337' -SystemString '4919' | Should -Be -1
        Test-VersionPattern -LenovoString '1337' -SystemString '4919' -LenovoStringFormat Hex | Should -Be 0
    }

    It 'Hexadecimal comparison - Less than' {
        Test-VersionPattern -LenovoString '^221B' -SystemString '8096' | Should -Be 0
    }

    It 'Hexadecimal comparison - Range A to B' {
        Test-VersionPattern -LenovoString '1337^221B' -SystemString '5000' | Should -Be 0
        Test-VersionPattern -LenovoString '1234^1337' -SystemString '4800' -LenovoStringFormat Hex | Should -Be 0
        Test-VersionPattern -LenovoString '1234^1337' -SystemString '12FF' -LenovoStringFormat Hex | Should -Be 0
    }
}
