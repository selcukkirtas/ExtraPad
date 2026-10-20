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
        capture = new ScreenCapture(settings.SelectedScreenIndex);
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

        // WinExe apps don't reliably show anything in the terminal that
        // launched them, and this machine has no monitor to glance at - so
        // the balloon tip (and the console line, when one is attached) are
        // the only confirmation that this actually started.
        Console.WriteLine($"[ExtraPad] listening on {string.Join(", ", urls)}");
        Console.WriteLine($"[ExtraPad] pairing code: {auth.PairingCode}");
        trayIcon.BalloonTipTitle = "ExtraPad is running";
        trayIcon.BalloonTipText = urls.Count > 0
            ? $"Open {urls[0]} on the iPad - pairing code {auth.PairingCode}"
            : "No LAN address found - check the network connection.";
        trayIcon.ShowBalloonTip(5000);
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
        menu.Items.Add(BuildDisplayPicker());

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

    /// A machine with more than one display (an RDP session's own virtual
    /// adapter plus, once installed, a virtual display driver's monitor)
    /// has no reliable way to know which one is intended without being
    /// told - so list them and let the tray menu pick, rather than
    /// guessing from "primary", which may not even be the right one here.
    private ToolStripMenuItem BuildDisplayPicker()
    {
        var root = new ToolStripMenuItem($"Mirroring: {capture.CurrentDeviceName} ({capture.ScreenSize.Width}x{capture.ScreenSize.Height})");
        foreach (var (index, deviceName, bounds, isPrimary) in ScreenCapture.AllDisplays())
        {
            var label = $"{deviceName}  {bounds.Width}x{bounds.Height}" + (isPrimary ? "  (primary)" : "");
            var item = new ToolStripMenuItem(label) { Checked = deviceName == capture.CurrentDeviceName };
            item.Click += (_, _) =>
            {
                capture.SelectDisplay(index);
                settings.SelectedScreenIndex = index;
                settings.Save();
                root.Text = $"Mirroring: {capture.CurrentDeviceName} ({capture.ScreenSize.Width}x{capture.ScreenSize.Height})";
                foreach (ToolStripMenuItem sibling in root.DropDownItems) sibling.Checked = false;
                item.Checked = true;
            };
            root.DropDownItems.Add(item);
        }
        return root;
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
