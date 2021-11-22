BeforeAll {
    . "$PSScriptRoot/../private/Compare-Version.ps1"
}

Describe "Compare-Version" {
    It 'Equal versions - 1 digit' {
        $result = Compare-Version -ReferenceVersion @(0) -DifferenceVersion @(0)
        $result | Should -Be 0
    }

    It 'Equal versions - 5 digits' {
        $result = Compare-Version -ReferenceVersion @(1,0,23,4,1) -DifferenceVersion @(1,0,23,4,1)
        $result | Should -Be 0
    }

    It 'Equal versions - Uneven lengths, trailing zeros' {
        $result = Compare-Version -ReferenceVersion @(1,0,23,4,1) -DifferenceVersion @(1,0,23,4,1,0,0)
        $result | Should -Be 0
    }

    It 'ReferenceVersion higher - Uneven lengths, leading zeros' {
        $result = Compare-Version -ReferenceVersion @(1,0,23,4,1) -DifferenceVersion @(0,0,1,0,23,4,1)
        $result | Should -Be 1
    }

    It 'ReferenceVersion higher - single digit' {
        $result = Compare-Version -ReferenceVersion @(5) -DifferenceVersion @(1)
        $result | Should -Be 1
    }

    It 'ReferenceVersion higher - 5 digits' {
        $result = Compare-Version -ReferenceVersion @(5,0,21,1) -DifferenceVersion @(5,0,20,4)
        $result | Should -Be 1
    }

    It 'ReferenceVersion higher - Uneven lengths' {
        $result = Compare-Version -ReferenceVersion @(5,0,21) -DifferenceVersion @(5,0,20,4,999)
        $result | Should -Be 1
    }

    It 'ReferenceVersion higher - Version bigger than Int.MaxValue' {
        $result = Compare-Version -ReferenceVersion @(2147483648,0) -DifferenceVersion @(5)
        $result | Should -Be 1
    }

    It 'DifferenceVersion higher - 1 digit' {
        $result = Compare-Version -ReferenceVersion @(5) -DifferenceVersion @(100)
        $result | Should -Be 2
    }

    It 'DifferenceVersion higher - 5 digits' {
        $result = Compare-Version -ReferenceVersion @(1,0,23,4,1) -DifferenceVersion @(1,0,23,5,5)
        $result | Should -Be 2
    }

}
