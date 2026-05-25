' CodeEntryScene — 6-digit pin entry with a custom-rendered D-pad keypad.
'
' We avoid SceneGraph's Button node (renders unreliably on some Roku
' firmware — observed shipping as a single-pixel dot on TCL Roku TVs).
' Each keypad cell is a Group { Rectangle + Label }. Focus is tracked
' manually in m.focusIndex (0–11) and updated by onKeyEvent on every
' D-pad press.
'
' Layout coordinates are in 1920x1080 FHD space. See CodeEntryScene.xml
' for the vertical budget breakdown.

sub init()
    print "[entry] init"
    m.code = ""
    m.focusIndex = 0

    ' --- Layout constants ----------------------------------------------
    m.DIGIT_SLOT_WIDTH = 110
    m.DIGIT_SLOT_HEIGHT = 140
    m.DIGIT_SLOT_GAP = 14

    m.KEYPAD_BTN_WIDTH = 180
    m.KEYPAD_BTN_HEIGHT = 100
    m.KEYPAD_BTN_GAP = 15
    m.KEYPAD_COLS = 3
    m.KEYPAD_ROWS = 4

    ' --- Brand palette (matches tapdisplay/src/app/globals.css) --------
    '   --color-brand:    #f7cd47   warm yellow accent
    '   --color-app:      #384150   mid slate
    '   --color-app-dark: #2d3545   dark slate (root bg)
    m.BRAND_YELLOW = "0xF7CD47FF"
    m.BRAND_YELLOW_SOFT = "0xF7CD4733"  ' 20% alpha for filled-slot tint
    m.APP_SLATE = "0x384150FF"
    m.APP_DARK = "0x2D3545FF"
    m.SURFACE_DIM = "0xFFFFFF14"        ' 8% white over slate bg
    m.TEXT_ON_FOCUS = "0x2D3545FF"      ' dark slate on yellow → readable
    m.TEXT_DEFAULT = "0xFFFFFFFF"
    m.TEXT_MUTED = "0xFFFFFFAA"

    ' --- Keypad data layout (row-major: i=0..2 = row 0, etc.) ----------
    ' "*" sentinel = DEL, "#" sentinel = GO. Visible labels go through
    ' labelFor() so the data stays compact.
    m.KEYPAD = [
        { ch: "1" }, { ch: "2" }, { ch: "3" },
        { ch: "4" }, { ch: "5" }, { ch: "6" },
        { ch: "7" }, { ch: "8" }, { ch: "9" },
        { ch: "*" }, { ch: "0" }, { ch: "#" }
    ]

    m.top.setFocus(true)
    buildDigitSlots()
    buildKeypad()
    refreshDigitSlots()
    refreshKeypadFocus()
end sub

sub buildDigitSlots()
    row = m.top.findNode("digitRow")
    m.digitSlots = []
    for i = 0 to 5
        slot = CreateObject("roSGNode", "Group")
        slot.translation = [i * (m.DIGIT_SLOT_WIDTH + m.DIGIT_SLOT_GAP), 0]

        bg = CreateObject("roSGNode", "Rectangle")
        bg.width = m.DIGIT_SLOT_WIDTH
        bg.height = m.DIGIT_SLOT_HEIGHT
        bg.color = m.SURFACE_DIM
        slot.appendChild(bg)

        lbl = CreateObject("roSGNode", "Label")
        lbl.text = ""
        lbl.width = m.DIGIT_SLOT_WIDTH
        lbl.height = m.DIGIT_SLOT_HEIGHT
        lbl.horizAlign = "center"
        lbl.vertAlign = "center"
        lbl.font = "font:LargeBoldSystemFont"
        lbl.color = m.TEXT_DEFAULT
        slot.appendChild(lbl)

        row.appendChild(slot)
        ' Store direct references rather than relying on findNode("slotLbl").
        ' SceneGraph's findNode does NOT scope to the calling node's subtree
        ' reliably across firmware — it can return the first match anywhere
        ' in the scene, which (with duplicate IDs across 6 sibling slots)
        ' silently breaks refresh. Direct refs avoid the question.
        m.digitSlots.push({ slot: slot, bg: bg, lbl: lbl })
    end for
end sub

sub buildKeypad()
    grid = m.top.findNode("keypadGroup")
    m.keypadCells = []

    for i = 0 to m.KEYPAD.Count() - 1
        row = i \ m.KEYPAD_COLS
        col = i - row * m.KEYPAD_COLS
        ch = m.KEYPAD[i].ch

        cell = CreateObject("roSGNode", "Group")
        cell.translation = [col * (m.KEYPAD_BTN_WIDTH + m.KEYPAD_BTN_GAP), row * (m.KEYPAD_BTN_HEIGHT + m.KEYPAD_BTN_GAP)]

        bg = CreateObject("roSGNode", "Rectangle")
        bg.id = "cellBg"
        bg.width = m.KEYPAD_BTN_WIDTH
        bg.height = m.KEYPAD_BTN_HEIGHT
        bg.color = m.SURFACE_DIM
        cell.appendChild(bg)

        lbl = CreateObject("roSGNode", "Label")
        lbl.id = "cellLbl"
        lbl.text = labelFor(ch)
        lbl.width = m.KEYPAD_BTN_WIDTH
        lbl.height = m.KEYPAD_BTN_HEIGHT
        lbl.horizAlign = "center"
        lbl.vertAlign = "center"
        lbl.font = "font:MediumBoldSystemFont"
        lbl.color = m.TEXT_DEFAULT
        cell.appendChild(lbl)

        grid.appendChild(cell)
        m.keypadCells.push({ node: cell, bg: bg, lbl: lbl, ch: ch })
    end for
end sub

function labelFor(ch as string) as string
    if ch = "*" then return "DEL"
    if ch = "#" then return "GO"
    return ch
end function

sub refreshKeypadFocus()
    for i = 0 to m.keypadCells.Count() - 1
        cell = m.keypadCells[i]
        if i = m.focusIndex then
            cell.bg.color = m.BRAND_YELLOW
            cell.lbl.color = m.TEXT_ON_FOCUS
        else
            cell.bg.color = m.SURFACE_DIM
            cell.lbl.color = m.TEXT_DEFAULT
        end if
    end for
end sub

sub refreshDigitSlots()
    for i = 0 to 5
        s = m.digitSlots[i]
        if i < Len(m.code) then
            s.lbl.text = Mid(m.code, i + 1, 1)
            s.bg.color = m.BRAND_YELLOW_SOFT
        else
            s.lbl.text = ""
            s.bg.color = m.SURFACE_DIM
        end if
    end for
end sub

sub applyKeypadChar(ch as string)
    print "[entry] applyKeypadChar ch="; ch; " code-before="; m.code
    if ch = "*" then
        if Len(m.code) > 0 then m.code = Left(m.code, Len(m.code) - 1)
    else if ch = "#" then
        if Len(m.code) = 6 then
            print "[entry] submitting code: "; m.code
            m.top.submittedCode = m.code
        end if
    else
        if Len(m.code) < 6 then m.code = m.code + ch
    end if
    print "[entry] code-after="; m.code
    refreshDigitSlots()
end sub

' Roku remote handling. We track focus ourselves rather than relying on
' SceneGraph's automatic focus traversal (which doesn't work cleanly with
' raw Group children).
'
' Key naming across Roku firmware versions is inconsistent — the "OK"
' button has been seen as "OK", "ok", and "select" — so we accept all
' three variants. Every key is also `print`-ed so telnet 8085 shows
' exactly what the remote is sending if anything misbehaves.
function onKeyEvent(key as string, press as boolean) as boolean
    print "[entry] onKeyEvent key="; key; " press="; press
    if not press then return false

    row = m.focusIndex \ m.KEYPAD_COLS
    col = m.focusIndex - row * m.KEYPAD_COLS

    lcKey = LCase(key)
    if lcKey = "up" then
        if row > 0 then row = row - 1
    else if lcKey = "down" then
        if row < m.KEYPAD_ROWS - 1 then row = row + 1
    else if lcKey = "left" then
        if col > 0 then col = col - 1
    else if lcKey = "right" then
        if col < m.KEYPAD_COLS - 1 then col = col + 1
    else if lcKey = "ok" or lcKey = "select" or lcKey = "enter" or lcKey = "play" then
        applyKeypadChar(m.KEYPAD[m.focusIndex].ch)
        return true
    else if lcKey = "back" then
        ' Quick delete on BACK — pressing it once clears the most recent
        ' digit. (MainScene handles "back to code entry" from the
        ' DisplayScene; here in the entry scene it would just exit the
        ' channel, which is a worse UX than backspacing.)
        applyKeypadChar("*")
        return true
    else
        return false
    end if

    m.focusIndex = row * m.KEYPAD_COLS + col
    refreshKeypadFocus()
    return true
end function
