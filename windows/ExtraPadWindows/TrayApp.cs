using System.Net;
using System.Net.Sockets;
using ExtraPadWindows.Capture;
using ExtraPadWindows.Networking;

namespace ExtraPadWindows;

/// Mirrors the role of AppController.swift's menu-bar half: a tray icon with
/// the address to type on the iPad, the pairing code, and a way to rotate
/// both.
public sealed class TrayApp : ApplicationContext
{
    private const int Port = 8765;

    private readonly NotifyIcon trayIcon;
    private readonly Settings settings;
    private readonly Auth auth;
    private readonly ScreenCapture capture;
    private readonly HttpServer server;
    private readonly List<string> urls;

    public TrayApp()
    {
        settings = Settings.Load();
        auth = new Auth(settings);
        capture = new ScreenCapture();
        server = new HttpServer(Port, auth, capture);
        urls = LocalUrls();

        trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "ExtraPad"
        };

        trayIcon.ContextMenuStrip = BuildMenu();
        server.Start();
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();

        var header = new ToolStripMenuItem("ExtraPad (Windows) - v1, mirrors this PC's screen") { Enabled = false };
        menu.Items.Add(header);
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem("Open on the iPad (click to copy):") { Enabled = false });
        foreach (var url in urls)
        {
            var item = new ToolStripMenuItem(url);
            item.Click += (_, _) => Clipboard.SetText(url);
            menu.Items.Add(item);
        }

        menu.Items.Add(new ToolStripSeparator());
        var codeItem = new ToolStripMenuItem($"Pairing code: {auth.PairingCode}");
        codeItem.Click += (_, _) => Clipboard.SetText(auth.PairingCode);
        menu.Items.Add(codeItem);

        var rotate = new ToolStripMenuItem("Generate a new code and key");
        rotate.Click += (_, _) =>
        {
            auth.Rotate();
            codeItem.Text = $"Pairing code: {auth.PairingCode}";
            MessageBox.Show("New code and key generated. Connected devices were dropped.",
                "ExtraPad", MessageBoxButtons.OK, MessageBoxIcon.Information);
        };
        menu.Items.Add(rotate);

        menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem("Quit");
        quit.Click += (_, _) => ExitApp();
        menu.Items.Add(quit);

        return menu;
    }

    private void ExitApp()
    {
        server.Stop();
        trayIcon.Visible = false;
        Application.Exit();
    }

    /// Same reasoning as NetworkInfo.swift on the Mac side: every local IPv4
    /// address, since the iPad is on whichever interface actually reaches it.
    private static List<string> LocalUrls()
    {
        var urls = new List<string>();
        foreach (var address in Dns.GetHostEntry(Dns.GetHostName()).AddressList)
        {
            if (address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address))
            {
                urls.Add($"http://{address}:{Port}");
            }
        }
        if (urls.Count == 0) urls.Add($"http://127.0.0.1:{Port}");
        return urls;
    }
}
