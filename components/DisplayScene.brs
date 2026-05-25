' DisplayScene — taplist render that mirrors the web display's structure:
'
'   Header text (centered, no logo / no "Live" status)
'   ┌────────────────────────┬─────────────────────────────────┐
'   │                        │  [img] TAP# Beer Name   $X.XX   │
'   │   Optional             │        Style · ABV · IBU        │
'   │   image panel          │  ─────────────────────────────  │
'   │   (slideshow if        │  [img] TAP# Beer Name   $X.XX   │
'   │    multiple images)    │        ...                      │
'   │                        │                                 │
'   └────────────────────────┴─────────────────────────────────┘
'                Scrolling ticker footer ──────────────────►
'
' computeLayout() reads screen.config (columns, column_image_position,
' column_image_ids) and screen images and decides the final layout
' (image panel left/right, beer columns split, or single full-width
' column). Everything in the body container is rebuilt on each
' renderPayload call — cheap and avoids partial-render artifacts.

sub init()
    print "[display] init"
    m.API_BASE = "https://brewerboard.com"

    m.rootBg = m.top.findNode("rootBg")
    m.headerText = m.top.findNode("headerText")
    m.bodyContainer = m.top.findNode("bodyContainer")
    m.footerClip = m.top.findNode("footerClip")
    m.footerText = m.top.findNode("footerText")
    m.refreshTimer = m.top.findNode("refreshTimer")
    m.tickerAnim = m.top.findNode("tickerAnim")
    m.tickerInterp = m.top.findNode("tickerInterp")

    ' --- Layout constants ----------------------------------------------
    m.SCREEN_W = 1920
    m.SCREEN_H = 1080
    m.SIDE_MARGIN = 40
    m.COLUMN_GAP = 30
    m.BODY_TOP = 120
    m.BODY_BOTTOM = 1020      ' just above the footer bg
    m.BODY_HEIGHT = m.BODY_BOTTOM - m.BODY_TOP

    ' Per-beer-row geometry (small image to keep the row tighter than v2).
    m.ROW_PADDING_Y = 10
    m.ROW_GAP = 4
    m.LABEL_BOX = 80
    m.LABEL_RIGHT_GAP = 16
    m.PRICES_BOX_WIDTH = 260
    m.PRICES_LEFT_GAP = 16

    ' Roku system-font alias sizes — see makeFont() comments for the full
    ' mapping. These pixel numbers are approximate (used only to size
    ' label heights so multi-line rows stack correctly).
    m.NAME_FONT_SIZE = 36
    m.DETAIL_FONT_SIZE = 24
    m.PRICE_FONT_SIZE = 28
    m.SIZE_LABEL_FONT_SIZE = 20
    m.FOOTER_FONT_SIZE = 24

    m.config = invalid

    m.top.observeField("screenCode", "onScreenCodeSet")
    m.refreshTimer.observeField("fire", "onRefreshTimerFired")
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
    if resp = invalid then return

    if resp.status = 404 then
        m.top.requestSignOut = true
        return
    end if
    if resp.status < 200 or resp.status >= 300 then return

    payload = ParseJson(resp.body)
    if payload = invalid then return
    renderPayload(payload)
end sub

sub renderPayload(payload as object)
    config = payload.screen.config
    m.config = config

    ' --- Root colors ---------------------------------------------------
    m.rootBg.color = configHex(config, "background_color", "0x1C1917FF", 255)

    ' --- Header text ---------------------------------------------------
    headerStr = ""
    if payload.headers <> invalid and payload.headers.Count() > 0 and payload.headers[0].text <> invalid then
        headerStr = payload.headers[0].text
    else if payload.screen.name <> invalid then
        headerStr = payload.screen.name
    end if
    m.headerText.text = headerStr
    m.headerText.color = configHex(config, "header_color", "0xFFFFFFFF", 255)

    ' --- Body: image panel + beer column(s) ----------------------------
    clearGroup(m.bodyContainer)
    layout = computeLayout(config, payload.images)

    ' Render image panel first (back of z-order if it overlaps anything;
    ' it shouldn't, since columns don't overlap).
    if layout.hasImagePanel then
        renderImagePanel(layout)
    end if

    ' Beer columns. Each "column slot" gets a slice of the beer array.
    beerColumns = splitBeers(payload.beers, layout)
    for ci = 0 to beerColumns.Count() - 1
        slot = layout.beerSlots[ci]
        renderBeerColumn(beerColumns[ci], payload.brewery_logo_url, slot)
    end for

    ' --- Footer ticker -------------------------------------------------
    renderFooter(payload.footers, config)
end sub

' ----- Layout computation -------------------------------------------------
'
' Returns:
'   {
'     columns:       1 | 2 | 3
'     hasImagePanel: bool
'     imagePos:      "left" | "right"
'     imageUrls:     [string]
'     imageSlot:     { x, y, w, h }   (only when hasImagePanel)
'     beerSlots:     [{ x, y, w, h }] (one per beer column)
'   }
function computeLayout(config as object, images as dynamic) as object
    columns = intField(config, "columns", 1)
    if columns < 1 then columns = 1
    if columns > 3 then columns = 3

    ' Collect image URLs the operator wants in the column-image slot.
    imageUrls = []
    if config.column_image_ids <> invalid and config.column_image_ids.Count() > 0 then
        for each id in config.column_image_ids
            url = findImageUrl(images, id)
            if url <> "" then imageUrls.push(url)
        end for
    end if
    if imageUrls.Count() = 0 and config.right_column_image_id <> invalid and config.right_column_image_id <> "" then
        url = findImageUrl(images, config.right_column_image_id)
        if url <> "" then imageUrls.push(url)
    end if

    hasImagePanel = (imageUrls.Count() > 0) and (columns >= 2)
    imagePos = "right"
    if config.column_image_position <> invalid then
        if config.column_image_position = "left" then imagePos = "left"
    end if

    ' Carve the body width into (image panel) + (beer columns).
    totalW = m.SCREEN_W - 2 * m.SIDE_MARGIN
    ' Number of slot-divisions (image counts as 1 slot in N-col layouts).
    slotCount = columns
    if hasImagePanel then
        beerColCount = columns - 1
    else
        beerColCount = columns
    end if
    slotW = (totalW - (slotCount - 1) * m.COLUMN_GAP) / slotCount

    slots = []
    x = m.SIDE_MARGIN
    for i = 0 to slotCount - 1
        slots.push({ x: x, y: m.BODY_TOP, w: slotW, h: m.BODY_HEIGHT })
        x = x + slotW + m.COLUMN_GAP
    end for

    layout = {
        columns: columns,
        hasImagePanel: hasImagePanel,
        imagePos: imagePos,
        imageUrls: imageUrls
    }

    if hasImagePanel then
        if imagePos = "left" then
            layout.imageSlot = slots[0]
            layout.beerSlots = []
            for i = 1 to slots.Count() - 1
                layout.beerSlots.push(slots[i])
            end for
        else
            layout.imageSlot = slots[slots.Count() - 1]
            layout.beerSlots = []
            for i = 0 to slots.Count() - 2
                layout.beerSlots.push(slots[i])
            end for
        end if
    else
        layout.beerSlots = slots
    end if

    return layout
end function

function findImageUrl(images as dynamic, id as string) as string
    if images = invalid then return ""
    for each img in images
        if img.id = id then return img.url
    end for
    return ""
end function

' Split the beer array into `beerSlots.Count()` chunks, in order. Web
' display does a column-major split (first N go to col 1, next N to col
' 2, etc.); we mirror that.
function splitBeers(beers as dynamic, layout as object) as object
    out = []
    if beers = invalid then beers = []
    cols = layout.beerSlots.Count()
    if cols <= 1 then
        out.push(beers)
        return out
    end if
    per = Int((beers.Count() + cols - 1) / cols)
    i = 0
    for c = 0 to cols - 1
        chunk = []
        endIdx = i + per - 1
        if endIdx > beers.Count() - 1 then endIdx = beers.Count() - 1
        for k = i to endIdx
            chunk.push(beers[k])
        end for
        out.push(chunk)
        i = endIdx + 1
        if i > beers.Count() - 1 then exit for
    end for
    ' Pad with empty arrays if beer count is less than column count.
    while out.Count() < cols
        out.push([])
    end while
    return out
end function

' ----- Renderers ----------------------------------------------------------

sub renderImagePanel(layout as object)
    slot = layout.imageSlot
    poster = CreateObject("roSGNode", "Poster")
    poster.uri = layout.imageUrls[0]
    poster.translation = [slot.x, slot.y]
    poster.width = slot.w
    poster.height = slot.h
    poster.loadDisplayMode = "scaleToFit"
    m.bodyContainer.appendChild(poster)
    ' Slideshow rotation across multiple imageUrls is a v4 follow-up.
end sub

sub renderBeerColumn(beers as dynamic, breweryLogoUrl as dynamic, slot as object)
    if beers = invalid or beers.Count() = 0 then return

    container = CreateObject("roSGNode", "Group")
    container.translation = [slot.x, 0]
    m.bodyContainer.appendChild(container)

    y = slot.y - m.BODY_TOP  ' relative to bodyContainer
    for i = 0 to beers.Count() - 1
        beer = beers[i]
        isLast = (i = beers.Count() - 1)
        result = buildBeerRow(beer, breweryLogoUrl, isLast, slot.w)
        result.node.translation = [0, y]
        container.appendChild(result.node)
        y = y + result.height
        if y > slot.y + slot.h then exit for
    end for
end sub

' Build one beer row. Layout (within the row Group):
'
'   [80px label]  TAP# Beer Name                           Size $X.XX
'                 Style · ABV% · IBU IBU                   Size $X.XX
'                 (description if config.show_description)
'   ────────────────────────────────────────────────────────────────
'
' Returns { node, height } because Group has no settable height field —
' assigning to row.height is silently dropped and reads back Invalid.
function buildBeerRow(beer as object, breweryLogoUrl as dynamic, isLast as boolean, rowWidth as integer) as object
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

    nameStr = asString(beer.name)
    styleStr = asString(beer.style)
    print "[display] beer name="; nameStr; " | style="; styleStr; " | abv="; asString(beer.abv); " | ibu="; asString(beer.ibu)

    ' --- Column geometry ----------------------------------------------
    textX = 0
    if showLabel and labelSrc <> "" then
        textX = m.LABEL_BOX + m.LABEL_RIGHT_GAP
    end if

    ' Decide whether to reserve a prices column at all. If this beer has
    ' no sizes, we hand back the prices-column width to the text area.
    sizes = beer.beer_sizes
    visibleIds = beer._visible_size_ids
    pricesEnabled = false
    pricesList = invalid
    if sizes <> invalid and sizes.Count() > 0 then
        pricesList = filterSizes(sizes, visibleIds)
        if pricesList.Count() > 0 then pricesEnabled = true
    end if

    pricesX = rowWidth
    pricesW = 0
    textRight = rowWidth
    if pricesEnabled then
        pricesW = m.PRICES_BOX_WIDTH
        pricesX = rowWidth - pricesW
        textRight = pricesX - m.PRICES_LEFT_GAP
    end if
    textWidth = textRight - textX

    ' --- Vertical budget ----------------------------------------------
    nameH = 44     ' fits font:LargestBoldSystemFont (~36px) comfortably
    detailH = 32   ' fits MediumSystemFont (~24px)

    detailParts = []
    if showStyle and stringIsSet(beer.style) then detailParts.push(beer.style)
    if showAbv and numberIsSet(beer.abv) then detailParts.push(formatAbv(beer.abv) + " ABV")
    if showIbu and numberIsSet(beer.ibu) then detailParts.push(formatIbu(beer.ibu))
    detailLine = joinStrings(detailParts, " · ")
    descriptionLine = ""
    if showDescription and stringIsSet(beer.description) then descriptionLine = beer.description

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

    ' --- Name + tap# line (directly on row, no nested group) ----------
    nameColor = configHex(m.config, "beer_name_color", "0xFFFFFFFF", 255)
    priceColor = configHex(m.config, "price_color", "0xFBBF24FF", 255)
    detailColor = configHex(m.config, "beer_detail_color", "0x9CA3AFFF", 255)

    nameY = m.ROW_PADDING_Y
    nameX = textX
    if showTap and beer.tap_number <> invalid then
        tapLbl = CreateObject("roSGNode", "Label")
        tapLbl.text = asString(beer.tap_number) + "."
        tapLbl.font = makeFont(m.NAME_FONT_SIZE, true)
        tapLbl.color = priceColor
        tapLbl.width = 60
        tapLbl.height = nameH
        tapLbl.horizAlign = "left"
        tapLbl.vertAlign = "center"
        tapLbl.translation = [nameX, nameY]
        row.appendChild(tapLbl)
        nameX = textX + 70
    end if

    nameLbl = CreateObject("roSGNode", "Label")
    nameLbl.text = nameStr
    nameLbl.font = makeFont(m.NAME_FONT_SIZE, true)
    nameLbl.color = nameColor
    nameLbl.width = textRight - nameX
    nameLbl.height = nameH
    nameLbl.horizAlign = "left"
    nameLbl.vertAlign = "center"
    nameLbl.translation = [nameX, nameY]
    row.appendChild(nameLbl)

    ' --- Detail line --------------------------------------------------
    nextY = nameY + nameH + m.ROW_GAP
    if detailLine <> "" then
        detailLbl = CreateObject("roSGNode", "Label")
        detailLbl.text = detailLine
        detailLbl.font = makeFont(m.DETAIL_FONT_SIZE, false)
        detailLbl.color = detailColor
        detailLbl.width = textWidth
        detailLbl.height = detailH
        detailLbl.horizAlign = "left"
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
        descLbl.horizAlign = "left"
        descLbl.vertAlign = "center"
        descLbl.translation = [textX, nextY]
        row.appendChild(descLbl)
    end if

    ' --- Prices column ------------------------------------------------
    if pricesEnabled then
        renderPriceColumn(row, pricesList, pricesX, pricesW, priceColor, detailColor)
    end if

    ' --- Per-row divider ----------------------------------------------
    if showDividers and not isLast then
        divider = CreateObject("roSGNode", "Rectangle")
        divider.width = rowWidth
        divider.height = intField(m.config, "row_divider_thickness", 1)
        opacityPct = intField(m.config, "row_divider_opacity", 100)
        alphaByte = Int((opacityPct / 100) * 255)
        if alphaByte > 255 then alphaByte = 255
        if alphaByte < 0 then alphaByte = 0
        divider.color = configHex(m.config, "row_divider_color", "0xFFFFFF55", alphaByte)
        divider.translation = [0, rowHeight - divider.height]
        row.appendChild(divider)
    end if

    return { node: row, height: rowHeight }
end function

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

sub renderPriceColumn(row as object, sizes as object, pricesX as integer, pricesW as integer, priceColor as string, sizeColor as string)
    priceGroup = CreateObject("roSGNode", "Group")
    priceGroup.translation = [pricesX, m.ROW_PADDING_Y]

    sizeColW = 100
    amountColW = pricesW - sizeColW - 12
    lineH = 36

    for i = 0 to sizes.Count() - 1
        s = sizes[i]
        y = i * lineH

        sizeLbl = CreateObject("roSGNode", "Label")
        sizeLbl.text = asString(s.label)
        sizeLbl.font = makeFont(m.SIZE_LABEL_FONT_SIZE, false)
        sizeLbl.color = sizeColor
        sizeLbl.width = sizeColW
        sizeLbl.horizAlign = "right"
        sizeLbl.translation = [0, y]
        priceGroup.appendChild(sizeLbl)

        amountLbl = CreateObject("roSGNode", "Label")
        amountLbl.text = formatPrice(s.price)
        amountLbl.font = makeFont(m.PRICE_FONT_SIZE, true)
        amountLbl.color = priceColor
        amountLbl.width = amountColW
        amountLbl.horizAlign = "left"
        amountLbl.translation = [sizeColW + 12, y]
        priceGroup.appendChild(amountLbl)
    end for

    row.appendChild(priceGroup)
end sub

' ----- Footer ticker ------------------------------------------------------

sub renderFooter(footers as dynamic, config as object)
    parts = []
    if footers <> invalid then
        for each f in footers
            if f.text <> invalid and f.text <> "" then parts.push(f.text)
        end for
    end if

    if parts.Count() = 0 then
        ' Stop the animation and clear text so nothing scrolls past.
        m.tickerAnim.control = "stop"
        m.footerText.text = ""
        return
    end if

    ' Join with a wide bullet separator and pad with extra spaces so the
    ' loop point isn't visibly abrupt.
    text = joinStrings(parts, "   •   ") + "        "
    m.footerText.text = text
    m.footerText.color = configHex(config, "footer_color", "0xFFFFFFFF", 255)
    m.footerText.font = makeFont(m.FOOTER_FONT_SIZE, false)

    ' Estimate width: avg ~14px per char at MediumSystemFont. Doesn't
    ' need to be exact — the animation just needs to overshoot the left
    ' edge so the text vanishes before looping.
    estW = Len(text) * 14
    if estW < 1200 then estW = 1200

    ' Rebuild the interpolator's keyValue with the right end-point.
    ' (Vector2DFieldInterpolator's keyValue is an array of [x, y] pairs.)
    m.tickerInterp.keyValue = [ [1920.0, 15.0], [-estW * 1.0, 15.0] ]

    ' Speed: ticker_speed is px/sec on the web; total distance is
    ' (1920 + estW). Duration = distance / speed, clamped 8s..60s.
    speed = intField(config, "ticker_speed", 150)
    if speed < 30 then speed = 30
    duration = (1920 + estW) / speed
    if duration < 8 then duration = 8
    if duration > 60 then duration = 60
    m.tickerAnim.duration = duration

    m.tickerAnim.control = "start"
end sub

' ----- Color + font helpers ----------------------------------------------

' Pick the closest Roku system-font alias to the requested px size.
' Sizes are approximate. Shipping a TTF would let us hit any pixel size
' — deferred.
function makeFont(size as integer, bold as boolean) as string
    if size >= 48 then
        if bold then return "font:HugeBoldSystemFont"
        return "font:HugeSystemFont"
    end if
    if size >= 32 then
        if bold then return "font:LargestBoldSystemFont"
        return "font:LargestSystemFont"
    end if
    if size >= 24 then
        if bold then return "font:LargeBoldSystemFont"
        return "font:LargeSystemFont"
    end if
    if size >= 18 then
        if bold then return "font:MediumBoldSystemFont"
        return "font:MediumSystemFont"
    end if
    if bold then return "font:SmallBoldSystemFont"
    return "font:SmallSystemFont"
end function

function configHex(config as object, key as string, fallback as string, alpha as integer) as string
    if config = invalid then return fallback
    hex = config[key]
    if hex = invalid or type(hex) <> "String" then return fallback
    cleaned = hex
    if Left(cleaned, 1) = "#" then cleaned = Mid(cleaned, 2)
    if Len(cleaned) < 6 then return fallback
    rgbPart = UCase(Mid(cleaned, 1, 6))
    return "0x" + rgbPart + intToHex2(alpha)
end function

function intToHex2(n as integer) as string
    chars = "0123456789ABCDEF"
    if n < 0 then n = 0
    if n > 255 then n = 255
    hi = Int(n / 16)
    lo = n - hi * 16
    return Mid(chars, hi + 1, 1) + Mid(chars, lo + 1, 1)
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
    return Len(asString(v)) > 0
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

' Remove every child of a Group. Used between renders so we don't pile
' up stale beer rows / image panels.
sub clearGroup(g as object)
    while g.getChildCount() > 0
        g.removeChild(g.getChild(0))
    end while
end sub

' ----- Remote handling ----------------------------------------------------

function onKeyEvent(key as string, press as boolean) as boolean
    if press and (LCase(key) = "back") then
        m.top.requestSignOut = true
        return true
    end if
    return false
end function
