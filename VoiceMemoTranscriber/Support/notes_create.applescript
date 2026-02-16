on run argv
    set noteTitle to item 1 of argv
    set noteBody to item 2 of argv

    tell application "Notes"
        activate
        tell default account
            make new note at default folder with properties {name:noteTitle, body:noteBody}
        end tell
    end tell
end run
