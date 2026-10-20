namespace ExtraPadWindows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        try
        {
            Application.Run(new TrayApp());
        }
        catch (Exception ex)
        {
            // Nothing else here has a monitor to show a crash on, and a
            // WinExe app gives no guarantee the launching terminal sees
            // anything either - this is the one message that has to land
            // somewhere visible.
            MessageBox.Show($"ExtraPad failed to start:\n\n{ex}", "ExtraPad",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
