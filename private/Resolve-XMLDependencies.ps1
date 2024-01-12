function Resolve-XMLDependencies {
    Param (
        [Parameter( Mandatory = $true )]
        [ValidateNotNullOrEmpty()]
        $XMLIN,
        [Parameter( Mandatory = $true )]
        [string]$PackagePath,
        [switch]$TreatUnsupportedAsPassed,
        [switch]$FailInboxDrivers,
        [switch]$ParentNodeIsAnd
    )

    $XMLTreeDepth++
    [DependencyParserState]$ParserState = 0

    $i = 0
    foreach ($XMLTREE in $XMLIN) {
        $i++
        Write-Debug "$('- ' * $XMLTreeDepth )|> Node: $($XMLTREE.SchemaInfo.Name)"

        if ($XMLTREE.SchemaInfo.Name -eq 'Not') {
            $ParserState = $ParserState -bxor 1
            Write-Debug "$('- ' * $XMLTreeDepth)Switched state to: $ParserState"
        }

        $Result = if ($XMLTREE.SchemaInfo.Name -like "_*") {
            switch (Test-MachineSatisfiesDependency -Dependency $XMLTREE -PackagePath $PackagePath -DebugIndent $XMLTreeDepth -FailInboxDrivers:$FailInboxDrivers) {
                0 {
                    $true
                }
                -1 {
                    $false
                }
                -2 {
                    Write-Debug "$('- ' * $XMLTreeDepth)Something unsupported encountered in: $($XMLTREE.SchemaInfo.Name)"
                    if ($TreatUnsupportedAsPassed) { $true } else { $false }
                }
            }
        } else {
            $SubtreeResults = Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes -PackagePath $PackagePath -TreatUnsupportedAsPassed:$TreatUnsupportedAsPassed -FailInboxDrivers:$FailInboxDrivers -ParentNodeIsAnd:($XMLTREE.SchemaInfo.Name -eq 'And')
            switch ($XMLTREE.SchemaInfo.Name) {
                'And' {
                    Write-Debug "$('- ' * $XMLTreeDepth)Tree was AND: Results: $subtreeresults"
                    if ($subtreeresults -contains $false) { $false } else { $true  }
                }
                default {
                    Write-Debug "$('- ' * $XMLTreeDepth)Tree was OR: Results: $subtreeresults"
                    if ($subtreeresults -contains $true ) { $true  } else { $false }
                }
            }
        }

        Write-Debug "$('- ' * $XMLTreeDepth)< Returning $($Result -bxor $ParserState) from node $($XMLTREE.SchemaInfo.Name)"

        $Result -bxor $ParserState
        if ($ParentNodeIsAnd -and $i -ne $XMLIN.Count -and -not ($Result -bxor $ParserState)) {
            Write-Debug "$('- ' * $XMLTreeDepth)Quitting AND evaluation early because we already got one FALSE."
            $ParserState = 0 # DO_HAVE
            break;
        }
        $ParserState = 0 # DO_HAVE
    }

    $XMLTreeDepth--
}
