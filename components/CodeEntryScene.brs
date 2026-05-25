' CodeEntryScene — 6-digit pin entry with D-pad keypad navigation.
'
' Layout:
'   [_] [_] [_] [_] [_] [_]      <- 6 digit slots, fills as user enters
'
'    1   2   3
'    4   5   6
'    7   8   9
'   DEL  0   GO              <- 3x4 keypad
'
' D-pad moves focus across the keypad; pressing OK on a digit appends it
' to the code (if fewer than 6); OK on DEL removes last digit; OK on GO
' submits if the code is full.

' Layout constants live on `m` so init/buildDigitSlots/buildKeypad can share
' them without a global. (BrightScript SceneGraph .brs files don't permit
' bare top-level assignments — only sub/function declarations.)

sub init()
    print "[entry] init"
    m.code = ""

    m.DIGIT_SLOT_WIDTH = 80
    m.DIGIT_SLOT_HEIGHT = 100
    m.DIGIT_SLOT_GAP = 20

    m.KEYPAD_BTN_WIDTH = 120
    m.KEYPAD_BTN_HEIGHT = 100
    m.KEYPAD_BTN_GAP = 16

    m.KEYPAD_ROWS = ["123", "456", "789", "*0#"]  ' "*" = DEL, "#" = GO

    m.top.setFocus(true)
    m.top.observeField("focusedChild", "onFocusedChildChanged")
    m.top.observeFieldScoped("focusedChild", "onFocusedChildChanged")

    buildDigitSlots()
    buildKeypad()
    refreshDigitSlots()
end sub

' Draw 6 digit-slot rectangles. Each slot is a Group containing a border
' Rectangle and a centered Label holding the digit (or empty if unfilled).
sub buildDigitSlots()
    row = m.top.findNode("digitRow")
    m.digitSlots = []
    for i = 0 to 5
        slot = CreateObject("roSGNode", "Group")
        slot.id = "slot" + StrI(i).Trim()
        slot.translation = [i * (m.DIGIT_SLOT_WIDTH + m.DIGIT_SLOT_GAP), 0]

        bg = CreateObject("roSGNode", "Rectangle")
        bg.id = "slotBg"
        bg.width = m.DIGIT_SLOT_WIDTH
        bg.height = m.DIGIT_SLOT_HEIGHT
        bg.color = "0xFFFFFF1A"
        slot.appendChild(bg)

        lbl = CreateObject("roSGNode", "Label")
        lbl.id = "slotLbl"
        lbl.text = ""
        lbl.width = m.DIGIT_SLOT_WIDTH
        lbl.height = m.DIGIT_SLOT_HEIGHT
        lbl.horizAlign = "center"
        lbl.vertAlign = "center"
        lbl.font = "font:LargeBoldSystemFont"
        lbl.color = "0xFFFFFFFF"
        slot.appendChild(lbl)

        row.appendChild(slot)
        m.digitSlots.push(slot)
    end for
end sub

' Build 4x3 keypad of Button nodes. We use SceneGraph's built-in Button so
' D-pad focus + OK-press wiring comes for free.
sub buildKeypad()
    grid = m.top.findNode("keypadGroup")
    m.keypadButtons = []
    rowIdx = 0
    for each rowStr in m.KEYPAD_ROWS
        colIdx = 0
        for i = 0 to Len(rowStr) - 1
            ch = Mid(rowStr, i + 1, 1)
            btn = CreateObject("roSGNode", "Button")
            btn.id = "btn_" + ch
            btn.text = keypadLabelFor(ch)
            btn.minWidth = m.KEYPAD_BTN_WIDTH
            btn.maxWidth = m.KEYPAD_BTN_WIDTH
            btn.translation = [colIdx * (m.KEYPAD_BTN_WIDTH + m.KEYPAD_BTN_GAP), rowIdx * (m.KEYPAD_BTN_HEIGHT + m.KEYPAD_BTN_GAP)]
            btn.observeField("buttonSelected", "onKeypadButtonPressed")
            grid.appendChild(btn)
            m.keypadButtons.push({ node: btn, char: ch })
            colIdx = colIdx + 1
        end for
        rowIdx = rowIdx + 1
    end for

    ' Focus the "1" button by default — top-left of the keypad.
    if m.keypadButtons.Count() > 0 then
        m.keypadButtons[0].node.setFocus(true)
    end if
end sub

' Human-readable label for keypad chars. "*" and "#" are sentinel chars
' for DEL/GO so we can pack the layout into a single per-row string above.
function keypadLabelFor(ch as string) as string
    if ch = "*" then return "DEL"
    if ch = "#" then return "GO"
    return ch
end function

' Field observer: a keypad button's `buttonSelected` flipped true. Walks
' m.keypadButtons to find which one fired, then applies its action to
' m.code and re-renders.
sub onKeypadButtonPressed()
    for each entry in m.keypadButtons
        if entry.node.buttonSelected = true then
            ' Reset the flag immediately so subsequent presses of the same
            ' button trigger the observer again.
            entry.node.buttonSelected = false
            applyKeypadChar(entry.char)
            return
        end if
    end for
end sub

sub applyKeypadChar(ch as string)
    if ch = "*" then
        if Len(m.code) > 0 then m.code = Left(m.code, Len(m.code) - 1)
    else if ch = "#" then
        ' Only submit if the code is exactly 6 digits — otherwise ignore.
        if Len(m.code) = 6 then
            print "[entry] submitting code: "; m.code
            m.top.submittedCode = m.code
        end if
    else
        if Len(m.code) < 6 then m.code = m.code + ch
    end if
    refreshDigitSlots()
end sub

' Repaint each digit-slot label + border based on current m.code state.
sub refreshDigitSlots()
    for i = 0 to 5
        slot = m.digitSlots[i]
        lbl = slot.findNode("slotLbl")
        bg = slot.findNode("slotBg")
        if i < Len(m.code) then
            lbl.text = Mid(m.code, i + 1, 1)
            bg.color = "0xFFFFFF33"
        else
            lbl.text = ""
            bg.color = "0xFFFFFF1A"
        end if
    end for
end sub

' Optional: react to focus moving around the keypad if we want to add hover
' state styling later. No-op for now.
sub onFocusedChildChanged()
end sub
