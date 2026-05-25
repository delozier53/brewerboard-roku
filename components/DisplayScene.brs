' DisplayScene controller — taplist render that mirrors the web BeerCard:
'
'   [label]  TAP# Beer Name                          Size1 $X.XX
'            Style · ABV% · IBU IBU                  Size2 $X.XX
'   ────────────────────────────────────────────────────────────
'
' All colors and visibility toggles come from the screen config. See the
' XML for the v2 gap list. Polls /api/display/[code] every 30s; sets
' requestSignOut on a 404 so the user can re-pair.

' API base lives on `m` so it's easy to swap for a Vercel preview or
' http://<your-mac-ip>:3000 when iterating locally.

sub init()
    print "[display] init"
    m.API_BASE = "https://brewerboard.com"

    m.rootBg = m.top.findNode("rootBg")
    m.headerBg = m.top.findNode("headerBg")
    m.breweryLogo = m.top.findNode("breweryLogo")
    m.headerText = m.top.findNode("headerText")
    m.connectionLabel = m.top.findNode("connectionLabel")
    m.beerList = m.top.findNode("beerList")
    m.footerText = m.top.findNode("footerText")
    m.refreshTimer = m.top.findNode("refreshTimer")

    ' Layout constants (1920x1080 FHD coords). Beer-row column widths add
    ' up to 1840 = screen width minus 40px margins each side.
    m.ROW_PADDING_Y = 14
    m.ROW_GAP = 6
    m.LABEL_BOX = 90              ' square label/logo on the left
    m.LABEL_RIGHT_GAP = 18
    m.PRICES_BOX_WIDTH = 320      ' right-anchored prices column
    m.PRICES_LEFT_GAP = 18

    ' Font sizes — Roku doesn't auto-fit yet, so we hardcode TV-readable
    ' values. Web values (18 / 13 / 15) are tiny because they get scaled
    ' up via the auto-fit hook; we skip that for v2.
    m.NAME_FONT_SIZE = 36
    m.DETAIL_FONT_SIZE = 24
    m.PRICE_FONT_SIZE = 28
    m.SIZE_LABEL_FONT_SIZE = 20

    ' Track active payload so a re-render uses the latest config.
    m.config = invalid

    m.top.observeField("screenCode", "onScreenCodeSet")
    m.refreshTimer.observeField("fire", "onRefreshTimerFired")

    setStatus("Connecting…")
end sub

sub onScreenCodeSet()
    fetchDisplayData()
end sub

sub onRefreshTimerFired()
    fetchDisplayData()
end sub

sub fetchDisplayData()
    code = m.top.screenCode
    if code = invalid or Len(code) <> 6 then return
    url = m.API_BASE + "/api/display/" + code
    print "[display] fetching "; url

    task = CreateObject("roSGNode", "DisplayLoaderTask")
    task.url = url
    task.observeField("response", "onLoaderResponse")
    task.control = "RUN"
    m.activeTask = task
end sub

sub onLoaderResponse()
    if m.activeTask = invalid then return
    resp = m.activeTask.response
    m.activeTask = invalid
    if resp = invalid then
        setStatus("No response")
        return
    end if

    if resp.status = 404 then
        print "[display] 404, signing out"
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

sub renderPayload(payload as object)
    ' --- Apply config colors -----------------------------------------
    config = payload.screen.config
    m.config = config

    bgColor = configHex(config, "background_color", "0x1C1917FF", 255)
    m.rootBg.color = bgColor

    ' --- Header --------------------------------------------------------
    if payload.brewery_logo_url <> invalid and payload.brewery_logo_url <> "" then
        m.breweryLogo.uri = payload.brewery_logo_url
    end if

    ' Header text: prefer the operator's configured header texts (first
    ' one for v2 — multi-header grids land later); fall back to screen
    ' name so a screen without headers still labels itself.
    if payload.headers <> invalid and payload.headers.Count() > 0 and payload.headers[0].text <> invalid then
        m.headerText.text = payload.headers[0].text
    else if payload.screen.name <> invalid then
        m.headerText.text = payload.screen.name
    end if
    m.headerText.color = configHex(config, "header_color", "0xFFFFFFFF", 255)

    ' --- Footer --------------------------------------------------------
    if payload.footers <> invalid and payload.footers.Count() > 0 then
        parts = []
        for each f in payload.footers
            if f.text <> invalid then parts.push(f.text)
        end for
        m.footerText.text = joinStrings(parts, "   •   ")
    else
        m.footerText.text = ""
    end if
    m.footerText.color = configHex(config, "footer_color", "0xFFFFFFAA", 170)

    ' --- Beer rows -----------------------------------------------------
    renderBeerList(payload.beers, payload.brewery_logo_url)
end sub

sub renderBeerList(beers as dynamic, breweryLogoUrl as dynamic)
    while m.beerList.getChildCount() > 0
        m.beerList.removeChild(m.beerList.getChild(0))
    end while

    if beers = invalid or beers.Count() = 0 then
        empty = CreateObject("roSGNode", "Label")
        empty.text = "No beers on tap yet."
        empty.color = configHex(m.config, "font_color", "0xFFFFFFAA", 170)
        empty.font = "font:MediumSystemFont"
        m.beerList.appendChild(empty)
        return
    end if

    ' Compute each row's height once (driven by content lines) and lay
    ' rows out vertically by accumulating Y. buildBeerRow returns
    ' { node, height } because SceneGraph's Group node has no settable
    ' `height` field — assigning to it is silently dropped, and reading
    ' it back returns Invalid (which would crash this loop).
    y = 0
    for i = 0 to beers.Count() - 1
        beer = beers[i]
        isLast = (i = beers.Count() - 1)
        result = buildBeerRow(beer, breweryLogoUrl, isLast)
        result.node.translation = [0, y]
        m.beerList.appendChild(result.node)
        y = y + result.height
        ' Avoid running off the bottom of the screen. Beer area is
        ' y=140..1030 = 890px tall.
        if y > 880 then exit for
    end for
end sub

' Build one beer row. Each row is a Group whose `height` field we set
' so the caller can stack rows. Layout (no description):
'
'   [80px x 80px label]  [text block]  [prices grid]
'      (optional)        flex-grows    right-aligned
'
function buildBeerRow(beer as object, breweryLogoUrl as dynamic, isLast as boolean) as object
    row = CreateObject("roSGNode", "Group")

    showLabel = boolField(m.config, "show_label_image", true)
    showTap = boolField(m.config, "show_tap_numbers", true)
    showStyle = boolField(m.config, "show_style", true)
    showAbv = boolField(m.config, "show_abv", true)
    showIbu = boolField(m.config, "show_ibu", true)
    showDescription = boolField(m.config, "show_description", false)
    showDividers = boolField(m.config, "show_row_dividers", true)

    labelSrc = ""
    if beer.label_url <> invalid and beer.label_url <> "" then
        labelSrc = beer.label_url
    else if breweryLogoUrl <> invalid then
        labelSrc = breweryLogoUrl
    end if

    ' Resolve text and column geometry ----------------------------------
    rowWidth = 1840
    textX = 0
    if showLabel and labelSrc <> "" then
        textX = m.LABEL_BOX + m.LABEL_RIGHT_GAP
    end if
    pricesX = rowWidth - m.PRICES_BOX_WIDTH
    textWidth = pricesX - textX - m.PRICES_LEFT_GAP

    ' Detail line: "Style · X.X% ABV · YY IBU" — only parts that are
    ' configured + present.
    detailParts = []
    if showStyle and stringIsSet(beer.style) then detailParts.push(beer.style)
    if showAbv and numberIsSet(beer.abv) then detailParts.push(formatAbv(beer.abv) + " ABV")
    if showIbu and numberIsSet(beer.ibu) then detailParts.push(formatIbu(beer.ibu))
    detailLine = joinStrings(detailParts, " · ")

    descriptionLine = ""
    if showDescription and stringIsSet(beer.description) then descriptionLine = beer.description

    ' --- Vertical budget ----------------------------------------------
    ' Heights are approximate — line-height ~1.2 of font size, rounded.
    nameH = Int(m.NAME_FONT_SIZE * 1.2)
    detailH = Int(m.DETAIL_FONT_SIZE * 1.2)

    contentH = nameH
    if detailLine <> "" then contentH = contentH + m.ROW_GAP + detailH
    if descriptionLine <> "" then contentH = contentH + m.ROW_GAP + detailH
    rowHeight = m.ROW_PADDING_Y + contentH + m.ROW_PADDING_Y

    ' --- Label image (left column) ------------------------------------
    if showLabel and labelSrc <> "" then
        poster = CreateObject("roSGNode", "Poster")
        poster.uri = labelSrc
        poster.translation = [0, m.ROW_PADDING_Y]
        poster.width = m.LABEL_BOX
        poster.height = m.LABEL_BOX
        poster.loadDisplayMode = "scaleToFit"
        row.appendChild(poster)
    end if

    ' --- Name + tap# line ---------------------------------------------
    nameColor = configHex(m.config, "beer_name_color", "0xFFFFFFFF", 255)
    priceColor = configHex(m.config, "price_color", "0xFBBF24FF", 255)

    nameRowGroup = CreateObject("roSGNode", "Group")
    nameRowGroup.translation = [textX, m.ROW_PADDING_Y]

    nameX = 0
    if showTap and beer.tap_number <> invalid then
        tapLbl = CreateObject("roSGNode", "Label")
        tapLbl.text = asString(beer.tap_number) + "."
        tapLbl.font = makeFont(m.NAME_FONT_SIZE, true)
        tapLbl.color = priceColor
        tapLbl.height = nameH
        tapLbl.vertAlign = "center"
        tapLbl.translation = [0, 0]
        nameRowGroup.appendChild(tapLbl)
        ' Reserve ~70px for "99." then a gap.
        nameX = 70
    end if

    nameLbl = CreateObject("roSGNode", "Label")
    nameLbl.text = asString(beer.name)
    nameLbl.font = makeFont(m.NAME_FONT_SIZE, true)
    nameLbl.color = nameColor
    nameLbl.width = textWidth - nameX
    nameLbl.height = nameH
    nameLbl.vertAlign = "center"
    nameLbl.translation = [nameX, 0]
    nameRowGroup.appendChild(nameLbl)

    row.appendChild(nameRowGroup)

    ' --- Detail line --------------------------------------------------
    nextY = m.ROW_PADDING_Y + nameH + m.ROW_GAP
    detailColor = configHex(m.config, "beer_detail_color", "0x9CA3AFFF", 255)
    if detailLine <> "" then
        detailLbl = CreateObject("roSGNode", "Label")
        detailLbl.text = detailLine
        detailLbl.font = makeFont(m.DETAIL_FONT_SIZE, false)
        detailLbl.color = detailColor
        detailLbl.width = textWidth
        detailLbl.height = detailH
        detailLbl.vertAlign = "center"
        detailLbl.translation = [textX, nextY]
        row.appendChild(detailLbl)
        nextY = nextY + detailH + m.ROW_GAP
    end if

    if descriptionLine <> "" then
        descLbl = CreateObject("roSGNode", "Label")
        descLbl.text = descriptionLine
        descLbl.font = makeFont(m.DETAIL_FONT_SIZE, false)
        descLbl.color = detailColor
        descLbl.width = textWidth
        descLbl.height = detailH
        descLbl.vertAlign = "center"
        descLbl.translation = [textX, nextY]
        ' Single-line for v2; could enable wrap later if it doesn't blow
        ' up the row-height calc.
        row.appendChild(descLbl)
    end if

    ' --- Prices column (right-anchored) -------------------------------
    sizes = beer.beer_sizes
    visibleIds = beer._visible_size_ids
    if sizes <> invalid and sizes.Count() > 0 then
        renderable = filterSizes(sizes, visibleIds)
        if renderable.Count() > 0 then
            renderPriceColumn(row, renderable, pricesX, priceColor, detailColor)
        end if
    end if

    ' --- Per-row divider line at the bottom ---------------------------
    if showDividers and not isLast then
        divider = CreateObject("roSGNode", "Rectangle")
        divider.width = rowWidth
        divider.height = intField(m.config, "row_divider_thickness", 1)
        opacityPct = intField(m.config, "row_divider_opacity", 100)
        ' Alpha byte: opacity 0–100 → 0–255
        alphaByte = Int((opacityPct / 100) * 255)
        if alphaByte > 255 then alphaByte = 255
        if alphaByte < 0 then alphaByte = 0
        divider.color = configHex(m.config, "row_divider_color", "0xFFFFFF55", alphaByte)
        divider.translation = [0, rowHeight - divider.height]
        row.appendChild(divider)
    end if

    ' Return both the node and its computed height. We can't stash the
    ' height on the Group itself — SceneGraph silently drops writes to
    ' unknown fields, so `row.height = rowHeight` would leave the height
    ' Invalid when read back in renderBeerList.
    return { node: row, height: rowHeight }
end function

' Filter sizes by visible_ids if the operator has hidden some.
function filterSizes(sizes as object, visibleIds as dynamic) as object
    if visibleIds = invalid or visibleIds.Count() = 0 then return sizes
    out = []
    for each s in sizes
        for each vid in visibleIds
            if s.id = vid then
                out.push(s)
                exit for
            end if
        end for
    end for
    return out
end function

' Render the per-size price rows on the right side of a beer row. Lays
' out one per line: "Size $X.XX" — the web does a multi-column grid for
' 4+ sizes; we keep it single-column for v2.
sub renderPriceColumn(row as object, sizes as object, pricesX as integer, priceColor as string, sizeColor as string)
    priceGroup = CreateObject("roSGNode", "Group")
    priceGroup.translation = [pricesX, m.ROW_PADDING_Y]

    sizeColWidth = 120
    amountColWidth = m.PRICES_BOX_WIDTH - sizeColWidth - 12
    lineH = Int(m.PRICE_FONT_SIZE * 1.2)

    for i = 0 to sizes.Count() - 1
        s = sizes[i]
        y = i * lineH

        sizeLbl = CreateObject("roSGNode", "Label")
        sizeLbl.text = asString(s.label)
        sizeLbl.font = makeFont(m.SIZE_LABEL_FONT_SIZE, false)
        sizeLbl.color = sizeColor
        sizeLbl.width = sizeColWidth
        sizeLbl.horizAlign = "right"
        sizeLbl.translation = [0, y]
        priceGroup.appendChild(sizeLbl)

        amountLbl = CreateObject("roSGNode", "Label")
        amountLbl.text = formatPrice(s.price)
        amountLbl.font = makeFont(m.PRICE_FONT_SIZE, true)
        amountLbl.color = priceColor
        amountLbl.width = amountColWidth
        amountLbl.horizAlign = "left"
        amountLbl.translation = [sizeColWidth + 12, y]
        priceGroup.appendChild(amountLbl)
    end for

    row.appendChild(priceGroup)
end sub

' ----- Color + font helpers ----------------------------------------------

' Build a custom-sized Font node. SceneGraph's named system fonts (e.g.
' "font:MediumBoldSystemFont") don't take a size argument, so for any
' size we want we have to instantiate a Font node ourselves.
function makeFont(size as integer, bold as boolean) as object
    font = CreateObject("roSGNode", "Font")
    font.size = size
    if bold then
        font.uri = "common:/Fonts/Roboto-Bold.ttf"
    else
        font.uri = "common:/Fonts/Roboto-Regular.ttf"
    end if
    return font
end function

' Read a #RRGGBB-style hex color from config and turn it into Roku's
' 0xRRGGBBAA format. Falls back to `fallback` (already in Roku format)
' when the field is missing or invalid.
function configHex(config as object, key as string, fallback as string, alpha as integer) as string
    if config = invalid then return fallback
    hex = config[key]
    if hex = invalid or type(hex) <> "String" then return fallback
    cleaned = hex
    if Left(cleaned, 1) = "#" then cleaned = Mid(cleaned, 2)
    if Len(cleaned) < 6 then return fallback
    rgbPart = UCase(Mid(cleaned, 1, 6))
    aHex = StrI(alpha, 16)
    aHex = aHex.Trim()
    if Len(aHex) = 1 then aHex = "0" + aHex
    return "0x" + rgbPart + UCase(aHex)
end function

function boolField(config as object, key as string, fallback as boolean) as boolean
    if config = invalid then return fallback
    v = config[key]
    if v = invalid then return fallback
    if type(v) = "Boolean" then return v
    return fallback
end function

function intField(config as object, key as string, fallback as integer) as integer
    if config = invalid then return fallback
    v = config[key]
    if v = invalid then return fallback
    if type(v) = "Integer" or type(v) = "Float" or type(v) = "Double" then return Int(v)
    return fallback
end function

' ----- String + format helpers -------------------------------------------

function asString(v as dynamic) as string
    if v = invalid then return ""
    if type(v) = "String" or type(v) = "roString" then return v
    return v.toStr()
end function

function stringIsSet(v as dynamic) as boolean
    if v = invalid then return false
    s = asString(v)
    return Len(s) > 0
end function

function numberIsSet(v as dynamic) as boolean
    if v = invalid then return false
    if type(v) = "Integer" or type(v) = "Float" or type(v) = "Double" then return v > 0
    if type(v) = "String" or type(v) = "roString" then return Val(v) > 0
    return false
end function

function formatAbv(abv as dynamic) as string
    if abv = invalid then return ""
    n = abv
    if type(n) = "String" or type(n) = "roString" then n = Val(n)
    if n = 0 then return ""
    whole = Int(n)
    tenths = Int(n * 10) - whole * 10
    if tenths = 0 then return whole.toStr() + "%"
    return whole.toStr() + "." + tenths.toStr() + "%"
end function

function formatIbu(ibu as dynamic) as string
    if ibu = invalid then return ""
    n = ibu
    if type(n) = "String" or type(n) = "roString" then n = Val(n)
    if n = 0 then return ""
    return Int(n).toStr() + " IBU"
end function

' Match the web's formatPrice — 2-decimal dollars with `$` prefix.
function formatPrice(price as dynamic) as string
    if price = invalid then return ""
    n = price
    if type(n) = "String" or type(n) = "roString" then n = Val(n)
    cents = Int(n * 100 + 0.5)
    dollars = Int(cents / 100)
    pennies = cents - dollars * 100
    penniesStr = pennies.toStr()
    if Len(penniesStr) = 1 then penniesStr = "0" + penniesStr
    return "$" + dollars.toStr() + "." + penniesStr
end function

function joinStrings(parts as object, separator as string) as string
    out = ""
    for i = 0 to parts.Count() - 1
        if i > 0 then out = out + separator
        out = out + parts[i]
    end for
    return out
end function

' ----- Status + remote handling ------------------------------------------

sub setStatus(msg as string)
    m.connectionLabel.text = msg
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press and (LCase(key) = "back") then
        m.top.requestSignOut = true
        return true
    end if
    return false
end function
