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

        $Result = switch -Wildcard ($XMLTREE.SchemaInfo.Name) {
            '_*' {
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
            }
            'And' {
                $SubtreeResults = Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes -PackagePath $PackagePath -TreatUnsupportedAsPassed:$TreatUnsupportedAsPassed -FailInboxDrivers:$FailInboxDrivers -ParentNodeIsAnd
                Write-Debug "$('- ' * $XMLTreeDepth)Tree was AND: Results: $SubtreeResults"
                if ($SubtreeResults -contains $false) { $false } else { $true  }
            }
            default {
                $SubtreeResults = Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes -PackagePath $PackagePath -TreatUnsupportedAsPassed:$TreatUnsupportedAsPassed -FailInboxDrivers:$FailInboxDrivers
                Write-Debug "$('- ' * $XMLTreeDepth)Tree was OR: Results: $SubtreeResults"
                if ($SubtreeResults -contains $true ) { $true  } else { $false }
            }
        }

        Write-Debug "$('- ' * $XMLTreeDepth)< Returning $($Result -bxor $ParserState) from node $($XMLTREE.SchemaInfo.Name)"

        $Result -bxor $ParserState

        # If we're evaluating the children of an And-node, and we get a negative result before the last child-element,
        # we can stop and don't have to process the remaining children anymore as the And-result will always be false.
        # This speeds things up but it can also avoid even running problematic tests, e.g. some ExternalDetections.
        if ($ParentNodeIsAnd -and $i -ne $XMLIN.Count -and -not ($Result -bxor $ParserState)) {
            Write-Debug "$('- ' * $XMLTreeDepth)Stopping AND evaluation early"
            $ParserState = 0 # DO_HAVE
            break;
        }
        $ParserState = 0 # DO_HAVE
    }

    $XMLTreeDepth--
}
