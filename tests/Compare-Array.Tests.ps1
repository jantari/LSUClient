BeforeAll {
    # Function to test
    . "$PSScriptRoot/../private/Compare-Array.ps1"
}

Describe 'Compare-Array' {
    It 'In-Test - Case True' {
        Compare-Array @(0, 'Hello', 1) -in @(0, 1, 'Hello', 'there') | Should -Be $True
    }

    It 'In-Test - Case False' {
        Compare-Array @(0, 'Hello', 1) -in @(0, 'Hello', 'there') | Should -Be $False
    }

    It 'ContainsOnly-Test - Case False' {
        Compare-Array @(0, 1, 0, 0, 0, 1) -containsonly @(0, 1, 2) | Should -Be $False
    }

    It 'ContainsOnly-Test - Case False' {
        Compare-Array @(0, 1) -containsonly @(0, 'Hello', 2) | Should -Be $False
    }
}
