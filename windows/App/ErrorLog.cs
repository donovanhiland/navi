using System.IO;
using System.Globalization;
using Navi.Core;

namespace Navi.App;

public static class ErrorLog
{
    public static string FilePath => Path.Combine(NaviPaths.DataDirectory(Program.IsDev), "navi.log");

    public static void Write(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        Write(error.ToString());
    }

    public static void Write(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var line = string.Create(CultureInfo.InvariantCulture, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
            File.AppendAllText(FilePath, line);
        }
        catch (IOException)
        {
            System.Diagnostics.Trace.WriteLine(message);
        }
        catch (UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.WriteLine(message);
        }
    }
}
