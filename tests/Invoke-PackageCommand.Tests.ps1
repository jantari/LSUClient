BeforeAll {
    # Import the module
    Import-Module "$PSScriptRoot/../LSUClient.psd1"
}

Describe 'Invoke-PackageCommand' {
    It 'Runs a simple command by Exe and Args' {
        InModuleScope LSUClient {
            $result = Invoke-PackageCommand -Executable "${env:SystemRoot}\system32\ipconfig.exe" -Arguments '-all' -Path "${env:SystemRoot}\system32"
            $result.Err | Should -Be 'NONE'
            $result.Info | Should -Not -Be $null
            $result.Info.Runtime | Should -BeGreaterThan ([TimeSpan]::Zero)
            $result.Info.StandardOutput | Should -Not -BeNullOrEmpty
        }
    }
    It 'Runs a simple command by CommandString' {
        InModuleScope LSUClient {
            $result = Invoke-PackageCommand -Command "${env:SystemRoot}\system32\ipconfig.exe -all" -Path "${env:SystemRoot}\system32"
            $result.Err | Should -Be 'NONE'
            $result.Info | Should -Not -Be $null
            $result.Info.Runtime | Should -BeGreaterThan ([TimeSpan]::Zero)
            $result.Info.StandardOutput | Should -Not -BeNullOrEmpty
        }
    }
    It 'Kills processes after set timeout' {
        InModuleScope LSUClient {
            $result = Invoke-PackageCommand -Command "${env:SystemRoot}\system32\winver.exe" -Path "${env:SystemRoot}\system32" -RuntimeLimit ([TimeSpan]::FromSeconds(2)) -WarningVariable WARNING
            $result.Err | Should -Be 'PROCESS_KILLED_TIMELIMIT'
            $result.Info | Should -Not -Be $null
            $result.Info.Runtime | Should -BeGreaterThan ([TimeSpan]::Zero)

            # Killing a process due to timeout that had a GUI window open like 'winver' does should
            # print the contents of the window to the warning stream to aid in troubleshooting hangs
            $WARNING | Should -Not -BeNullOrEmpty
        }
    }
}

