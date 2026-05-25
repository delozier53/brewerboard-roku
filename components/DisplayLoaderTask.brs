' DisplayLoaderTask — performs a single HTTPS GET and reports { status, body }
' back via the `response` interface field.
'
' Roku's roUrlTransfer talks HTTPS as long as we point at the system CA
' bundle. `EnableEncodings(true)` lets the server gzip the (potentially
' chatty) JSON payload. The timeout is set generously (15s) because we'd
' rather report a slow connection than retry and hammer the API.

sub init()
    m.top.functionName = "runFetch"
end sub

sub runFetch()
    url = m.top.url
    if url = invalid or url = "" then
        m.top.response = { status: 0, body: "" }
        return
    end if

    transfer = CreateObject("roUrlTransfer")
    transfer.SetUrl(url)
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.InitClientCertificates()
    transfer.EnableEncodings(true)
    transfer.AddHeader("Accept", "application/json")
    transfer.SetMessagePort(CreateObject("roMessagePort"))
    transfer.RetainBodyOnError(true)

    ok = transfer.AsyncGetToString()
    if not ok then
        m.top.response = { status: 0, body: "AsyncGetToString failed" }
        return
    end if

    port = transfer.GetMessagePort()
    msg = wait(15000, port)  ' 15-second budget
    if msg = invalid then
        transfer.AsyncCancel()
        m.top.response = { status: 0, body: "timeout" }
        return
    end if

    eventType = type(msg)
    if eventType = "roUrlEvent" then
        status = msg.GetResponseCode()
        body = msg.GetString()
        m.top.response = { status: status, body: body }
    else
        m.top.response = { status: 0, body: "unexpected event " + eventType }
    end if
end sub
