namespace Navi.Core;

public static class NaviPaths
{
    public const string ReleaseName = "Navi";
    public const string DevName = "Navi Dev";

    public static string AppName(bool isDev) => isDev ? DevName : ReleaseName;

    public static string DataDirectory(bool isDev) =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppName(isDev));
}
