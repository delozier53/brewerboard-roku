' MainScene controller — boots the channel, decides which sub-scene to mount
' first based on whether the TV has been paired before.
'
' The "saved code" lives in Roku's Registry under section "brewerboard",
' key "screen_code". Registry is the Roku equivalent of localStorage —
' per-channel, persists across reboots, survives channel updates.

sub init()
    print "[main] init"
    m.sceneHost = m.top.findNode("sceneHost")

    code = ReadSavedCode()
    if code <> invalid and Len(code) = 6 then
        print "[main] found saved code, jumping to display: "; code
        showDisplay(code)
    else
        print "[main] no saved code, showing code-entry"
        showCodeEntry()
    end if
end sub

' Mount the 6-digit code-entry screen. Subscribes to its `submittedCode`
' field so we can swap to the display scene when the user finishes input.
sub showCodeEntry()
    clearHost()
    entry = CreateObject("roSGNode", "CodeEntryScene")
    entry.id = "entry"
    entry.observeField("submittedCode", "onCodeSubmitted")
    m.sceneHost.appendChild(entry)
    entry.setFocus(true)
end sub

' Mount the display scene with the given screen code. Subscribes to its
' `requestSignOut` field so the user can return to code entry from inside
' the display (e.g. when reassigning the TV to a different brewery).
sub showDisplay(code as string)
    clearHost()
    display = CreateObject("roSGNode", "DisplayScene")
    display.id = "display"
    display.screenCode = code
    display.observeField("requestSignOut", "onSignOutRequested")
    m.sceneHost.appendChild(display)
    display.setFocus(true)
end sub

' Tear down any currently-mounted sub-scene before mounting a new one.
sub clearHost()
    while m.sceneHost.getChildCount() > 0
        child = m.sceneHost.getChild(0)
        m.sceneHost.removeChild(child)
    end while
end sub

' Field observer: fires when CodeEntryScene sets submittedCode.
sub onCodeSubmitted()
    entry = m.sceneHost.findNode("entry")
    if entry = invalid then return
    code = entry.submittedCode
    if code = invalid or Len(code) <> 6 then return

    print "[main] code submitted, saving and switching to display: "; code
    WriteSavedCode(code)
    showDisplay(code)
end sub

' Field observer: fires when DisplayScene sets requestSignOut.
sub onSignOutRequested()
    print "[main] sign-out requested, clearing code and returning to entry"
    ClearSavedCode()
    showCodeEntry()
end sub

' ----- Registry helpers ---------------------------------------------------
' Roku's roRegistrySection is the persistent kv store. Keys + values are
' strings. Operations are cheap and safe to call on the main thread.

function ReadSavedCode() as dynamic
    section = CreateObject("roRegistrySection", "brewerboard")
    if section.Exists("screen_code") then
        return section.Read("screen_code")
    end if
    return invalid
end function

sub WriteSavedCode(code as string)
    section = CreateObject("roRegistrySection", "brewerboard")
    section.Write("screen_code", code)
    section.Flush()
end sub

sub ClearSavedCode()
    section = CreateObject("roRegistrySection", "brewerboard")
    if section.Exists("screen_code") then section.Delete("screen_code")
    section.Flush()
end sub
