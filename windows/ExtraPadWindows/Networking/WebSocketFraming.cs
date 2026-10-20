using System.Security.Cryptography;
using System.Text;

namespace ExtraPadWindows.Networking;

/// Mirrors Sources/ExtraPadProtocol/WebSocketFraming.swift. Hand-rolled, not
/// System.Net.WebSockets, so the exact same framing rules apply as on the Mac
/// host and nothing drifts between the two.
public static class WebSocketFraming
{
    private const string Guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    /// Builds the 101 response for a client handshake, or null if the request
    /// is not a valid WebSocket upgrade.
    public static byte[]? HandshakeResponse(IReadOnlyDictionary<string, string> headers)
    {
        if (!headers.TryGetValue("sec-websocket-key", out var key)) return null;
        if (!headers.TryGetValue("upgrade", out var upgrade)
            || !upgrade.Contains("websocket", StringComparison.OrdinalIgnoreCase)) return null;

        var accept = Convert.ToBase64String(SHA1.HashData(Encoding.UTF8.GetBytes(key + Guid)));
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + $"Sec-WebSocket-Accept: {accept}\r\n\r\n";
        return Encoding.UTF8.GetBytes(response);
    }

    public static byte[] BinaryFrame(byte[] payload) => Frame(0x82, payload);

    public static byte[] TextFrame(string text) => Frame(0x81, Encoding.UTF8.GetBytes(text));

    public static byte[] PingFrame() => Frame(0x89, Array.Empty<byte>());

    private static byte[] Frame(byte opcode, byte[] payload)
    {
        using var ms = new MemoryStream();
        ms.WriteByte(opcode);
        // long, not int: shifting a 32-bit value by up to 56 bits in C# only
        // uses the shift amount's low 5 bits (count >> 56 silently becomes
        // count >> 24), which produced garbage length bytes for every
        // payload over 64KB - a full-screen JPEG routinely is. The browser
        // reads the resulting frame as a different, wrong length and tears
        // the connection down as a protocol violation.
        long count = payload.Length;
        if (count < 126)
        {
            ms.WriteByte((byte)count);
        }
        else if (count <= 0xFFFF)
        {
            ms.WriteByte(126);
            ms.WriteByte((byte)((count >> 8) & 0xFF));
            ms.WriteByte((byte)(count & 0xFF));
        }
        else
        {
            ms.WriteByte(127);
            for (var shift = 56; shift >= 0; shift -= 8) ms.WriteByte((byte)((count >> shift) & 0xFF));
        }
        ms.Write(payload);
        return ms.ToArray();
    }

    public abstract record ClientMessage
    {
        public sealed record Close : ClientMessage;
        public sealed record Resync : ClientMessage;
        public sealed record Input(string Phase, int X, int Y) : ClientMessage;
    }

    /// Accumulates bytes and yields whole client frames. Client frames are
    /// masked, and a message can straddle two reads.
    public sealed class ClientFrameReader
    {
        private readonly List<byte> buffer = new();

        public void Append(ReadOnlySpan<byte> data) => buffer.AddRange(data.ToArray());

        public ClientMessage? Next()
        {
            while (true)
            {
                if (buffer.Count < 2) return null;
                var bytes = buffer;
                var opcode = bytes[0] & 0x0F;
                var masked = (bytes[1] & 0x80) != 0;
                int length = bytes[1] & 0x7F;
                var offset = 2;

                if (length == 126)
                {
                    if (bytes.Count < 4) return null;
                    length = (bytes[2] << 8) | bytes[3];
                    offset = 4;
                }
                else if (length == 127)
                {
                    if (bytes.Count < 10) return null;
                    length = 0;
                    for (var i = 2; i < 10; i++) length = (length << 8) | bytes[i];
                    offset = 10;
                }

                byte[] maskKey = Array.Empty<byte>();
                if (masked)
                {
                    if (bytes.Count < offset + 4) return null;
                    maskKey = bytes.GetRange(offset, 4).ToArray();
                    offset += 4;
                }
                if (bytes.Count < offset + length) return null;

                var payload = bytes.GetRange(offset, length).ToArray();
                if (masked)
                {
                    for (var i = 0; i < payload.Length; i++) payload[i] ^= maskKey[i % 4];
                }
                buffer.RemoveRange(0, offset + length);

                if (opcode == 0x8) return new ClientMessage.Close();
                if (opcode != 0x1 && opcode != 0x2) continue; // ping/pong etc.

                var message = Parse(Encoding.UTF8.GetString(payload));
                if (message is not null) return message;
            }
        }

        /// Wire text: "R" to resync, or "<phase> <x> <y>" where phase is D, M or U.
        private static ClientMessage? Parse(string text)
        {
            if (text == "R") return new ClientMessage.Resync();
            var parts = text.Split(' ');
            if (parts.Length == 3 && (parts[0] is "D" or "M" or "U")
                && int.TryParse(parts[1], out var x) && int.TryParse(parts[2], out var y))
            {
                return new ClientMessage.Input(parts[0], x, y);
            }
            return null;
        }
    }
}
