using System.Text;

namespace ExtraPadWindows.Networking;

/// Mirrors Sources/ExtraPad/Auth.swift. Shared-secret access control over
/// plain HTTP on the LAN - not a defense against someone reading the wire,
/// just against someone who merely knows the address.
public sealed class Auth
{
    private readonly Settings settings;
    private readonly object failLock = new();
    private int failures;

    public Auth(Settings settings) => this.settings = settings;

    public string Key => settings.AccessKey;
    public string PairingCode => settings.PairingCode;
    public const string CookieName = WireNames.AccessCookie;
    public const string QueryName = WireNames.KeyQuery;
    public const string DeviceCookieName = WireNames.DeviceCookie;

    public bool Matches(string? candidate) => candidate is not null && ConstantTimeEquals(Key, candidate);

    /// Six digits is a small space, so wrong guesses are throttled and enough
    /// of them retire the code entirely - only the machine's owner can read
    /// the replacement off the tray menu.
    public bool CheckPairingCode(string? candidate)
    {
        if (candidate is null || candidate.Length != 6) return false;
        if (ConstantTimeEquals(PairingCode, candidate))
        {
            lock (failLock) { failures = 0; }
            return true;
        }
        int count;
        lock (failLock) { failures++; count = failures; }
        Thread.Sleep(Math.Min(count * 250, 2000));
        if (count >= 20) settings.RotateCode();
        return false;
    }

    public string Rotate()
    {
        var key = settings.RotateKey();
        lock (failLock) { failures = 0; }
        return key;
    }

    private static bool ConstantTimeEquals(string expectedString, string candidate)
    {
        var expected = Encoding.UTF8.GetBytes(expectedString);
        var given = Encoding.UTF8.GetBytes(candidate);
        if (expected.Length != given.Length) return false;
        byte difference = 0;
        for (var i = 0; i < expected.Length; i++) difference |= (byte)(expected[i] ^ given[i]);
        return difference == 0;
    }

    public static string DeviceCookieHeader(string id) =>
        $"Set-Cookie: {DeviceCookieName}={id}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n";

    public string SetCookieHeader() =>
        $"Set-Cookie: {CookieName}={Key}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n";

    public static string? CookieValue(string name, IReadOnlyDictionary<string, string> headers)
    {
        if (!headers.TryGetValue("cookie", out var line)) return null;
        foreach (var pair in line.Split(';'))
        {
            var parts = pair.Split('=', 2);
            if (parts.Length == 2 && parts[0].Trim() == name) return parts[1].Trim();
        }
        return null;
    }

    public static string? CookieValue(IReadOnlyDictionary<string, string> headers) =>
        CookieValue(CookieName, headers);

    public static string NewDeviceId()
    {
        var bytes = new byte[16];
        Random.Shared.NextBytes(bytes);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
