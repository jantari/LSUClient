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

            Write-Host $return
            Remove-Item -LiteralPath $Destination

            $return | Should -Not -BeNullOrEmpty
            $return | Should -BeOfType System.String
        }
    }
    It "Fails when a file doesn't exist (HTTP)" {
        InModuleScope LSUClient {
            $MockFile = [PackageFilePointer]::new(
                'doesntexist.mockfile', # Name
                'https://raw.githubusercontent.com/jantari/LSUClient/master/doesntexist.mockfile', # AbsoluteLocation
                'HTTP', # LocationType
                'Test', # Kind
                'ABC123', # Checksum
                123 # Size
            )

            { Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP } | Should -Throw '*404*'
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

            Write-Host $return
            Remove-Item -LiteralPath $Destination

            $return | Should -Not -BeNullOrEmpty
            $return | Should -BeOfType System.String
        }
    }
    It "Fails when a file doesn't exist (FILE)" {
        InModuleScope LSUClient {
            $MockFile = [PackageFilePointer]::new(
                'doesntexist.mockfile', # Name
                (Join-Path -Path $PWD -ChildPath 'doesntexist.mockfile'), # AbsoluteLocation
                'FILE', # LocationType
                'Test', # Kind
                'ABC123', # Checksum
                123 # Size
            )

            { Save-PackageFile -SourceFile $MockFile -Directory $ENV:TEMP -ErrorAction Stop } | Should -Throw 'Cannot find*'
        }
    }
}
