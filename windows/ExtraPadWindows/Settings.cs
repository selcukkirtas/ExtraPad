using System.Text.Json;

namespace ExtraPadWindows;

/// Persisted across launches, same reasoning as Auth.swift: the iPad's
/// home-screen shortcut has the key baked into its URL, so it cannot rotate
/// on every start.
public sealed class Settings
{
    public string AccessKey { get; set; } = "";
    public string PairingCode { get; set; } = "";

    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ExtraPad", "settings.json");

    private static readonly object Lock = new();

    public static Settings Load()
    {
        lock (Lock)
        {
            try
            {
                if (File.Exists(FilePath))
                {
                    var json = File.ReadAllText(FilePath);
                    var loaded = JsonSerializer.Deserialize<Settings>(json);
                    if (loaded is not null && !string.IsNullOrEmpty(loaded.AccessKey)
                        && loaded.PairingCode.Length == 6)
                    {
                        return loaded;
                    }
                }
            }
            catch
            {
                // Corrupt or unreadable settings file - fall through and
                // generate fresh ones rather than failing to start.
            }

            var fresh = new Settings
            {
                AccessKey = GenerateKey(),
                PairingCode = GenerateCode()
            };
            fresh.Save();
            return fresh;
        }
    }

    public void Save()
    {
        lock (Lock)
        {
            var dir = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
        }
    }

    public string RotateKey()
    {
        AccessKey = GenerateKey();
        PairingCode = GenerateCode();
        Save();
        return AccessKey;
    }

    public string RotateCode()
    {
        PairingCode = GenerateCode();
        Save();
        return PairingCode;
    }

    /// 20 chars, no 0/O or 1/l - read off a menu, typed on an iPad.
    private static string GenerateKey()
    {
        const string alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
        var bytes = new byte[20];
        Random.Shared.NextBytes(bytes);
        var chars = new char[20];
        for (var i = 0; i < bytes.Length; i++) chars[i] = alphabet[bytes[i] % alphabet.Length];
        return new string(chars);
    }

    private static string GenerateCode()
    {
        var chars = new char[6];
        for (var i = 0; i < chars.Length; i++) chars[i] = (char)('0' + Random.Shared.Next(10));
        return new string(chars);
    }
}
