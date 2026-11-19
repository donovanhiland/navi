using System.Windows;
using Navi.Core;

namespace Navi.App;

public static class Program
{
#if NAVI_DEV
    public const bool IsDev = true;
#else
    public const bool IsDev = false;
#endif

    [STAThread]
    public static int Main()
    {
        using var single = new Mutex(initiallyOwned: true, $@"Local\{NaviPaths.AppName(IsDev)}.SingleInstance", out var first);
        if (!first) return 0;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            ErrorLog.Write(e.Exception);
            e.Handled = true;
        };
        using var navi = new NaviApp(app);
        app.Startup += (_, _) => navi.Start();
        return app.Run();
    }
}
