using System.Security.Cryptography;
using System.Text;

namespace NotesCore;

public enum NoteCryptoError
{
    /// <summary>Too short, no magic, iteration count out of range, or the plaintext is not UTF-8.</summary>
    Damaged,
    /// <summary>Unknown format version or key derivation: written by a newer app; leave the file alone.</summary>
    NewerVersion,
    /// <summary>Authentication failed: a wrong password and tampered data can not be told apart.</summary>
    WrongPasswordOrDamaged,
}

public sealed class NoteCryptoException(NoteCryptoError error) : Exception
{
    public NoteCryptoError Error { get; } = error;

    public override string Message => Strings.Get(Error switch
    {
        NoteCryptoError.Damaged => "CryptoDamaged",
        NoteCryptoError.NewerVersion => "CryptoNewerVersion",
        _ => "CryptoWrongPassword",
    });
}

/// <summary>
/// The `.mdenc` file format (docs/format.md, "Encrypted notes"): a 42-byte header, AES-256-GCM ciphertext, 16-byte tag.
/// The header is the authenticated data. Pure functions; callers keep a <see cref="Key"/> per unlocked file so only the
/// first unlock pays for the key derivation.
/// </summary>
public static class NoteCrypto
{
    public const string FileExtension = "mdenc";
    public const uint DefaultIterations = 600_000;
    public const uint MinIterations = 10_000;
    public const uint MaxIterations = 10_000_000;

    private static readonly byte[] Magic = "NOTESENC"u8.ToArray();
    private const byte Version = 1;
    private const byte KdfPbkdf2Sha256 = 1;
    private const int SaltSize = 16;
    private const int NonceSize = 12;
    private const int TagSize = 16;
    private const int HeaderSize = 42;
    private const int KeySize = 32;

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>
    /// A derived key with the salt and iteration count it came from (what goes into a file's header).
    /// Never printed: <see cref="ToString"/> shows no material.
    /// </summary>
    public sealed class Key
    {
        private readonly byte[] salt;
        internal readonly byte[] Material;

        internal Key(byte[] salt, uint iterations, byte[] material)
        {
            this.salt = salt;
            Iterations = iterations;
            Material = material;
        }

        public uint Iterations { get; }

        public byte[] Salt => (byte[])salt.Clone();

        /// <summary>
        /// Whether <paramref name="data"/> is an encrypted note made with this key's salt and iterations, so the key can
        /// decrypt it (or fails authentication) without deriving again. Looks at the header only.
        /// </summary>
        public bool Matches(byte[] data) =>
            TryParseHeader(data, out var header) && header.Salt.AsSpan().SequenceEqual(salt) && header.Iterations == Iterations;

        public override string ToString() => $"NoteCrypto.Key(iterations: {Iterations})";
    }

    private readonly record struct Header(uint Iterations, byte[] Salt);

    private static Header ParseHeader(byte[] data)
    {
        if (data.Length < HeaderSize + TagSize || !data.AsSpan(0, Magic.Length).SequenceEqual(Magic))
            throw new NoteCryptoException(NoteCryptoError.Damaged);
        if (data[8] != Version || data[9] != KdfPbkdf2Sha256) throw new NoteCryptoException(NoteCryptoError.NewerVersion);
        var iterations = (uint)(data[10] << 24 | data[11] << 16 | data[12] << 8 | data[13]);
        if (iterations is < MinIterations or > MaxIterations) throw new NoteCryptoException(NoteCryptoError.Damaged);
        return new Header(iterations, data[14..30]);
    }

    private static bool TryParseHeader(byte[] data, out Header header)
    {
        try
        {
            header = ParseHeader(data);
            return true;
        }
        catch (NoteCryptoException)
        {
            header = default;
            return false;
        }
    }

    /// <summary>A key for a new password: random salt, <see cref="DefaultIterations"/>. Slow on purpose (about 0.2 s): call it off the UI thread.</summary>
    public static Key NewKey(string password) => NewKey(password, DefaultIterations);

    /// <summary><paramref name="iterations"/> is for tests.</summary>
    internal static Key NewKey(string password, uint iterations)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        return new Key(salt, iterations, Derive(password, salt, iterations));
    }

    /// <summary>
    /// The key <paramref name="password"/> gives for the file <paramref name="data"/> (its salt and iterations). Throws
    /// <see cref="NoteCryptoError.Damaged"/> or <see cref="NoteCryptoError.NewerVersion"/> for a bad header; a wrong
    /// password is only found by <see cref="Decrypt"/>. Slow like <see cref="NewKey(string)"/>: call it off the UI thread.
    /// </summary>
    public static Key KeyFor(string password, byte[] data)
    {
        var header = ParseHeader(data);
        return new Key(header.Salt, header.Iterations, Derive(password, header.Salt, header.Iterations));
    }

    /// <summary>The file bytes for <paramref name="text"/> (in on-disk form, see <see cref="NoteFile.Normalized"/>), with a new random nonce every call.</summary>
    public static byte[] Encrypt(string text, Key key) => Encrypt(text, key, RandomNumberGenerator.GetBytes(NonceSize));

    /// <summary><paramref name="nonce"/> is for the known-answer test; never pass a fixed nonce otherwise.</summary>
    internal static byte[] Encrypt(string text, Key key, byte[] nonce)
    {
        var plain = StrictUtf8.GetBytes(NoteFile.Normalized(text));
        var result = new byte[HeaderSize + plain.Length + TagSize];
        Magic.CopyTo(result, 0);
        result[8] = Version;
        result[9] = KdfPbkdf2Sha256;
        result[10] = (byte)(key.Iterations >> 24);
        result[11] = (byte)(key.Iterations >> 16);
        result[12] = (byte)(key.Iterations >> 8);
        result[13] = (byte)key.Iterations;
        key.Salt.CopyTo(result, 14);
        nonce.CopyTo(result, 30);
        using var aes = new AesGcm(key.Material, TagSize);
        aes.Encrypt(nonce, plain, result.AsSpan(HeaderSize, plain.Length), result.AsSpan(HeaderSize + plain.Length, TagSize),
            result.AsSpan(0, HeaderSize));
        return result;
    }

    /// <summary>
    /// The text of the file <paramref name="data"/>. Throws <see cref="NoteCryptoError.Damaged"/> (bad header, not UTF-8),
    /// <see cref="NoteCryptoError.NewerVersion"/>, or <see cref="NoteCryptoError.WrongPasswordOrDamaged"/> (authentication
    /// failed, including a key made for another salt or iteration count).
    /// </summary>
    public static string Decrypt(byte[] data, Key key)
    {
        ParseHeader(data);
        var plain = new byte[data.Length - HeaderSize - TagSize];
        try
        {
            using var aes = new AesGcm(key.Material, TagSize);
            aes.Decrypt(data.AsSpan(30, NonceSize), data.AsSpan(HeaderSize, plain.Length), data.AsSpan(data.Length - TagSize, TagSize),
                plain, data.AsSpan(0, HeaderSize));
        }
        catch (CryptographicException)
        {
            throw new NoteCryptoException(NoteCryptoError.WrongPasswordOrDamaged);
        }
        try
        {
            return StrictUtf8.GetString(plain);
        }
        catch (DecoderFallbackException)
        {
            throw new NoteCryptoException(NoteCryptoError.Damaged);
        }
    }

    /// <summary>The key for a given salt (tests).</summary>
    internal static Key KeyFor(string password, byte[] salt, uint iterations) =>
        new((byte[])salt.Clone(), iterations, Derive(password, salt, iterations));

    private static byte[] Derive(string password, byte[] salt, uint iterations)
    {
        var passwordBytes = Encoding.UTF8.GetBytes(password.Normalize(NormalizationForm.FormC));
        try
        {
            return Rfc2898DeriveBytes.Pbkdf2(passwordBytes, salt, checked((int)iterations), HashAlgorithmName.SHA256, KeySize);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(passwordBytes);
        }
    }
}
