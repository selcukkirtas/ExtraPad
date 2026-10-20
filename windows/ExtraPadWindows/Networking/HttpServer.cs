using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using ExtraPadWindows.Capture;
using Microsoft.Win32;

namespace ExtraPadWindows.Networking;

/// Mirrors Sources/ExtraPad/MJPEGServer.swift, cut down to what v1 needs:
/// only the atlas/JPEG-over-WebSocket path (/delta + /ws), no H.264, no TLS,
/// no Bonjour (the iPad types the address into Safari directly, same as the
/// Mac host's own documented fallback). One shared capture - the whole
/// primary display - rather than a session per device, because v1 mirrors
/// instead of creating a separate virtual display per iPad.
///
/// Known gap vs. the Mac host: there is no per-device "a new device wants to
/// connect, Allow/Deny?" prompt yet. Anyone who supplies the key or the
/// pairing code is let straight in. Fine for a first test on a trusted LAN;
/// worth closing before this goes further.
public sealed class HttpServer
{
    public int Port { get; }
    private readonly Auth auth;
    private readonly ScreenCapture capture;
    private readonly int fps;
    private readonly long jpegQuality;

    private TcpListener? listener;
    private CancellationTokenSource? cts;
    private readonly ConcurrentDictionary<Guid, ClientConnection> clients = new();
    private volatile HostStatus hostStatus = HostStatus.Awake;
    /// Lets the unlock handler wake the capture loop immediately rather than
    /// waiting out whatever is left of the current tick - otherwise the
    /// first frame after unlocking could lag by up to a whole tick on top of
    /// Windows' own unlock animation.
    private readonly SemaphoreSlim captureSignal = new(0);

    public int ActiveClients => clients.Count;

    public HttpServer(int port, Auth auth, ScreenCapture capture, int fps = 15, long jpegQuality = 60)
    {
        Port = port;
        this.auth = auth;
        this.capture = capture;
        this.fps = fps;
        this.jpegQuality = jpegQuality;
    }

    public void Start()
    {
        cts = new CancellationTokenSource();
        listener = new TcpListener(IPAddress.Any, Port);
        listener.Start();
        _ = Task.Run(() => AcceptLoop(cts.Token));
        _ = Task.Run(() => CaptureLoop(cts.Token));
        _ = Task.Run(() => KeepAliveLoop(cts.Token));
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    public void Stop()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        cts?.Cancel();
        listener?.Stop();
        foreach (var client in clients.Values) client.Dispose();
        clients.Clear();
        captureSignal.Dispose();
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        switch (e.Reason)
        {
            case SessionSwitchReason.SessionLock:
                hostStatus = HostStatus.Locked;
                InputInjector.ReleaseIfHeld();
                BroadcastText(hostStatus.WireText());
                break;
            case SessionSwitchReason.SessionUnlock:
                hostStatus = HostStatus.Awake;
                BroadcastText(hostStatus.WireText());
                captureSignal.Release();
                break;
        }
    }

    // MARK: - Accept loop

    private async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient tcpClient;
            try
            {
                tcpClient = await listener!.AcceptTcpClientAsync(token);
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            tcpClient.NoDelay = true;
            _ = Task.Run(() => HandleConnectionAsync(tcpClient, token), token);
        }
    }

    private async Task HandleConnectionAsync(TcpClient tcpClient, CancellationToken token)
    {
        var stream = tcpClient.GetStream();
        string rawHead;
        try
        {
            rawHead = await ReadRequestHeadAsync(stream, token);
        }
        catch
        {
            tcpClient.Close();
            return;
        }
        if (rawHead.Length == 0) { tcpClient.Close(); return; }

        var lines = rawHead.Split("\r\n");
        var requestLine = lines[0].Split(' ');
        if (requestLine.Length < 2 || (requestLine[0] != "GET" && requestLine[0] != "HEAD"))
        {
            await SendAsync(stream, "405 Method Not Allowed", Encoding.UTF8.GetBytes("GET expected\n"),
                "text/plain; charset=utf-8");
            tcpClient.Close();
            return;
        }

        var headers = new Dictionary<string, string>();
        for (var i = 1; i < lines.Length; i++)
        {
            var idx = lines[i].IndexOf(':');
            if (idx <= 0) continue;
            headers[lines[i][..idx].Trim().ToLowerInvariant()] = lines[i][(idx + 1)..].Trim();
        }

        var target = requestLine[1];
        var qIndex = target.IndexOf('?');
        var path = qIndex >= 0 ? target[..qIndex] : target;
        var query = new Dictionary<string, string>();
        if (qIndex >= 0)
        {
            foreach (var pair in target[(qIndex + 1)..].Split('&'))
            {
                var kv = pair.Split('=', 2);
                if (kv.Length == 2) query[kv[0]] = Uri.UnescapeDataString(kv[1]);
            }
        }

        await RouteAsync(stream, tcpClient, path, query, headers, token);
    }

    private async Task<string> ReadRequestHeadAsync(NetworkStream stream, CancellationToken token)
    {
        var buffer = new List<byte>();
        var chunk = new byte[4096];
        while (buffer.Count < 16 * 1024)
        {
            var read = await stream.ReadAsync(chunk, token);
            if (read == 0) break;
            buffer.AddRange(chunk.AsSpan(0, read).ToArray());
            var text = Encoding.UTF8.GetString(buffer.ToArray());
            var idx = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (idx >= 0) return text[..idx];
        }
        return "";
    }

    // MARK: - Routing

    private async Task RouteAsync(NetworkStream stream, TcpClient tcpClient, string path,
        Dictionary<string, string> query, Dictionary<string, string> headers, CancellationToken token)
    {
        var authorised = false;
        var issueCookie = false;
        if (query.TryGetValue(Auth.QueryName, out var givenKey) && auth.Matches(givenKey))
        {
            authorised = true;
            issueCookie = true;
        }
        else if (auth.Matches(Auth.CookieValue(headers)))
        {
            authorised = true;
        }

        if (!authorised && path == "/pair")
        {
            if (auth.CheckPairingCode(query.GetValueOrDefault("code")))
            {
                authorised = true;
                issueCookie = true;
                path = "/";
            }
            else
            {
                await SendPageAsync(stream, "200 OK", WebClientPages.PairingPage(wrong: true));
                tcpClient.Close();
                return;
            }
        }

        if (!authorised)
        {
            var wantsPage = path is "/" or "/index.html" or "/delta";
            Console.WriteLine($"[ExtraPad] 401 on {path} (no key/cookie matched) - cookie header: "
                + $"\"{(headers.TryGetValue("cookie", out var ck) ? ck : "(none)")}\"");
            await SendPageAsync(stream, "200 OK",
                wantsPage ? WebClientPages.PairingPage(wrong: false) : WebClientPages.UnauthorisedPage(),
                status2: wantsPage ? null : "401 Unauthorized");
            tcpClient.Close();
            return;
        }

        string? deviceCookie = null;
        if (Auth.CookieValue(Auth.DeviceCookieName, headers) is null)
        {
            deviceCookie = Auth.NewDeviceId();
        }

        switch (path)
        {
            case "/":
            case "/index.html":
            case "/delta":
                var html = WebClientPages.DeltaPage(capture.ScreenSize.Width, capture.ScreenSize.Height, WireProtocol.Atlas);
                await SendAsync(stream, "200 OK", Encoding.UTF8.GetBytes(html), "text/html; charset=utf-8",
                    issueCookie ? auth.SetCookieHeader() : null, deviceCookie);
                tcpClient.Close();
                break;

            case "/version":
                var versionJson = $"{{\"protocol\":{WireProtocol.Version},\"minimum\":{WireProtocol.MinimumSupportedVersion}}}";
                await SendAsync(stream, "200 OK", Encoding.UTF8.GetBytes(versionJson), "application/json");
                tcpClient.Close();
                break;

            case "/ws":
                if (query.TryGetValue(WireNames.VersionQuery, out var vRaw) && int.TryParse(vRaw, out var clientVersion)
                    && !WireProtocol.CanServe(clientVersion))
                {
                    await SendAsync(stream, "409 Conflict",
                        Encoding.UTF8.GetBytes($"Protocol {clientVersion} not supported; host speaks {WireProtocol.Version}\n"),
                        "text/plain; charset=utf-8");
                    tcpClient.Close();
                    return;
                }
                await UpgradeToWebSocketAsync(stream, tcpClient, headers, token);
                break; // ownership of tcpClient now belongs to the WS loop

            case "/snapshot":
                var frame = capture.CaptureJpeg(jpegQuality);
                if (frame is not null)
                {
                    await SendAsync(stream, "200 OK", frame, "image/jpeg");
                }
                else
                {
                    await SendAsync(stream, "503 Service Unavailable", Encoding.UTF8.GetBytes("No frame yet\n"),
                        "text/plain; charset=utf-8");
                }
                tcpClient.Close();
                break;

            case "/info":
                var infoJson = $"{{\"width\":{capture.ScreenSize.Width},\"height\":{capture.ScreenSize.Height}," +
                               $"\"activeStreams\":{ActiveClients}}}";
                await SendAsync(stream, "200 OK", Encoding.UTF8.GetBytes(infoJson), "application/json");
                tcpClient.Close();
                break;

            case "/favicon.ico":
                await SendAsync(stream, "204 No Content", Array.Empty<byte>(), "image/x-icon");
                tcpClient.Close();
                break;

            default:
                await SendPageAsync(stream, "404 Not Found", WebClientPages.NotFoundPage());
                tcpClient.Close();
                break;
        }
    }

    private async Task SendPageAsync(NetworkStream stream, string status, string html, string? status2 = null) =>
        await SendAsync(stream, status2 ?? status, Encoding.UTF8.GetBytes(html), "text/html; charset=utf-8");

    private static async Task SendAsync(NetworkStream stream, string status, byte[] body, string contentType,
        string? setCookieHeader = null, string? deviceCookie = null)
    {
        var header = new StringBuilder();
        header.Append("HTTP/1.1 ").Append(status).Append("\r\n");
        header.Append("Content-Type: ").Append(contentType).Append("\r\n");
        header.Append("Content-Length: ").Append(body.Length).Append("\r\n");
        header.Append("Cache-Control: no-store\r\n");
        if (setCookieHeader is not null) header.Append(setCookieHeader);
        if (deviceCookie is not null) header.Append(Auth.DeviceCookieHeader(deviceCookie));
        header.Append("Connection: close\r\n\r\n");
        var headerBytes = Encoding.UTF8.GetBytes(header.ToString());
        try
        {
            await stream.WriteAsync(headerBytes);
            await stream.WriteAsync(body);
        }
        catch
        {
            // Client went away mid-response; nothing to clean up here.
        }
    }

    // MARK: - WebSocket

    private async Task UpgradeToWebSocketAsync(NetworkStream stream, TcpClient tcpClient,
        Dictionary<string, string> headers, CancellationToken token)
    {
        var handshake = WebSocketFraming.HandshakeResponse(headers);
        if (handshake is null)
        {
            Console.WriteLine("[ExtraPad] /ws upgrade rejected - no valid Sec-WebSocket-Key/Upgrade header");
            await SendAsync(stream, "400 Bad Request", Encoding.UTF8.GetBytes("WebSocket upgrade expected\n"),
                "text/plain; charset=utf-8");
            tcpClient.Close();
            return;
        }
        await stream.WriteAsync(handshake, token);

        var id = Guid.NewGuid();
        var connection = new ClientConnection(id, tcpClient, stream);
        Console.WriteLine($"[ExtraPad] /ws client connected ({id})");
        clients[id] = connection;

        await connection.SendRawAsync(WebSocketFraming.TextFrame(hostStatus.WireText()));

        var reader = new WebSocketFraming.ClientFrameReader();
        var buffer = new byte[4096];
        try
        {
            while (!token.IsCancellationRequested)
            {
                var read = await stream.ReadAsync(buffer, token);
                if (read == 0) break;
                reader.Append(buffer.AsSpan(0, read));
                while (reader.Next() is { } message)
                {
                    switch (message)
                    {
                        case WebSocketFraming.ClientMessage.Close:
                            InputInjector.ReleaseIfHeld();
                            goto done;
                        case WebSocketFraming.ClientMessage.Input(var phase, var x, var y):
                            InputInjector.Handle(phase, x, y);
                            break;
                        case WebSocketFraming.ClientMessage.Resync:
                            // Every tick already sends a full keyframe in v1 -
                            // nothing extra to do until dirty-rect diffing exists.
                            break;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[ExtraPad] /ws client ({id}) read loop ended: {ex.GetType().Name}: {ex.Message}");
        }
        done:
        Console.WriteLine($"[ExtraPad] /ws client disconnected ({id})");
        InputInjector.ReleaseIfHeld();
        clients.TryRemove(id, out _);
        connection.Dispose();
    }

    private void BroadcastText(string text)
    {
        var frame = WebSocketFraming.TextFrame(text);
        foreach (var client in clients.Values) _ = client.SendRawAsync(frame);
    }

    /// Mirrors MJPEGServer.swift's startKeepAlive(): a WebSocket client sat
    /// idle long enough - nobody touching the iPad, no screen changes worth
    /// a frame - looks dead to a NAT or Wi-Fi router, which drops it with no
    /// error on either side. The symptom was exactly that: the connection
    /// silently dies, the keep-awake video stops with it, and the iPad falls
    /// back to its normal auto-lock timer. A ping well inside that window
    /// keeps every socket demonstrably alive.
    private async Task KeepAliveLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(20), token); }
            catch (OperationCanceledException) { return; }
            var frame = WebSocketFraming.PingFrame();
            foreach (var client in clients.Values) _ = client.SendRawAsync(frame);
        }
    }

    // MARK: - Capture loop

    private async Task CaptureLoop(CancellationToken token)
    {
        var delay = 1000 / Math.Max(fps, 1);
        var framesSent = 0;
        var lastStatusLog = DateTime.UtcNow;
        while (!token.IsCancellationRequested)
        {
            try { await captureSignal.WaitAsync(delay, token); }
            catch (OperationCanceledException) { return; }

            if (DateTime.UtcNow - lastStatusLog > TimeSpan.FromSeconds(5))
            {
                lastStatusLog = DateTime.UtcNow;
                Console.WriteLine($"[ExtraPad] capture status: {clients.Count} client(s), "
                    + $"{hostStatus}, {framesSent} frame(s) sent in the last 5s");
                framesSent = 0;
            }

            if (hostStatus == HostStatus.Locked || clients.IsEmpty) continue;

            var jpeg = capture.CaptureJpeg(jpegQuality);
            if (jpeg is null) continue;
            framesSent++;

            var message = new AtlasMessage
            {
                Regions = new[]
                {
                    new AtlasMessage.Region(0, 0, 0, capture.ScreenSize.Width, capture.ScreenSize.Height)
                },
                IsKeyframe = true,
                ShowsDiagnostics = false,
                Jpeg = jpeg
            };
            var frame = WebSocketFraming.BinaryFrame(message.Encoded());
            foreach (var client in clients.Values) _ = client.SendRawAsync(frame);
        }
    }
}

/// One connected WebSocket client. Writes are serialised with a semaphore so
/// a keepalive ping and a capture-loop frame can never interleave into a
/// corrupt frame on the wire.
internal sealed class ClientConnection : IDisposable
{
    public Guid Id { get; }
    private readonly TcpClient tcpClient;
    private readonly NetworkStream stream;
    private readonly SemaphoreSlim sendLock = new(1, 1);

    public ClientConnection(Guid id, TcpClient tcpClient, NetworkStream stream)
    {
        Id = id;
        this.tcpClient = tcpClient;
        this.stream = stream;
    }

    public async Task SendRawAsync(byte[] data)
    {
        // A client that is still busy with the last frame is skipped rather
        // than queued - v1 has no backlog/backpressure handling yet beyond
        // this.
        if (!await sendLock.WaitAsync(0)) return;
        try
        {
            await stream.WriteAsync(data);
        }
        catch (Exception ex)
        {
            // Dead connection; the read loop will notice and clean up.
            Console.WriteLine($"[ExtraPad] write to client ({Id}) failed: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            sendLock.Release();
        }
    }

    public void Dispose()
    {
        sendLock.Dispose();
        tcpClient.Close();
    }
}
