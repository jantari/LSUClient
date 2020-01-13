function Resolve-XMLDependencies {
    Param (
        [Parameter ( Mandatory = $true )]
        [ValidateNotNullOrEmpty()]
        $XMLIN,
        [switch]$FailUnsupportedDependencies,
        [string]$DebugLogFile
    )
    
    $XMLTreeDepth++
    [DependencyParserState]$ParserState = 0
    
    foreach ($XMLTREE in $XMLIN) {
        if ($DebugLogFile) {
            Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth )|> Node: $($XMLTREE.SchemaInfo.Name)"
        }

        if ($XMLTREE.SchemaInfo.Name -eq 'Not') {
            $ParserState = $ParserState -bxor 1
            if ($DebugLogFile) {
                Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Switched state to: $ParserState"
            }
        }
        
        $Result = if ($XMLTREE.SchemaInfo.Name -like "_*") {
            switch (Test-MachineSatisfiesDependency -Dependency $XMLTREE) {
                0 {
                    $true
                }
                -1 {
                    $false
                }
                -2 {
                    if ($DebugLogFile) {
                        Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Something unsupported encountered in: $($XMLTREE.SchemaInfo.Name)"
                    }
                    if ($FailUnsupportedDependencies) { $false } else { $true }
                }
            }
        } else {
            $SubtreeResults = Resolve-XMLDependencies -XMLIN $XMLTREE.ChildNodes -FailUnsupportedDependencies:$FailUnsupportedDependencies -DebugLogFile $DebugLogFile
            switch ($XMLTREE.SchemaInfo.Name) {
                'And' {
                    if ($DebugLogFile) {
                        Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Tree was AND: Results: $subtreeresults"
                    }
                    if ($subtreeresults -contains $false) { $false } else { $true  }
                }
                default {
                    if ($DebugLogFile) {
                        Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)Tree was OR: Results: $subtreeresults"
                    }
                    if ($subtreeresults -contains $true ) { $true  } else { $false }
                }
            }
        }

        if ($DebugLogFile) {
            Add-Content -LiteralPath $DebugLogFile -Value "$('- ' * $XMLTreeDepth)< Returning $($Result -bxor $ParserState) from node $($XMLTREE.SchemaInfo.Name)"
        }

        $Result -bxor $ParserState
        $ParserState = 0 # DO_HAVE
    }

    $XMLTreeDepth--
}