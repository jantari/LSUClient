BeforeAll {
    # Function to test
    . "$PSScriptRoot/../private/Get-PackagePathInfo.ps1"
}

Describe 'Get-PackagePathInfo' {
    It 'File on HTTP webserver by absolute path' {
        $info = Get-PackagePathInfo -Path 'https://raw.githubusercontent.com/jantari/LSUClient/master/README.md'

        $info.Valid | Should -Be $true
        $info.Type | Should -BeExactly 'HTTP'
        $info.AbsoluteLocation | Should -BeExactly 'https://raw.githubusercontent.com/jantari/LSUClient/master/README.md'
    }
    It 'File on HTTP webserver by relative path' {
        $info = Get-PackagePathInfo -BasePath 'https://raw.githubusercontent.com/jantari/LSUClient/master' -Path 'README.md'

        $info.Valid | Should -Be $true
        $info.Type | Should -BeExactly 'HTTP'
        $info.AbsoluteLocation | Should -BeExactly 'https://raw.githubusercontent.com/jantari/LSUClient/master/README.md'
    }
    It 'File with illegal URL characters in its name on HTTP webserver' {
        $info = Get-PackagePathInfo -BasePath 'https://raw.githubusercontent.com/jantari/LSUClient/master/tests' -Path 'urlescape%to{ }download.testfile'

        $info.Valid | Should -Be $true
        $info.Type | Should -BeExactly 'HTTP'
        $info.AbsoluteLocation | Should -BeExactly 'https://raw.githubusercontent.com/jantari/LSUClient/master/tests/urlescape%25to%7B%20%7Ddownload.testfile'
    }
    It "Local file by absolute path" {
        $file = Join-Path -Path $PWD -ChildPath 'README.md'
        $info = Get-PackagePathInfo  -Path $file

        $info.Valid | Should -Be $true
        $info.Type | Should -BeExactly 'FILE'
        $info.AbsoluteLocation | Should -BeExactly $file
    }
    It "Local file by relative path" {
        $info = Get-PackagePathInfo -BasePath $PWD -Path 'README.md'

        $info.Valid | Should -Be $true
        $info.Type | Should -BeExactly 'FILE'
        $info.AbsoluteLocation | Should -BeExactly (Join-Path -Path $PWD -ChildPath 'README.md')
    }
}
