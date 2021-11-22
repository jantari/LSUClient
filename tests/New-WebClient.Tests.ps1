BeforeAll {
    # Function to test
    . "$PSScriptRoot/../private/New-WebClient.ps1"
}

Describe 'New-WebClient' {
    It 'Returns WebClient - No parameters' {
        New-WebClient | Should -BeOfType 'System.Net.WebClient'
    }

    It 'Returns WebClient - With Proxy' {
        $wc = New-WebClient -Proxy 'http://localhost:8080/'
        $wc | Should -BeOfType 'System.Net.WebClient'
        $wc.Proxy | Should -BeOfType 'System.Net.WebProxy'
    }
}
