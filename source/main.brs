' BrewerBoard Roku channel — entry point.
'
' Every Roku channel needs a `Main()` in source/. This boilerplate creates
' the SceneGraph screen, instantiates `MainScene` (defined in
' components/MainScene.xml), and runs the message-loop until the user backs
' out of the channel.

sub Main(args as dynamic)
    print "[brewerboard] launching channel"

    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    scene = screen.CreateScene("MainScene")
    screen.Show()

    ' Pass deep-link args through to the scene if the channel was launched
    ' from a content link or a content provider. Roku passes these even when
    ' the launch is "cold", so we wire them to a scene field for visibility.
    if args <> invalid and args.contentId <> invalid then
        scene.contentId = args.contentId
    end if

    while true
        msg = wait(0, port)
        msgType = type(msg)
        if msgType = "roSGScreenEvent" then
            if msg.IsScreenClosed() then
                print "[brewerboard] screen closed, exiting"
                return
            end if
        end if
    end while
end sub
