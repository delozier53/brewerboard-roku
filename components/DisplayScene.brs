' DisplayScene — taplist render that mirrors the web display.
'
' Layout (1920x1080 FHD):
'   ┌────────────────────────┬─────────────────────────────────────┐
'   │   Column image         │   Header 1   |   Header 2           │
'   │   (slideshow)          │   ────────────────────────────       │
'   │                        │   [logo]  Name | Brewery       12oz │
'   │                        │           Style · ABV · IBU     $5  │
'   │                        │   ────────────────────────────       │
'   │                        │   ...                               │
'   └────────────────────────┴─────────────────────────────────────┘
'           this is a sample • here's another • anniversary
'
' Headers live INSIDE the tap-list panel. No global header bar / logo /
' status indicator. Footer scrolls all active messages across the
' bottom via an Animation node.

sub init()
    print "[display] init"
    m.API_BASE = "https://brewerboard.com"

    m.rootBg = m.top.findNode("rootBg")
    m.bodyContainer = m.top.findNode("bodyContainer")
    m.footerBg = m.top.findNode("footerBg")
    m.footerText = m.top.findNode("footerText")
    m.refreshTimer = m.top.findNode("refreshTimer")
    m.tickerAnim = m.top.findNode("tickerAnim")
    m.tickerInterp = m.top.findNode("tickerInterp")

    ' Layout constants (1920x1080 FHD).
    m.SCREEN_W = 1920
    m.SCREEN_H = 1080
    m.SIDE_MARGIN = 32         ' matches web paddingInline
    m.COLUMN_GAP = 32          ' matches web columnGap
    m.BODY_TOP = 24
    m.BODY_BOTTOM = 1000       ' just above footer
    m.BODY_HEIGHT = m.BODY_BOTTOM - m.BODY_TOP

    ' Beer row geometry.
    m.ROW_PADDING_Y = 12
    m.LOGO_BOX = 60
    m.LOGO_GAP = 14            ' logo → text gap
    m.PRICES_COL_W = 110       ' right column for size/price stack
    m.PRICES_GAP = 16

    ' Header section.
    m.HEADER_HEIGHT = 70

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

    m.rootBg.color = configHex(config, "background_color", "0x1C1917FF", 255)

    ' Rebuild body container from scratch each render.
    clearGroup(m.bodyContainer)

    layout = computeLayout(config, payload.images)

    if layout.hasImagePanel then
        renderImagePanel(layout)
    end if

    ' Distribute beers across the configured beer columns.
    beerColumns = splitBeers(payload.beers, layout)
    for ci = 0 to beerColumns.Count() - 1
        slot = layout.beerSlots[ci]
        renderTapListColumn(beerColumns[ci], payload.brewery_logo_url, payload.headers, slot, config, ci)
    end for

    renderFooter(payload.footers, config)
end sub

' ----- Layout computation -------------------------------------------------

function computeLayout(config as object, images as dynamic) as object
    columns = intField(config, "columns", 1)
    if columns < 1 then columns = 1
    if columns > 3 then columns = 3

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
    if config.column_image_position <> invalid and config.column_image_position = "left" then
        imagePos = "left"
    end if

    totalW = m.SCREEN_W - 2 * m.SIDE_MARGIN
    slotCount = columns
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
    while out.Count() < cols
        out.push([])
    end while
    return out
end function

' ----- Image panel --------------------------------------------------------

sub renderImagePanel(layout as object)
    slot = layout.imageSlot
    poster = CreateObject("roSGNode", "Poster")
    poster.uri = layout.imageUrls[0]
    poster.translation = [slot.x, slot.y]
    poster.width = slot.w
    poster.height = slot.h
    poster.loadDisplayMode = "scaleToFit"
    m.bodyContainer.appendChild(poster)
    ' Slideshow rotation across multiple imageUrls = v4 follow-up.
end sub

' ----- Tap list column ----------------------------------------------------

' Renders the header area at the top of the column (1 or 2 sub-columns),
' a divider line, and then beer rows below. `colIndex` is 0 for the first
' beer column (leftmost) and lets us decide whether to render headers
' (only the first beer column shows them, matching the web).
sub renderTapListColumn(beers as dynamic, breweryLogoUrl as dynamic, headers as dynamic, slot as object, config as object, colIndex as integer)
    container = CreateObject("roSGNode", "Group")
    container.translation = [slot.x, slot.y]
    m.bodyContainer.appendChild(container)

    y = 0
    if colIndex = 0 then
        headerH = renderHeaderArea(container, headers, slot.w, config)
        y = y + headerH
    end if

    if beers = invalid or beers.Count() = 0 then return

    nameFont = "font:LargeBoldSystemFont"
    detailFont = "font:MediumSystemFont"
    priceFont = "font:LargeBoldSystemFont"
    sizeFont = "font:MediumSystemFont"

    nameColor = configHex(config, "beer_name_color", "0xFFFFFFFF", 255)
    detailColor = configHex(config, "beer_detail_color", "0x9CA3AFFF", 255)
    priceColor = configHex(config, "price_color", "0xFBBF24FF", 255)

    showLabel = boolField(config, "show_label_image", true)
    showStyle = boolField(config, "show_style", true)
    showAbv = boolField(config, "show_abv", true)
    showIbu = boolField(config, "show_ibu", true)
    showDescription = boolField(config, "show_description", false)
    showDividers = boolField(config, "show_row_dividers", true)

    rowStyle = { nameFont: nameFont, detailFont: detailFont, priceFont: priceFont, sizeFont: sizeFont, nameColor: nameColor, detailColor: detailColor, priceColor: priceColor, showLabel: showLabel, showStyle: showStyle, showAbv: showAbv, showIbu: showIbu, showDescription: showDescription, showDividers: showDividers }

    ' Auto-fit: distribute extra vertical space evenly across rows so
    ' the list naturally fills the column height instead of clumping at
    ' the top with empty space below. (Roku system fonts come in fixed
    ' sizes — we can't scale them like the web's --fit-scale, so we
    ' scale the row padding/logo instead.)
    naturalRowH = computeNaturalRowHeight(showDescription)
    availableH = slot.h - y
    rowH = naturalRowH
    if availableH > naturalRowH * beers.Count() then
        rowH = Int(availableH / beers.Count())
    end if
    ' Cap the row height growth so logos don't become absurd on short
    ' beer lists.
    if rowH > naturalRowH * 2 then rowH = naturalRowH * 2

    for i = 0 to beers.Count() - 1
        beer = beers[i]
        isLast = (i = beers.Count() - 1)
        result = buildBeerRow(beer, breweryLogoUrl, isLast, slot.w, rowH, rowStyle)
        result.node.translation = [0, y]
        container.appendChild(result.node)
        y = y + result.height
        if y > slot.h then exit for
    end for
end sub

' Returns the natural (no-stretching) height of a beer row given the
' configured visibility toggles. Used to decide whether the column has
' room to stretch rows.
function computeNaturalRowHeight(showDescription as boolean) as integer
    nameLineH = 36
    detailLineH = 28
    contentH = nameLineH + detailLineH  ' assume detail is always shown
    if showDescription then contentH = contentH + detailLineH
    return 24 + contentH  ' 12 padding top + 12 padding bottom
end function

' Reactive font picker: shrinks the font alias step-by-step until the
' approximate rendered width fits within `availableW`. Avoids the "..."
' truncation we get when a long combined "Name | Source Brewery" string
' overflows the column.
'
' Char-width values calibrated against actual Roku TCL on-TV rendering:
' "Chumy the Whale  |  Skydance Brewing" (36 chars) was truncating at
' LargeBoldSystemFont in a 672 px column, which puts true avg width at
' ~21-22 px/char. Previous estimate of 17 was too generous and let the
' picker skip the down-step. Conservative values now — slight chance
' of dropping a step too early on the safer side.
function pickFitFont(text as string, availableW as integer) as string
    n = Len(text)
    if n = 0 then return "font:LargeBoldSystemFont"
    if n * 22 <= availableW then return "font:LargeBoldSystemFont"
    if n * 17 <= availableW then return "font:MediumBoldSystemFont"
    if n * 13 <= availableW then return "font:SmallBoldSystemFont"
    return "font:SmallBoldSystemFont"
end function

' Render the header sub-section: 1 or 2 header texts side by side, then
' a horizontal divider below. Returns the total height consumed.
function renderHeaderArea(container as object, headers as dynamic, width as integer, config as object) as integer
    if headers = invalid or headers.Count() = 0 then return 0

    ' Medium bold so "Sample Header Text 1" fits the half-column width
    ' (~440 px) without truncating. Large bold was rendering at ~26 px/char,
    ' too wide for the slot.
    headerFont = "font:MediumBoldSystemFont"
    headerColor = configHex(config, "header_color", "0xFFFFFFFF", 255)

    rowH = 50
    if headers.Count() >= 2 then
        ' Two columns of header text
        halfW = (width - 24) / 2  ' 24px gap between header cells
        h1 = createSimpleLabel(asString(headers[0].text), 0, 10, halfW, rowH, headerFont, headerColor, "center")
        h2 = createSimpleLabel(asString(headers[1].text), halfW + 24, 10, halfW, rowH, headerFont, headerColor, "center")
        container.appendChild(h1)
        container.appendChild(h2)
    else
        ' Single centered header
        h = createSimpleLabel(asString(headers[0].text), 0, 10, width, rowH, headerFont, headerColor, "center")
        container.appendChild(h)
    end if

    ' Divider line under the headers — matches web's border-b
    divider = CreateObject("roSGNode", "Rectangle")
    divider.width = width
    divider.height = 1
    divider.color = configHex(config, "font_color", "0xFFFFFF40", 64)
    divider.translation = [0, rowH + 14]
    container.appendChild(divider)

    return rowH + 24  ' content height + spacing below divider
end function

' ----- Beer row -----------------------------------------------------------
'
' Mirrors the web BeerCard:
'
'   [60x60 logo]   Beer Name | Source Brewery        12oz
'                  Style · ABV · IBU                  $5
'   ────────────────────────────────────────────────────────
'
' Returns { node, height } because Group has no settable height field.
function buildBeerRow(beer as object, breweryLogoUrl as dynamic, isLast as boolean, rowWidth as integer, targetRowHeight as integer, style as object) as object
    row = CreateObject("roSGNode", "Group")

    nameStr = asString(beer.name)
    sourceStr = ""
    if beer.source_brewery <> invalid and beer.source_brewery <> "" then
        showSrc = true
        if beer.show_source_brewery <> invalid and beer.show_source_brewery = false then showSrc = false
        if showSrc then sourceStr = asString(beer.source_brewery)
    end if

    styleStr = asString(beer.style)
    print "[display] row: name="; nameStr; " | src="; sourceStr; " | style="; styleStr

    labelSrc = ""
    if style.showLabel then
        if beer.label_url <> invalid and beer.label_url <> "" then
            labelSrc = beer.label_url
        else if breweryLogoUrl <> invalid then
            labelSrc = breweryLogoUrl
        end if
    end if

    ' --- Logo size (computed first so textX can react to it) ----------
    ' The logo grows with the stretched row height so tall rows don't
    ' have a tiny logo floating in the upper-left. Cap at 100 so it
    ' doesn't eat too much horizontal space — earlier 140 cap was
    ' overlapping the text area on stretched rows.
    logoSize = m.LOGO_BOX
    if labelSrc <> "" then
        targetLogo = targetRowHeight - 24
        if targetLogo > m.LOGO_BOX then logoSize = targetLogo
        if logoSize > 100 then logoSize = 100
    end if

    ' --- Column geometry inside the row -------------------------------
    ' textX is now driven by the ACTUAL logo size (was hardcoded to
    ' m.LOGO_BOX = 60, which meant text started at x=74 but the logo
    ' extended to x=127 on tall rows — visible overlap).
    leftX = 0
    if labelSrc <> "" then
        textX = logoSize + m.LOGO_GAP
    else
        textX = 0
    end if

    ' Decide whether to reserve a prices column.
    sizes = beer.beer_sizes
    visibleIds = beer._visible_size_ids
    pricesEnabled = false
    pricesList = invalid
    if sizes <> invalid and sizes.Count() > 0 then
        pricesList = filterSizes(sizes, visibleIds)
        if pricesList.Count() > 0 then pricesEnabled = true
    end if

    if pricesEnabled then
        pricesX = rowWidth - m.PRICES_COL_W
        textRight = pricesX - m.PRICES_GAP
    else
        pricesX = rowWidth
        textRight = rowWidth
    end if
    textWidth = textRight - textX

    ' --- Vertical layout (top-anchored, no vertAlign center) ----------
    ' Heights are based on observed Roku system-font cap heights:
    '   LargeBoldSystemFont ≈ 28 px text + descender
    '   MediumSystemFont    ≈ 22 px
    nameLineH = 36
    detailLineH = 28

    detailParts = []
    if style.showStyle and stringIsSet(beer.style) then detailParts.push(beer.style)
    if style.showAbv and numberIsSet(beer.abv) then detailParts.push(formatAbv(beer.abv) + " ABV")
    if style.showIbu and numberIsSet(beer.ibu) then detailParts.push(formatIbu(beer.ibu))
    detailLine = joinStrings(detailParts, " · ")

    descLine = ""
    if style.showDescription and stringIsSet(beer.description) then descLine = beer.description

    contentH = nameLineH
    if detailLine <> "" then contentH = contentH + detailLineH
    if descLine <> "" then contentH = contentH + detailLineH
    naturalH = m.ROW_PADDING_Y + contentH + m.ROW_PADDING_Y
    rowHeight = naturalH
    if targetRowHeight > naturalH then rowHeight = targetRowHeight

    ' If the row is stretched, center the content vertically within it.
    extraPad = Int((rowHeight - naturalH) / 2)
    topPad = m.ROW_PADDING_Y + extraPad

    ' --- Logo image (left) --------------------------------------------
    ' logoSize was computed up at the top of the function so textX
    ' could react to it. Center it vertically within the row.
    logoCenterY = Int((rowHeight - logoSize) / 2)
    if logoCenterY < topPad then logoCenterY = topPad
    if labelSrc <> "" then
        poster = CreateObject("roSGNode", "Poster")
        poster.uri = labelSrc
        poster.translation = [leftX, logoCenterY]
        poster.width = logoSize
        poster.height = logoSize
        poster.loadDisplayMode = "scaleToFit"
        row.appendChild(poster)
    end if

    ' --- Name + source brewery line (one combined label) --------------
    ' Reactive font: if the combined name+source string is wider than
    ' the available textWidth at the configured large bold font, drop
    ' down a step (medium bold) so we never truncate. This is the only
    ' way to fit "Chumy the Whale | Skydance Brewing" in a half-screen
    ' column without shipping a narrower TTF like Raleway.
    nameY = topPad
    nameDisplay = nameStr
    if sourceStr <> "" then nameDisplay = nameStr + "  |  " + sourceStr
    chosenFont = pickFitFont(nameDisplay, textWidth)
    nameLbl = createSimpleLabel(nameDisplay, textX, nameY, textWidth, nameLineH, chosenFont, style.nameColor, "left")
    row.appendChild(nameLbl)

    ' --- Detail line --------------------------------------------------
    detailY = nameY + nameLineH
    if detailLine <> "" then
        detailLbl = createSimpleLabel(detailLine, textX, detailY, textWidth, detailLineH, style.detailFont, style.detailColor, "left")
        row.appendChild(detailLbl)
    end if

    if descLine <> "" then
        descY = detailY
        if detailLine <> "" then descY = descY + detailLineH
        descLbl = createSimpleLabel(descLine, textX, descY, textWidth, detailLineH, style.detailFont, style.detailColor, "left")
        row.appendChild(descLbl)
    end if

    ' --- Size + price stack (right) -----------------------------------
    if pricesEnabled then
        renderPriceStack(row, pricesList, pricesX, m.PRICES_COL_W, topPad, style)
    end if

    ' --- Per-row divider ----------------------------------------------
    if style.showDividers and not isLast then
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

' Size + price stacked vertically in the right column. Matches the web
' photo: "12oz" above "$5", with the size in white and the price in the
' brand yellow.
sub renderPriceStack(row as object, sizes as object, pricesX as integer, pricesW as integer, topPad as integer, style as object)
    y = topPad
    stackH = 32
    for i = 0 to sizes.Count() - 1
        s = sizes[i]
        sizeLbl = createSimpleLabel(asString(s.label), 0, y, pricesW, stackH, style.sizeFont, style.nameColor, "right")
        sizeLbl.translation = [pricesX, y]
        row.appendChild(sizeLbl)

        priceLbl = createSimpleLabel(formatPrice(s.price), 0, y + stackH - 2, pricesW, stackH, style.priceFont, style.priceColor, "right")
        priceLbl.translation = [pricesX, y + stackH - 2]
        row.appendChild(priceLbl)

        y = y + 2 * stackH + 6
    end for
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
        m.tickerAnim.control = "stop"
        m.footerText.text = ""
        return
    end if

    ' Build the marquee text: messages joined by wide gaps (no bullets),
    ' with the whole set repeated TWICE in the label text. That gives us
    ' a seamless loop: we animate the translation by exactly one-set-
    ' width, and because copy #2 sits where copy #1 was at the end of
    ' the run, the loop point is visually identical and the user sees
    ' the first message reappear immediately after the last — no gap.
    SEP = "                    "  ' 20 spaces between messages
    singleSet = joinStrings(parts, SEP) + SEP
    text = singleSet + singleSet
    m.footerText.text = text
    m.footerText.color = configHex(config, "footer_color", "0xFFFFFFFF", 255)

    ' Approximate width of one set. ~13 px per char at MediumSystemFont.
    oneSetW = Len(singleSet) * 13
    if oneSetW < 1200 then oneSetW = 1200

    ' Animate translation by exactly one-set-width. y=1030 keeps the
    ' label pinned in the footer bar — the earlier build mistakenly
    ' passed y=20 here, which is why the marquee was rendering at the
    ' TOP of the screen instead of the footer.
    FOOTER_Y = 1030.0
    m.tickerInterp.keyValue = [ [0.0, FOOTER_Y], [-oneSetW * 1.0, FOOTER_Y] ]

    speed = intField(config, "ticker_speed", 150)
    if speed < 30 then speed = 30
    duration = oneSetW / speed
    if duration < 10 then duration = 10
    if duration > 120 then duration = 120
    m.tickerAnim.duration = duration

    m.tickerAnim.control = "start"
end sub

' ----- Small helpers -----------------------------------------------------

' Create a Label with explicit dimensions and top-anchored vertical
' alignment. Avoids vertAlign="center" which can hide text on some Roku
' firmware when the label's height isn't large enough to contain the
' rendered glyphs comfortably.
function createSimpleLabel(text as string, x as integer, y as integer, w as integer, h as integer, font as string, color as string, align as string) as object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = font
    lbl.color = color
    lbl.width = w
    lbl.height = h
    lbl.horizAlign = align
    lbl.vertAlign = "top"
    lbl.translation = [x, y]
    return lbl
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

' Replace the alpha byte of a Roku color string. Useful for "70% opacity
' of beer_name_color" without re-parsing the hex.
function withAlpha(rokuColor as string, newAlpha as integer) as string
    if Len(rokuColor) < 10 then return rokuColor
    return Left(rokuColor, 8) + intToHex2(newAlpha)
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

' Web's formatPrice strips trailing .00 to keep prices compact ("$5"
' instead of "$5.00"). Mirror that.
function formatPrice(price as dynamic) as string
    if price = invalid then return ""
    n = price
    if type(n) = "String" or type(n) = "roString" then n = Val(n)
    cents = Int(n * 100 + 0.5)
    dollars = Int(cents / 100)
    pennies = cents - dollars * 100
    if pennies = 0 then return "$" + dollars.toStr()
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

sub clearGroup(g as object)
    while g.getChildCount() > 0
        g.removeChild(g.getChild(0))
    end while
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press and (LCase(key) = "back") then
        m.top.requestSignOut = true
        return true
    end if
    return false
end function
