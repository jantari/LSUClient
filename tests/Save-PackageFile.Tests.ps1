BeforeAll {
    # Import the module
    Import-Module "$PSScriptRoot/../LSUClient.psd1"
}

Describe 'Save-PackageFile' {
    It 'Fetch a file and return its path (HTTP)' {
        InModuleScope LSUClient {
            $MockFile = [PackageFilePointer]::new(
                'README.md', # Name
                'https://raw.githubusercontent.com/jantari/LSUClient/master/README.md', # AbsoluteLocation
                'HTTP', # LocationType
                'Test', # Kind
                'ABC123', # Checksum
                123 # Size
            )

            $Destination = Join-Path -Path $ENV:TEMP -ChildPath 'README.md'

            $Destination | Should -Not -Exist

            $return = Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP

            $Destination | Should -Exist

            Remove-Item -LiteralPath $Destination

            $return | Should -Not -BeNullOrEmpty
            $return | Should -BeOfType System.String
        }
    }
    It "Respects ErrorAction when a file doesn't exist (HTTP)" {
        InModuleScope LSUClient {
            $MockFile = [PackageFilePointer]::new(
                'doesntexist.mockfile', # Name
                'https://raw.githubusercontent.com/jantari/LSUClient/master/doesntexist.mockfile', # AbsoluteLocation
                'HTTP', # LocationType
                'Test', # Kind
                'ABC123', # Checksum
                123 # Size
            )

            # Validate the 404 error is non-terminating with ErrorAction Continue or SilentlyContinue
            $null = Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP -ErrorAction SilentlyContinue -ErrorVariable spfErrors
            $spfErrors.Count | Should -Not -Be 0
            $spfErrors | Should -BeLike "*404*"

            # Validate the error becomes terminating with ErrorAction Stop
            { Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP -ErrorAction Stop } | Should -Throw '*404*'
        }
    }
    It 'Fetch a file and return its path (FILE)' {
        InModuleScope LSUClient {
            $MockFile = [PackageFilePointer]::new(
                'README.md', # Name
                (Join-Path -Path $PWD -ChildPath "README.md"), # AbsoluteLocation
                'FILE', # LocationType
                'Test', # Kind
                'ABC123', # Checksum
                123 # Size
            )

            $Destination = Join-Path -Path $ENV:TEMP -ChildPath 'README.md'

            $Destination | Should -Not -Exist

            $return = Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP

            $Destination | Should -Exist

            Remove-Item -LiteralPath $Destination

            $return | Should -Not -BeNullOrEmpty
            $return | Should -BeOfType System.String
        }
    }
    It "Respects ErrorAction when a file doesn't exist (FILE)" {
        InModuleScope LSUClient {
            $MockFile = [PackageFilePointer]::new(
                'doesntexist.mockfile', # Name
                (Join-Path -Path $PWD -ChildPath 'doesntexist.mockfile'), # AbsoluteLocation
                'FILE', # LocationType
                'Test', # Kind
                'ABC123', # Checksum
                123 # Size
            )

            # Validate the error is non-terminating with ErrorAction Continue or SilentlyContinue
            $null = Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP -ErrorAction SilentlyContinue -ErrorVariable spfErrors
            $spfErrors.Count | Should -Not -Be 0
            $spfErrors | Should -BeLike "Cannot find*"

            # Validate the error becomes terminating with ErrorAction Stop
            { Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP -ErrorAction Stop } | Should -Throw 'Cannot find*'
        }
    }
}
