' DisplayScene controller — owns the polling loop and beer-list rendering.
'
' Flow on mount:
'   1. Pull `screenCode` from interface (set by MainScene)
'   2. Kick off an initial DisplayLoaderTask to fetch payload
'   3. When task.response fires, parse + render
'   4. refreshTimer (every 30s) fires the same fetch
'
' If a fetch returns 404, we set requestSignOut so MainScene re-mounts the
' code-entry screen — same intent as the web display redirecting to
' /display when a code is invalid.

' API base lives on `m` so it's easy to swap for a Vercel preview or
' http://<your-mac-ip>:3000 when iterating locally. (BrightScript .brs
' files in SceneGraph components don't permit bare top-level assignments —
' only sub/function declarations.)

sub init()
    print "[display] init"
    m.API_BASE = "https://brewerboard.com"

    m.headerBg = m.top.findNode("headerBg")
    m.breweryLogo = m.top.findNode("breweryLogo")
    m.screenTitle = m.top.findNode("screenTitle")
    m.connectionLabel = m.top.findNode("connectionLabel")
    m.beerList = m.top.findNode("beerList")
    m.footerLabel = m.top.findNode("footerLabel")
    m.refreshTimer = m.top.findNode("refreshTimer")

    m.top.observeField("screenCode", "onScreenCodeSet")
    m.refreshTimer.observeField("fire", "onRefreshTimerFired")

    ' Allow OK-on-back-button as a sign-out shortcut. Roku remote BACK is
    ' handled by onKeyEvent below.

    setStatus("Connecting…")
end sub

sub onScreenCodeSet()
    fetchDisplayData()
end sub

sub onRefreshTimerFired()
    fetchDisplayData()
end sub

' Spawn a fresh DisplayLoaderTask each refresh. Tasks are single-shot in
' Roku — once `state` transitions to "done", reusing the same node is more
' trouble than just creating a new one.
sub fetchDisplayData()
    code = m.top.screenCode
    if code = invalid or Len(code) <> 6 then
        print "[display] no valid code, skipping fetch"
        return
    end if

    url = m.API_BASE + "/api/display/" + code
    print "[display] fetching "; url

    task = CreateObject("roSGNode", "DisplayLoaderTask")
    task.url = url
    task.observeField("response", "onLoaderResponse")
    task.control = "RUN"
    m.activeTask = task  ' keep a reference so the GC doesn't reap it
end sub

' Field observer: DisplayLoaderTask sets `response` when the HTTPS request
' completes. Shape: { status: int, body: string }
sub onLoaderResponse()
    if m.activeTask = invalid then return
    resp = m.activeTask.response
    m.activeTask = invalid
    if resp = invalid then
        setStatus("No response")
        return
    end if

    if resp.status = 404 then
        print "[display] screen not found, signing out"
        m.top.requestSignOut = true
        return
    end if

    if resp.status < 200 or resp.status >= 300 then
        setStatus("HTTP " + StrI(resp.status).Trim())
        return
    end if

    payload = ParseJson(resp.body)
    if payload = invalid then
        setStatus("Invalid JSON")
        return
    end if

    renderPayload(payload)
    setStatus("Live")
end sub

' Compose the header + beer list from the payload. Mirrors the data
' structure returned by /api/display/[code]/route.ts.
sub renderPayload(payload as object)
    ' Header: brewery logo + screen name
    if payload.brewery_logo_url <> invalid and payload.brewery_logo_url <> "" then
        m.breweryLogo.uri = payload.brewery_logo_url
    end if

    if payload.screen <> invalid and payload.screen.name <> invalid then
        m.screenTitle.text = payload.screen.name
    end if

    ' Footer: join all active footer messages on " • "
    if payload.footers <> invalid and payload.footers.Count() > 0 then
        parts = []
        for each f in payload.footers
            if f.text <> invalid then parts.push(f.text)
        end for
        m.footerLabel.text = JoinStrings(parts, "   •   ")
    else
        m.footerLabel.text = ""
    end if

    renderBeerList(payload.beers)
end sub

' Rebuild the beer-list group from scratch on each render. For ~20 beers
' this is cheap enough that diff'ing isn't worth the complexity.
sub renderBeerList(beers as dynamic)
    while m.beerList.getChildCount() > 0
        m.beerList.removeChild(m.beerList.getChild(0))
    end while

    if beers = invalid or beers.Count() = 0 then
        empty = CreateObject("roSGNode", "Label")
        empty.text = "No beers on tap yet."
        empty.color = "0xFFFFFF70"
        m.beerList.appendChild(empty)
        return
    end if

    rowHeight = 70
    for i = 0 to beers.Count() - 1
        beer = beers[i]
        row = buildBeerRow(beer, i, rowHeight)
        row.translation = [0, i * rowHeight]
        m.beerList.appendChild(row)
    end for
end sub

' One beer row: tap# | name | style | ABV | IBU. Columns are absolutely
' positioned for now; switch to a SceneGraph LayoutGroup once the visual
' design firms up.
function buildBeerRow(beer as object, index as integer, rowHeight as integer) as object
    row = CreateObject("roSGNode", "Group")

    ' Subtle alternating row background for readability on TV from across
    ' the room.
    bg = CreateObject("roSGNode", "Rectangle")
    bg.width = 1840
    bg.height = rowHeight - 6
    if index mod 2 = 0 then
        bg.color = "0xFFFFFF08"
    else
        bg.color = "0xFFFFFF03"
    end if
    row.appendChild(bg)

    addRowLabel(row, asString(beer.tap_number), 0, 60, "right", "font:MediumBoldSystemFont", "0xFFD24DFF")
    addRowLabel(row, asString(beer.name), 100, 700, "left", "font:MediumBoldSystemFont", "0xFFFFFFFF")
    addRowLabel(row, asString(beer.style), 820, 500, "left", "font:MediumSystemFont", "0xFFFFFFAA")
    addRowLabel(row, formatAbv(beer.abv), 1340, 160, "right", "font:MediumBoldSystemFont", "0xFFFFFFFF")
    addRowLabel(row, formatIbu(beer.ibu), 1520, 160, "right", "font:MediumBoldSystemFont", "0xFFFFFFAA")

    return row
end function

sub addRowLabel(parent as object, text as string, x as integer, w as integer, align as string, font as string, color as string)
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.width = w
    lbl.height = 60
    lbl.horizAlign = align
    lbl.vertAlign = "center"
    lbl.font = font
    lbl.color = color
    lbl.translation = [x, 0]
    parent.appendChild(lbl)
end sub

' ----- Formatters ---------------------------------------------------------

function asString(v as dynamic) as string
    if v = invalid then return ""
    return v.toStr()
end function

function formatAbv(abv as dynamic) as string
    if abv = invalid then return ""
    n = abv
    if type(n) = "roString" or type(n) = "String" then n = Val(n)
    if n = 0 then return ""
    ' Trim trailing .0 — show "6%" not "6.0%"
    txt = StrI(Int(n * 10)).Trim()
    whole = Int(n)
    frac = Int(n * 10) - whole * 10
    if frac = 0 then return whole.toStr() + "%"
    return whole.toStr() + "." + frac.toStr() + "%"
end function

function formatIbu(ibu as dynamic) as string
    if ibu = invalid then return ""
    n = ibu
    if type(n) = "roString" or type(n) = "String" then n = Val(n)
    if n = 0 then return ""
    return Int(n).toStr() + " IBU"
end function

function JoinStrings(parts as object, separator as string) as string
    out = ""
    for i = 0 to parts.Count() - 1
        if i > 0 then out = out + separator
        out = out + parts[i]
    end for
    return out
end function

' ----- Status helper ------------------------------------------------------

sub setStatus(msg as string)
    m.connectionLabel.text = msg
end sub

' ----- Remote-button handling --------------------------------------------
' Pressing BACK on the Roku remote while the display is up triggers a
' sign-out so the operator can re-pair the TV to a different screen code.

function onKeyEvent(key as string, press as boolean) as boolean
    if press and key = "back" then
        m.top.requestSignOut = true
        return true
    end if
    return false
end function
