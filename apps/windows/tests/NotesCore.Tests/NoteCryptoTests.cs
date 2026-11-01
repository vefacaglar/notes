using System.Text;
using NotesCore;

namespace NotesCore.Tests;

public sealed class NoteCryptoTests : IDisposable
{
    private const uint Iterations = 10_000;
    private readonly NoteCrypto.Key key = NoteCrypto.NewKey("parola", Iterations);
    private readonly NotesTempFolder temp = new();

    public void Dispose() => temp.Dispose();

    private static NoteCryptoError ErrorOf(Action action) => Assert.Throws<NoteCryptoException>(action).Error;

    private static byte[] With(byte[] data, int index, byte value)
    {
        var copy = (byte[])data.Clone();
        copy[index] = value;
        return copy;
    }

    [Theory]
    [InlineData("")]
    [InlineData("hello")]
    [InlineData("Toplantı İşğüçö ıİ")]
    [InlineData("emoji 👩‍👩‍👧 🇹🇷")]
    [InlineData("a\nb\n")]
    public void RoundTrip(string text)
    {
        var data = NoteCrypto.Encrypt(text, key);
        Assert.Equal(text, NoteCrypto.Decrypt(data, key));
        Assert.Equal(58 + Encoding.UTF8.GetByteCount(text), data.Length);
    }

    [Fact]
    public void CrlfAndBOMAreNormalized()
    {
        var data = NoteCrypto.Encrypt("﻿a\r\nb", key);
        Assert.Equal("a\nb", NoteCrypto.Decrypt(data, key));
    }

    [Fact]
    public void HeaderLayout()
    {
        var data = NoteCrypto.Encrypt("x", key);
        Assert.Equal("NOTESENC"u8.ToArray(), data[..8]);
        Assert.Equal(1, data[8]);
        Assert.Equal(1, data[9]);
        Assert.Equal(new byte[] { 0, 0, 0x27, 0x10 }, data[10..14]);
        Assert.Equal(key.Salt, data[14..30]);
    }

    [Fact]
    public void WrongPassword()
    {
        var data = NoteCrypto.Encrypt("secret", key);
        var other = NoteCrypto.NewKey("başka", Iterations);
        Assert.Equal(NoteCryptoError.WrongPasswordOrDamaged, ErrorOf(() => NoteCrypto.Decrypt(data, other)));
        var sameSalt = NoteCrypto.KeyFor("başka", data);
        Assert.Equal(NoteCryptoError.WrongPasswordOrDamaged, ErrorOf(() => NoteCrypto.Decrypt(data, sameSalt)));
    }

    [Fact]
    public void EveryByteIsAuthenticated()
    {
        var data = NoteCrypto.Encrypt("secret text", key);
        for (var index = 0; index < data.Length; index++)
        {
            var error = Assert.Throws<NoteCryptoException>(() => NoteCrypto.Decrypt(With(data, index, (byte)(data[index] ^ 1)), key)).Error;
            if (index < 8) Assert.Equal(NoteCryptoError.Damaged, error);
            else if (index < 10) Assert.Equal(NoteCryptoError.NewerVersion, error);
            else if (index is 10 or 11 or 12)
                Assert.True(error is NoteCryptoError.Damaged or NoteCryptoError.WrongPasswordOrDamaged, $"byte {index}: {error}");
            else Assert.Equal(NoteCryptoError.WrongPasswordOrDamaged, error);
        }
    }

    [Fact]
    public void TruncatedOrExtendedFails()
    {
        var data = NoteCrypto.Encrypt("secret text", key);
        for (var cut = 1; cut <= data.Length; cut++)
        {
            var shorter = data[..^cut];
            Assert.Throws<NoteCryptoException>(() => NoteCrypto.Decrypt(shorter, key));
        }
        Assert.Equal(NoteCryptoError.WrongPasswordOrDamaged, ErrorOf(() => NoteCrypto.Decrypt([.. data, 0], key)));
    }

    [Fact]
    public void TooShortOrNoMagic()
    {
        var data = NoteCrypto.Encrypt("", key);
        Assert.Equal(58, data.Length);
        Assert.Equal(NoteCryptoError.Damaged, ErrorOf(() => NoteCrypto.Decrypt([], key)));
        Assert.Equal(NoteCryptoError.Damaged, ErrorOf(() => NoteCrypto.Decrypt(data[..^1], key)));
        Assert.Equal(NoteCryptoError.Damaged, ErrorOf(() => NoteCrypto.Decrypt(Enumerable.Repeat((byte)0x41, 100).ToArray(), key)));
        Assert.Equal(NoteCryptoError.Damaged, ErrorOf(() => NoteCrypto.KeyFor("x", "hello"u8.ToArray())));
    }

    [Fact]
    public void UnknownVersionAndKdf()
    {
        var data = With(NoteCrypto.Encrypt("x", key), 8, 2);
        Assert.Equal(NoteCryptoError.NewerVersion, ErrorOf(() => NoteCrypto.Decrypt(data, key)));
        Assert.Equal(NoteCryptoError.NewerVersion, ErrorOf(() => NoteCrypto.KeyFor("x", data)));
        data[8] = 1;
        data[9] = 2;
        Assert.Equal(NoteCryptoError.NewerVersion, ErrorOf(() => NoteCrypto.Decrypt(data, key)));
    }

    [Fact]
    public void IterationBounds()
    {
        var data = NoteCrypto.Encrypt("x", key);
        byte[] WithIterations(uint n)
        {
            var copy = (byte[])data.Clone();
            for (var i = 0; i < 4; i++) copy[10 + i] = (byte)((n >> (24 - 8 * i)) & 0xFF);
            return copy;
        }
        foreach (var bad in new uint[] { 0, 9_999, 10_000_001, uint.MaxValue })
            Assert.Equal(NoteCryptoError.Damaged, ErrorOf(() => NoteCrypto.KeyFor("x", WithIterations(bad))));
        NoteCrypto.KeyFor("x", WithIterations(10_000));
    }

    [Fact]
    public void NonceDiffersBetweenEncryptions()
    {
        var a = NoteCrypto.Encrypt("same", key);
        var b = NoteCrypto.Encrypt("same", key);
        Assert.NotEqual(a[30..42], b[30..42]);
        Assert.NotEqual(a, b);
        Assert.Equal(a[..30], b[..30]);
    }

    [Fact]
    public void KeyForDataDecrypts()
    {
        var data = NoteCrypto.Encrypt("içerik", key);
        var again = NoteCrypto.KeyFor("parola", data);
        Assert.Equal(key.Salt, again.Salt);
        Assert.Equal(key.Iterations, again.Iterations);
        Assert.Equal("içerik", NoteCrypto.Decrypt(data, again));
    }

    [Fact]
    public void PasswordIsNFCNormalized()
    {
        var k = NoteCrypto.NewKey("café", Iterations);
        var data = NoteCrypto.Encrypt("x", k);
        var k2 = NoteCrypto.KeyFor("café", data);
        Assert.Equal("x", NoteCrypto.Decrypt(data, k2));
    }

    [Fact]
    public void MatchesComparesSaltAndIterations()
    {
        var data = NoteCrypto.Encrypt("x", key);
        Assert.True(key.Matches(data));
        Assert.False(NoteCrypto.NewKey("parola", Iterations).Matches(data));
        Assert.False(key.Matches("junk"u8.ToArray()));
        Assert.False(key.Matches(With(data, 13, (byte)(data[13] ^ 1))));
    }

    [Fact]
    public void ToStringHidesMaterial()
    {
        Assert.Equal("NoteCrypto.Key(iterations: 10000)", key.ToString());
        Assert.DoesNotContain("Material", $"{key}");
    }

    [Fact]
    public void DefaultIterationsRoundTrip()
    {
        var k = NoteCrypto.NewKey("p");
        Assert.Equal(600_000u, k.Iterations);
        var data = NoteCrypto.Encrypt("x", k);
        Assert.Equal("x", NoteCrypto.Decrypt(data, NoteCrypto.KeyFor("p", data)));
    }

    [Fact]
    public void ErrorMessages()
    {
        Assert.Equal("The password is wrong or the file is damaged.", new NoteCryptoException(NoteCryptoError.WrongPasswordOrDamaged).Message);
        Assert.Equal("This encrypted note is damaged.", new NoteCryptoException(NoteCryptoError.Damaged).Message);
        Assert.Equal("This encrypted note was made by a newer version of Notes.", new NoteCryptoException(NoteCryptoError.NewerVersion).Message);
        using var _ = TestCulture.Use("tr");
        Assert.Equal("Parola yanlış ya da dosya bozuk.", new NoteCryptoException(NoteCryptoError.WrongPasswordOrDamaged).Message);
        Assert.Equal("Bu şifreli not bozuk.", new NoteCryptoException(NoteCryptoError.Damaged).Message);
        Assert.Equal("Bu şifreli not Notes'un daha yeni bir sürümüyle oluşturulmuş.", new NoteCryptoException(NoteCryptoError.NewerVersion).Message);
    }

    [Fact]
    public void WritesAndReadsBytesAtomically()
    {
        var file = Path.Combine(temp.Path, "crypto.mdenc");
        NoteFile.Write(NoteCrypto.Encrypt("x", key), file);
        var second = NoteCrypto.Encrypt("y", key);
        NoteFile.Write(second, file);
        Assert.Equal(second, NoteFile.ReadData(file));
        Assert.Equal([file], Directory.GetFiles(temp.Path));
    }

    [Fact]
    public void NonUtf8PlaintextIsDamaged()
    {
        // Encrypt bytes that are not UTF-8 with the same layout, as a damaged-but-authentic file would be.
        var data = NoteCrypto.Encrypt("aaa", key);
        using var aes = new System.Security.Cryptography.AesGcm(key.Material, 16);
        byte[] plain = [0x61, 0xFF, 0x62];
        var forged = new byte[42 + plain.Length + 16];
        data.AsSpan(0, 42).CopyTo(forged);
        aes.Encrypt(forged.AsSpan(30, 12), plain, forged.AsSpan(42, plain.Length), forged.AsSpan(42 + plain.Length, 16), forged.AsSpan(0, 42));
        Assert.Equal(NoteCryptoError.Damaged, ErrorOf(() => NoteCrypto.Decrypt(forged, key)));
    }

    /// <summary>The shared test vector (docs/format.md): byte for byte what the macOS app produces.</summary>
    [Fact]
    public void KnownAnswer()
    {
        var salt = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
        var nonce = Enumerable.Range(0, 12).Select(i => (byte)i).ToArray();
        var k = NoteCrypto.KeyFor("correct horse", salt, 10_000);
        var data = NoteCrypto.Encrypt("# Merhaba\nşifreli not\n", k, nonce);
        const string hex = "4e4f544553454e43010100002710000102030405060708090a0b0c0d0e0f000102030405060708090a0b59043478fa207924476c2c15bf69de34aaf25bac4a610f213beff55d3b7b60643ffafff21e5309";
        Assert.Equal(hex, Convert.ToHexStringLower(data));
        Assert.Equal("# Merhaba\nşifreli not\n", NoteCrypto.Decrypt(data, k));
        Assert.Equal("# Merhaba\nşifreli not\n", NoteCrypto.Decrypt(Convert.FromHexString(hex), NoteCrypto.KeyFor("correct horse", Convert.FromHexString(hex))));
    }
}
