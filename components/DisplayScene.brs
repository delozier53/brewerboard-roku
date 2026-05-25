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
    ' Hit the www. host directly. The apex (brewerboard.com) returns a
    ' 308 redirect to www., which Roku's roUrlTransfer DOES follow but
    ' some intermediary caches may be holding the redirect target with
    ' stale data even when the no-store header should prevent it. Using
    ' the canonical host removes the extra hop entirely.
    m.API_BASE = "https://www.brewerboard.com"

    m.rootBg = m.top.findNode("rootBg")
    m.bodyContainer = m.top.findNode("bodyContainer")
    m.footerBg = m.top.findNode("footerBg")
    m.footerText = m.top.findNode("footerText")
    m.refreshTimer = m.top.findNode("refreshTimer")
    m.slideshowTimer = m.top.findNode("slideshowTimer")
    m.tickerAnim = m.top.findNode("tickerAnim")
    m.tickerInterp = m.top.findNode("tickerInterp")

    m.slideshowImages = []
    m.slideshowIndex = 0
    m.slideshowPoster = invalid

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
    m.slideshowTimer.observeField("fire", "onSlideshowTick")
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
    ' Cache-bust with a timestamp query param so no intermediary
    ' (Vercel edge, ISP transparent cache, roUrlTransfer's own pool)
    ' can hand us a stale response. The server treats unknown query
    ' params as no-ops.
    cacheBust = "?_t=" + (CreateObject("roDateTime").AsSeconds()).toStr()
    url = m.API_BASE + "/api/display/" + code + cacheBust
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

    ' Filter to only the headers the operator has flipped ON in the
    ' dashboard. Web uses is_active on header rows; we accept a couple
    ' of variant names defensively so a schema rename doesn't break us
    ' silently.
    activeHeaders = filterActiveHeaders(payload.headers)

    headerStr = ""
    if activeHeaders.Count() > 0 and activeHeaders[0].text <> invalid then headerStr = activeHeaders[0].text
    colImgCount = 0
    if config.column_image_ids <> invalid then colImgCount = config.column_image_ids.Count()
    print "[display] render: cols="; config.columns; " bg="; config.background_color; " header[0]="; headerStr; " active_headers="; activeHeaders.Count(); " column_image_ids="; colImgCount

    m.rootBg.color = configHex(config, "background_color", "0x1C1917FF", 255)

    ' Rebuild body container from scratch each render.
    clearGroup(m.bodyContainer)

    layout = computeLayout(config, payload.images)

    if layout.hasImagePanel then
        renderImagePanel(layout)
    end if

    ' Header bar spans the FULL tap-list area (union of all beer-column
    ' slot widths), not just the first column. Web puts the <header>
    ' inside the tap-list panel which is a single flex container above
    ' all the rendered beer cards.
    headerH = 0
    if activeHeaders.Count() > 0 then
        headerArea = computeHeaderArea(layout)
        renderHeaderArea(activeHeaders, headerArea, config)
        headerH = headerArea.h
    end if

    ' Distribute beers across the configured beer columns. Slots are
    ' offset down by header height so we don't render over the headers.
    beerColumns = splitBeers(payload.beers, layout)
    for ci = 0 to beerColumns.Count() - 1
        slot = layout.beerSlots[ci]
        offsetSlot = { x: slot.x, y: slot.y + headerH, w: slot.w, h: slot.h - headerH }
        renderTapListColumn(beerColumns[ci], payload.brewery_logo_url, offsetSlot, config)
    end for

    renderFooter(payload.footers, config)
end sub

' Header is only rendered for headers the operator has set is_active=true.
' Accept variant field names defensively in case the API ever renames.
function filterActiveHeaders(headers as dynamic) as object
    out = []
    if headers = invalid then return out
    for each h in headers
        if isHeaderActive(h) then out.push(h)
    end for
    return out
end function

function isHeaderActive(h as object) as boolean
    if h = invalid then return false
    if h.is_active <> invalid and type(h.is_active) = "Boolean" then return h.is_active
    if h.active <> invalid and type(h.active) = "Boolean" then return h.active
    if h.is_visible <> invalid and type(h.is_visible) = "Boolean" then return h.is_visible
    ' If no toggle field is present in the schema at all, default to
    ' showing the header. (Prevents headers from disappearing if the
    ' schema simply doesn't track an active flag.)
    return true
end function

' Bounding box of the tap-list-area = union of every beer-column slot.
' When the image panel is on one side, the tap-list area is the OTHER
' side; with no image, it spans the full body width.
function computeHeaderArea(layout as object) as object
    leftX = layout.beerSlots[0].x
    rightX = leftX + layout.beerSlots[0].w
    for each s in layout.beerSlots
        if s.x < leftX then leftX = s.x
        if s.x + s.w > rightX then rightX = s.x + s.w
    end for
    return { x: leftX, y: m.BODY_TOP, w: rightX - leftX, h: m.HEADER_HEIGHT }
end function

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

    ' Filter out URLs that Roku's Poster can't render (videos). The
    ' web's ColumnImageSlideshow does the same — videos need a Video
    ' node with content metadata, which we haven't wired up yet.
    images = []
    for each url in layout.imageUrls
        if not isVideoUrl(url) then images.push(url)
    end for
    if images.Count() = 0 then
        m.slideshowTimer.control = "stop"
        return
    end if

    poster = CreateObject("roSGNode", "Poster")
    ' loadWidth/loadHeight tell Roku to DECODE the image at this size,
    ' not at its native size. Critical for large source images: Roku
    ' TCL TVs silently drop textures larger than 2048×2048, so a
    ' 3334×3334 brewery-logo JPG (real-world example from logs) loads
    ' but never renders. Decoding at the display size keeps us safely
    ' below the GPU texture cap on every device.
    poster.loadWidth = slot.w
    poster.loadHeight = slot.h
    poster.uri = images[0]
    poster.translation = [slot.x, slot.y]
    poster.width = slot.w
    poster.height = slot.h
    poster.loadDisplayMode = "scaleToFit"
    m.bodyContainer.appendChild(poster)

    ' Set up rotation when the operator has multiple images in the slot.
    if images.Count() > 1 then
        m.slideshowImages = images
        m.slideshowPoster = poster
        m.slideshowIndex = 0
        duration = intField(m.config, "column_image_duration_seconds", 8)
        if duration < 2 then duration = 2
        if duration > 60 then duration = 60
        m.slideshowTimer.duration = duration
        m.slideshowTimer.control = "start"
    else
        m.slideshowImages = []
        m.slideshowPoster = invalid
        m.slideshowTimer.control = "stop"
    end if
end sub

sub onSlideshowTick()
    if m.slideshowImages = invalid or m.slideshowImages.Count() <= 1 then return
    if m.slideshowPoster = invalid then return
    m.slideshowIndex = (m.slideshowIndex + 1) mod m.slideshowImages.Count()
    m.slideshowPoster.uri = m.slideshowImages[m.slideshowIndex]
end sub

' True for file extensions Roku Poster can't render (these need Video
' node + content-meta). Matches the web's isVideoUrl helper.
function isVideoUrl(url as string) as boolean
    if url = invalid or Len(url) < 5 then return false
    lower = LCase(url)
    if Right(lower, 4) = ".mp4" then return true
    if Right(lower, 5) = ".webm" then return true
    if Right(lower, 4) = ".mov" then return true
    if Right(lower, 4) = ".avi" then return true
    if Right(lower, 4) = ".mkv" then return true
    return false
end function

' ----- Tap list column ----------------------------------------------------

' Renders one beer column's worth of rows. Header rendering is now done
' at the renderPayload level (above all beer columns), not here — this
' function only stacks beer rows starting from slot.y.
sub renderTapListColumn(beers as dynamic, breweryLogoUrl as dynamic, slot as object, config as object)
    container = CreateObject("roSGNode", "Group")
    container.translation = [slot.x, slot.y]
    m.bodyContainer.appendChild(container)

    y = 0
    if beers = invalid or beers.Count() = 0 then return

    ' Resolve the operator's typeface once per render. getFontNode then
    ' creates a Font node sized for each text element.
    fontFamily = configFontFamily(config)

    nameColor = configHex(config, "beer_name_color", "0xFFFFFFFF", 255)
    detailColor = configHex(config, "beer_detail_color", "0x9CA3AFFF", 255)
    priceColor = configHex(config, "price_color", "0xFBBF24FF", 255)

    showLabel = boolField(config, "show_label_image", true)
    showStyle = boolField(config, "show_style", true)
    showAbv = boolField(config, "show_abv", true)
    showIbu = boolField(config, "show_ibu", true)
    showDescription = boolField(config, "show_description", false)
    showDividers = boolField(config, "show_row_dividers", true)

    rowStyle = { fontFamily: fontFamily, nameColor: nameColor, detailColor: detailColor, priceColor: priceColor, showLabel: showLabel, showStyle: showStyle, showAbv: showAbv, showIbu: showIbu, showDescription: showDescription, showDividers: showDividers }

    ' Distribute the column's vertical space evenly across the beer
    ' rows. No upper cap — when there are few beers, the rows expand
    ' to fill the screen (operator on a small list still gets a full
    ' display). No lower bound either — when there are many beers,
    ' rows compress; buildBeerRow then picks tighter fonts internally.
    availableH = slot.h - y
    rowH = availableH
    if beers.Count() > 0 then rowH = Int(availableH / beers.Count())

    for i = 0 to beers.Count() - 1
        beer = beers[i]
        isLast = (i = beers.Count() - 1)
        result = buildBeerRow(beer, breweryLogoUrl, isLast, slot.w, rowH, rowStyle)
        ' Skip rendering a beer that would extend past the column area
        ' (would otherwise overrun into the footer ticker). The web's
        ' auto-fit shrinks fonts to make everything fit; on Roku we
        ' clip — preferable to text running through the footer.
        if y + result.height > slot.h then exit for
        result.node.translation = [0, y]
        container.appendChild(result.node)
        y = y + result.height
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

' Render the header area at the top of the tap-list area. Spans the
' full tap-list width (not just the first column) so headers look like
' a unified banner across the top, matching the web display.
sub renderHeaderArea(headers as dynamic, area as object, config as object)
    if headers = invalid or headers.Count() = 0 then return

    container = CreateObject("roSGNode", "Group")
    container.translation = [area.x, area.y]
    m.bodyContainer.appendChild(container)

    ' Reactive header sizing using the operator's chosen font.
    family = configFontFamily(config)
    headerColor = configHex(config, "header_color", "0xFFFFFFFF", 255)

    rowH = 50
    if headers.Count() >= 2 then
        halfW = (area.w - 24) / 2
        s1 = fitFontSize(asString(headers[0].text), halfW, 36, 16)
        s2 = fitFontSize(asString(headers[1].text), halfW, 36, 16)
        h1 = createSimpleLabel(asString(headers[0].text), 0, 10, halfW, rowH, getFontNode(family, s1, true), headerColor, "center")
        h2 = createSimpleLabel(asString(headers[1].text), halfW + 24, 10, halfW, rowH, getFontNode(family, s2, true), headerColor, "center")
        container.appendChild(h1)
        container.appendChild(h2)
    else
        s = fitFontSize(asString(headers[0].text), area.w, 40, 18)
        h = createSimpleLabel(asString(headers[0].text), 0, 10, area.w, rowH, getFontNode(family, s, true), headerColor, "center")
        container.appendChild(h)
    end if

    ' Divider line under the headers — matches the web's border-b.
    divider = CreateObject("roSGNode", "Rectangle")
    divider.width = area.w
    divider.height = 1
    divider.color = configHex(config, "font_color", "0xFFFFFF40", 64)
    divider.translation = [0, rowH + 14]
    container.appendChild(divider)
end sub

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

    ' --- Logo size — sized off TEXT content height, not row height ----
    ' The web's logoSizeBase = sum of (name lineH + detail lineH +
    ' description lineH), so the logo visually matches the height of
    ' the text block next to it. Earlier builds tried to scale the
    ' logo up with row stretching (rowHeight-based), which produced
    ' the 180-px logos that overran every row in the build-19 photos.
    ' We compute logoSize as a placeholder here using the current
    ' LOGO_BOX; it gets recomputed against contentH after we know the
    ' final layout (single- or multi-line name).
    logoSize = m.LOGO_BOX

    ' --- Column geometry inside the row -------------------------------
    ' textX uses the MAX expected logoSize (100, our cap) so the text
    ' column position is consistent across rows. We compute the actual
    ' logoSize later (from contentH) but reserve the max upfront so
    ' rows with shorter content don't shift the text column horizontally.
    leftX = 0
    if labelSrc <> "" then
        textX = 100 + m.LOGO_GAP
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

    ' Adapt pricesW to the actual rowWidth so a 3-col layout doesn't
    ' have a price column that eats the whole row, and a 1-col layout
    ' isn't artificially cramped. Tuned so:
    '   wide row (1-col)    → 360 px (fits "$10.50" comfortably 2-up)
    '   medium row (2-col)  → 280 px
    '   narrow row (3-col)  → 200 px (tight; 1-up may be all that fits)
    if pricesEnabled then
        if rowWidth >= 1000 then
            pricesW = 360
        else if rowWidth >= 700 then
            pricesW = 280
        else
            pricesW = 200
        end if
        pricesX = rowWidth - pricesW
        textRight = pricesX - m.PRICES_GAP
    else
        pricesW = 0
        pricesX = rowWidth
        textRight = rowWidth
    end if
    textWidth = textRight - textX

    ' --- Reactive font sizing -----------------------------------------
    ' Pick each text element's size based on the actual text length and
    ' the available column width. Uses the operator's selected typeface
    ' (style.fontFamily) loaded as TTF via getFontNode, so we can hit
    ' any size from 14 to 36 px continuously instead of being stuck at
    ' Roku's ~5 fixed system-font tiers.
    combinedNameSrc = nameStr
    if sourceStr <> "" then combinedNameSrc = nameStr + "  |  " + sourceStr

    nameSize = fitFontSize(combinedNameSrc, textWidth, 36, 18)

    ' If even the smallest name size still wouldn't fit on a single
    ' line, fall back to a two-line layout: name solo on line 1, source
    ' brewery on line 2 at a smaller size. Guarantees no truncation.
    splitNameSource = false
    if sourceStr <> "" and approxTextWidth(combinedNameSrc, nameSize) > textWidth then
        splitNameSource = true
        nameSize = fitFontSize(nameStr, textWidth, 36, 18)
    end if

    nameLineH = Int(nameSize * 1.2)
    if nameLineH < 20 then nameLineH = 20
    sourceLineH = Int(nameSize * 0.9)
    if sourceLineH < 16 then sourceLineH = 16

    detailParts = []
    if style.showStyle and stringIsSet(beer.style) then detailParts.push(beer.style)
    if style.showAbv and numberIsSet(beer.abv) then detailParts.push(formatAbv(beer.abv) + " ABV")
    if style.showIbu and numberIsSet(beer.ibu) then detailParts.push(formatIbu(beer.ibu))
    detailLine = joinStrings(detailParts, " · ")
    detailSize = fitFontSize(detailLine, textWidth, 24, 12)
    detailLineH = Int(detailSize * 1.2)
    if detailLineH < 14 then detailLineH = 14

    descLine = ""
    if style.showDescription and stringIsSet(beer.description) then descLine = beer.description

    textContentH = nameLineH
    if splitNameSource then textContentH = textContentH + sourceLineH
    if detailLine <> "" then textContentH = textContentH + detailLineH
    if descLine <> "" then textContentH = textContentH + detailLineH

    ' Price block goes 2-up side-by-side (matches the web's grid). The
    ' vertical space it needs depends on how many sizes, rounded up to
    ' the next pair. Row must be tall enough to fit whichever side is
    ' taller — text block or price block.
    priceCellH = 38
    priceRowsNeeded = 0
    if pricesEnabled then
        n = pricesList.Count()
        priceRowsNeeded = Int((n + 1) / 2)
    end if
    priceContentH = priceRowsNeeded * priceCellH

    contentH = textContentH
    if priceContentH > contentH then contentH = priceContentH

    naturalH = m.ROW_PADDING_Y + contentH + m.ROW_PADDING_Y
    rowHeight = naturalH
    if targetRowHeight > naturalH then rowHeight = targetRowHeight

    ' If the row is stretched, center the content vertically within it.
    extraPad = Int((rowHeight - naturalH) / 2)
    topPad = m.ROW_PADDING_Y + extraPad

    ' --- Logo image (left) --------------------------------------------
    ' Final logoSize is the SMALLER of (text content height, 100). This
    ' way the logo never exceeds the visible text block — matches the
    ' web's logoSizeBase calculation. Centered vertically within the
    ' row content (not the whole row) so it tracks the text properly.
    if labelSrc <> "" then
        logoSize = contentH
        if logoSize > 100 then logoSize = 100
        if logoSize < 40 then logoSize = 40
    end if
    logoCenterY = topPad + Int((contentH - logoSize) / 2)
    if labelSrc <> "" then
        poster = CreateObject("roSGNode", "Poster")
        ' Beer label images can also be huge (>2048 px) — same TCL GPU
        ' cap applies. Decode at the display size to stay under the
        ' texture limit.
        poster.loadWidth = logoSize
        poster.loadHeight = logoSize
        poster.uri = labelSrc
        poster.translation = [leftX, logoCenterY]
        poster.width = logoSize
        poster.height = logoSize
        poster.loadDisplayMode = "scaleToFit"
        row.appendChild(poster)
    end if

    ' --- Name (line 1) + optional source brewery (line 2) -------------
    ' If splitNameSource is true the combined string didn't fit even at
    ' the smallest size, so we render name on its own line and source
    ' on a dedicated second line below. Otherwise it's one combined
    ' label with the operator's font at the fitted size.
    nameY = topPad
    nameFont = getFontNode(style.fontFamily, nameSize, true)
    if splitNameSource then
        nameLbl = createSimpleLabel(nameStr, textX, nameY, textWidth, nameLineH, nameFont, style.nameColor, "left")
        row.appendChild(nameLbl)
        srcSize = fitFontSize(sourceStr, textWidth, Int(nameSize * 0.75), 12)
        srcFont = getFontNode(style.fontFamily, srcSize, false)
        srcLbl = createSimpleLabel(sourceStr, textX, nameY + nameLineH, textWidth, sourceLineH, srcFont, style.nameColor, "left")
        row.appendChild(srcLbl)
    else
        nameLbl = createSimpleLabel(combinedNameSrc, textX, nameY, textWidth, nameLineH, nameFont, style.nameColor, "left")
        row.appendChild(nameLbl)
    end if

    ' --- Detail line --------------------------------------------------
    detailY = nameY + nameLineH
    if splitNameSource then detailY = detailY + sourceLineH
    detailFont = getFontNode(style.fontFamily, detailSize, false)
    if detailLine <> "" then
        detailLbl = createSimpleLabel(detailLine, textX, detailY, textWidth, detailLineH, detailFont, style.detailColor, "left")
        row.appendChild(detailLbl)
    end if

    if descLine <> "" then
        descY = detailY
        if detailLine <> "" then descY = descY + detailLineH
        descLbl = createSimpleLabel(descLine, textX, descY, textWidth, detailLineH, detailFont, style.detailColor, "left")
        row.appendChild(descLbl)
    end if

    ' --- Size + price grid (right) — 2-up side-by-side -----------------
    if pricesEnabled then
        renderPriceGrid(row, pricesList, pricesX, pricesW, topPad, priceCellH, style)
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
' Side-by-side 2-up price grid matching the web BeerCard layout:
'
'   12oz $5    16oz $6        ← row 1: sizes[0] | sizes[1]
'   Pint $7    Can  $5        ← row 2: sizes[2] | sizes[3]
'                              etc.
'
' Each cell is a (size-label, price) pair rendered side-by-side. With
' 1 size, only the left cell is filled; the right cell is empty. With
' an odd number of sizes, the last row has just the left cell.
sub renderPriceGrid(row as object, sizes as object, pricesX as integer, pricesW as integer, topPad as integer, cellH as integer, style as object)
    cellW = Int((pricesW - 8) / 2)  ' 2 cells per row, 8 px gap
    for i = 0 to sizes.Count() - 1
        col = i mod 2
        gridRow = Int(i / 2)
        cellX = pricesX
        if col = 1 then cellX = pricesX + cellW + 8
        cellY = topPad + gridRow * cellH
        renderPriceCell(row, sizes[i], cellX, cellY, cellW, cellH, style)
    end for
end sub

sub renderPriceCell(row as object, size as object, x as integer, y as integer, w as integer, h as integer, style as object)
    ' Split the cell ~45/55: size label on left (smaller font), price on
    ' right (bold, brand color). Both sides use fitFontSize so longer
    ' values like "$10.50" or "Pint" auto-shrink rather than truncating.
    labelW = Int(w * 0.42)
    gap = 6
    priceW = w - labelW - gap

    labelText = asString(size.label)
    priceText = formatPrice(size.price)

    sizeSize = fitFontSize(labelText, labelW, 22, 11)
    priceSize = fitFontSize(priceText, priceW, 28, 12)

    sizeFont = getFontNode(style.fontFamily, sizeSize, false)
    priceFont = getFontNode(style.fontFamily, priceSize, true)

    sizeLbl = createSimpleLabel(labelText, x, y, labelW, h, sizeFont, style.nameColor, "right")
    row.appendChild(sizeLbl)

    priceLbl = createSimpleLabel(priceText, x + labelW + gap, y, priceW, h, priceFont, style.priceColor, "left")
    row.appendChild(priceLbl)
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

    ' Use the operator's font at a fixed footer size for the ticker.
    family = configFontFamily(config)
    footerSize = intField(config, "ticker_font_size", 24)
    if footerSize < 14 then footerSize = 14
    if footerSize > 40 then footerSize = 40
    m.footerText.font = getFontNode(family, footerSize, false)

    ' Approximate width of one set at the chosen footer size.
    oneSetW = approxTextWidth(singleSet, footerSize)
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
' alignment. `font` may be either a string alias (like
' "font:LargeBoldSystemFont") OR a Font/SystemFont node reference. Roku
' Label.font accepts both.
function createSimpleLabel(text as string, x as integer, y as integer, w as integer, h as integer, font as object, color as string, align as string) as object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    if font <> invalid then lbl.font = font
    lbl.color = color
    lbl.width = w
    lbl.height = h
    lbl.horizAlign = align
    lbl.vertAlign = "top"
    lbl.translation = [x, y]
    return lbl
end function

' --------------------------------------------------------------------------
' Reactive font system
' --------------------------------------------------------------------------
' getFontNode(family, size, bold) returns a Font node configured to load
' the operator's chosen typeface from a stable CDN (@fontsource on
' jsdelivr serves every Google Font as TTF at a predictable URL). Roku's
' Font.uri field accepts https URIs and the renderer caches loaded
' fonts, so reusing the same family across rows is cheap.
'
' We cache the Font nodes by (family|size|weight) so multiple Labels can
' share one Font instance.

function getFontNode(family as string, size as integer, bold as boolean) as object
    if m.fontCache = invalid then m.fontCache = {}
    if family = invalid or family = "" then family = "Inter"
    if size < 8 then size = 8

    weight = "r"
    if bold then weight = "b"
    key = family + "|" + size.toStr() + "|" + weight

    cached = m.fontCache[key]
    if cached <> invalid then return cached

    font = CreateObject("roSGNode", "Font")
    font.size = size
    font.uri = fontUrlFor(family, bold)
    m.fontCache[key] = font
    return font
end function

' Map an operator-selectable font family name to a TTF URL on jsdelivr's
' @fontsource CDN. URLs follow the pattern:
'   https://cdn.jsdelivr.net/npm/@fontsource/<family>/files/<family>-latin-<weight>-normal.ttf
'
' The whitelist mirrors AVAILABLE_FONTS in the web app (Lato, Oswald,
' Raleway, Inter, etc.). Anything not on the list falls back to Inter so
' a typo doesn't blow up the Roku channel.
function fontUrlFor(family as string, bold as boolean) as string
    weight = "400"
    if bold then weight = "700"

    ' Normalize: lowercase, spaces to dashes. Matches @fontsource pkg names.
    fam = LCase(family)
    fam = replaceAll(fam, " ", "-")

    ' Whitelist of fonts we know exist on @fontsource via jsdelivr.
    ' Comma-delimited so we can do a single InStr check.
    known = ",raleway,roboto,inter,oswald,playfair-display,bebas-neue,montserrat,anton,lato,poppins,source-sans-3,nunito,dm-sans,space-grotesk,barlow,barlow-condensed,exo-2,fjalla-one,righteous,cinzel,libre-baskerville,merriweather,"
    if InStr(0, known, "," + fam + ",") = 0 then fam = "inter"

    return "https://cdn.jsdelivr.net/npm/@fontsource/" + fam + "/files/" + fam + "-latin-" + weight + "-normal.ttf"
end function

' Approximate text width without using roFont (which would require the
' font to be local). 0.55 of size is a reasonable average for the
' sans-serif fonts in our whitelist — errs slightly conservative so we
' drop a size step earlier rather than later.
function approxTextWidth(text as string, size as integer) as integer
    if text = invalid or Len(text) = 0 then return 0
    return Int(Len(text) * size * 0.55)
end function

' Return the largest font size in [minSize..maxSize] whose approximated
' rendered width fits within `availableW`. Used everywhere we need
' reactive sizing — names, prices, headers, footer ticker.
function fitFontSize(text as string, availableW as integer, maxSize as integer, minSize as integer) as integer
    if text = invalid or Len(text) = 0 then return maxSize
    size = maxSize
    while size > minSize
        if approxTextWidth(text, size) <= availableW then return size
        size = size - 1
    end while
    return minSize
end function

' BrightScript doesn't have a string replace built-in, so here's a
' minimal implementation. Used to convert "Source Sans 3" → "source-sans-3"
' for @fontsource package names.
function replaceAll(s as string, find as string, replacement as string) as string
    if Len(find) = 0 then return s
    out = ""
    i = 1
    while i <= Len(s)
        if Mid(s, i, Len(find)) = find then
            out = out + replacement
            i = i + Len(find)
        else
            out = out + Mid(s, i, 1)
            i = i + 1
        end if
    end while
    return out
end function

' Look up the operator's chosen typeface from screen config. Prefers
' beer_font_family (per-card override) over font_family (global). Falls
' back to Inter so we never end up trying to load an undefined font.
function configFontFamily(config as object) as string
    if config = invalid then return "Inter"
    f = config.beer_font_family
    if f <> invalid and f <> "" and f <> "Inter" then return f
    f = config.font_family
    if f <> invalid and f <> "" then return f
    return "Inter"
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
