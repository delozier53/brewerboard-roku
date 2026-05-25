' CodeEntryScene — 6-digit pin entry with a custom-rendered D-pad keypad.
'
' Layout (all coordinates in 1920x1080 FHD space):
'
'   [_] [_] [_] [_] [_] [_]      <- 6 digit slots
'
'    1   2   3
'    4   5   6
'    7   8   9
'   DEL  0   GO                  <- 4x3 keypad
'
' Why custom keypad cells instead of SceneGraph's Button node?
' Button nodes silently mis-render text on some Roku firmware (shows up
' as a tiny dot on TCL Roku TVs we tested). Rolling our own with
' Rectangle + Label is more code but renders identically across devices
' and gives us full control over focus styling.
'
' Focus state lives on `m.focusIndex` (0–11). onKeyEvent translates the
' Roku remote's D-pad into row/col arithmetic and re-renders the focused
' cell on every change.

sub init()
    print "[entry] init"
    m.code = ""
    m.focusIndex = 0  ' index into KEYPAD layout below

    ' --- Layout constants ----------------------------------------------
    m.DIGIT_SLOT_WIDTH = 130
    m.DIGIT_SLOT_HEIGHT = 160
    m.DIGIT_SLOT_GAP = 16

    m.KEYPAD_BTN_WIDTH = 180
    m.KEYPAD_BTN_HEIGHT = 110
    m.KEYPAD_BTN_GAP = 20
    m.KEYPAD_COLS = 3
    m.KEYPAD_ROWS = 4

    ' --- Brand palette -------------------------------------------------
    ' Amber matches the web app's `--brand` accent. Adjust here if/when
    ' the brand color changes — every focused element references these.
    m.BRAND_AMBER = "0xF59E0BFF"
    m.BRAND_AMBER_SOFT = "0xF59E0B33"  ' 20% alpha for filled-slot bg
    m.SURFACE_DIM = "0xFFFFFF14"
    m.SURFACE_FOCUS_BG = "0xF59E0BFF"
    m.TEXT_ON_FOCUS = "0x0A0A0AFF"
    m.TEXT_DEFAULT = "0xFFFFFFFF"
    m.TEXT_MUTED = "0xFFFFFFAA"

    ' --- Keypad data layout --------------------------------------------
    ' Index order is row-major: indexes 0-2 = row 0, 3-5 = row 1, etc.
    ' Each entry has a single-char `ch` used both as the visible label
    ' (transformed via labelFor) and the action key. "*" = DEL, "#" = GO.
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

' Render 6 digit slots. Each slot is Group { borderRect + bgRect + label }.
' Border vs bg gives us a "filled" visual state (amber tint when a digit
' lives in the slot) without redrawing the layout.
sub buildDigitSlots()
    row = m.top.findNode("digitRow")
    m.digitSlots = []
    for i = 0 to 5
        slot = CreateObject("roSGNode", "Group")
        slot.translation = [i * (m.DIGIT_SLOT_WIDTH + m.DIGIT_SLOT_GAP), 0]

        bg = CreateObject("roSGNode", "Rectangle")
        bg.id = "slotBg"
        bg.width = m.DIGIT_SLOT_WIDTH
        bg.height = m.DIGIT_SLOT_HEIGHT
        bg.color = m.SURFACE_DIM
        slot.appendChild(bg)

        lbl = CreateObject("roSGNode", "Label")
        lbl.id = "slotLbl"
        lbl.text = ""
        lbl.width = m.DIGIT_SLOT_WIDTH
        lbl.height = m.DIGIT_SLOT_HEIGHT
        lbl.horizAlign = "center"
        lbl.vertAlign = "center"
        lbl.font = "font:LargeBoldSystemFont"
        lbl.color = m.TEXT_DEFAULT
        slot.appendChild(lbl)

        row.appendChild(slot)
        m.digitSlots.push(slot)
    end for
end sub

' Render the 4x3 keypad as custom Group cells. We do NOT use Button —
' see header comment for the firmware-compat rationale.
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

' Translate the internal sentinel chars to human labels.
function labelFor(ch as string) as string
    if ch = "*" then return "DEL"
    if ch = "#" then return "GO"
    return ch
end function

' Repaint every keypad cell's bg/text colors so only the focused one is
' highlighted. Cheap to call on every D-pad event.
sub refreshKeypadFocus()
    for i = 0 to m.keypadCells.Count() - 1
        cell = m.keypadCells[i]
        if i = m.focusIndex then
            cell.bg.color = m.SURFACE_FOCUS_BG
            cell.lbl.color = m.TEXT_ON_FOCUS
        else
            cell.bg.color = m.SURFACE_DIM
            cell.lbl.color = m.TEXT_DEFAULT
        end if
    end for
end sub

' Paint each digit-slot label + bg based on current m.code. Filled slots
' get an amber-tinted bg so the user can see at a glance how many digits
' they've entered, even from across the room.
sub refreshDigitSlots()
    for i = 0 to 5
        slot = m.digitSlots[i]
        lbl = slot.findNode("slotLbl")
        bg = slot.findNode("slotBg")
        if i < Len(m.code) then
            lbl.text = Mid(m.code, i + 1, 1)
            bg.color = m.BRAND_AMBER_SOFT
        else
            lbl.text = ""
            bg.color = m.SURFACE_DIM
        end if
    end for
end sub

sub applyKeypadChar(ch as string)
    if ch = "*" then
        ' DEL — remove last digit
        if Len(m.code) > 0 then m.code = Left(m.code, Len(m.code) - 1)
    else if ch = "#" then
        ' GO — submit if full, otherwise ignore
        if Len(m.code) = 6 then
            print "[entry] submitting code: "; m.code
            m.top.submittedCode = m.code
        end if
    else
        if Len(m.code) < 6 then m.code = m.code + ch
    end if
    refreshDigitSlots()
end sub

' Roku remote handling. We track focus ourselves rather than relying on
' SceneGraph's automatic focus-traversal (which doesn't work cleanly with
' raw Group children).
function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false

    row = m.focusIndex \ m.KEYPAD_COLS
    col = m.focusIndex - row * m.KEYPAD_COLS

    if key = "up" then
        if row > 0 then row = row - 1
    else if key = "down" then
        if row < m.KEYPAD_ROWS - 1 then row = row + 1
    else if key = "left" then
        if col > 0 then col = col - 1
    else if key = "right" then
        if col < m.KEYPAD_COLS - 1 then col = col + 1
    else if key = "OK" or key = "play" then
        applyKeypadChar(m.KEYPAD[m.focusIndex].ch)
        return true
    else if key = "back" then
        ' Treat BACK as a quick delete shortcut.
        applyKeypadChar("*")
        return true
    else
        return false
    end if

    m.focusIndex = row * m.KEYPAD_COLS + col
    refreshKeypadFocus()
    return true
end function
