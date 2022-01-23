function Remove-CmdEscapeCharacter {
    <#
        .NOTES
        All CMD (Command Prompt) Metacharacters are: ( ) % ! ^ " < > & |
        Sometimes, Lenovo uses a ^ (caret) to escape one of the above in their commands, for example in package n1olk08w.
        Most of the time they either don't, or enclose the string containing the metacharacter in quotes.

        Since this module does not run commands through cmd.exe anymore we mustn't escape these characters
        and in cases where a command contains a metacharacter prepended by a caret, we most likely have to
        remove the caret (like cmd would) prior to running the command.

        In module versions 1.2.2 and below, commands were still run through cmd.exe and this logic was inverted -
        escaped metacharacters were what we wanted and unescaped ones had to be manually escaped as best as possible
    #>

    [OutputType('System.String')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Scope='Function',
        Justification='This function does not change system state, it only edits a string'
    )]
    Param (
        [string]$String
    )

    if (-not $String.Contains('^')) {
        return $String
    }

    # These are the characters with special meaning in cmd
    # If we find a caret (^) before any of them inside a command string
    # it is highly likely it's there to escape that character for cmd.exe
    # and not because it's supposed to be passed literally
    [char[]]$CmdMetacharacters = @(
        '(',
        ')',
        '%',
        '!',
        '^',
        '"',
        '>',
        '<',
        '&',
        '|'
    )

    $newString = for ($i = 0; $i -lt $String.Length; $i++) {
        if ($String[$i] -eq '^') {
            if ($String[$i + 1] -in $CmdMetacharacters) {
                # If the next character after the ^ is one of the metacharacters
                # skip the ^ (remove from string) and jump ahead to the next char
                $i++
            }
        }

        $String[$i]
    }

    return -join $newString
}
