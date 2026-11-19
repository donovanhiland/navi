using System.Windows;
using Navi.Core;
using Forms = System.Windows.Forms;

namespace Navi.App;

public sealed class NaviApp : IDisposable
{
    private const string ReleasesUrl = "https://github.com/donovanhiland/navi/releases";

    private static readonly HashSet<MenuCommand> Built = [MenuCommand.Settings, MenuCommand.CheckForUpdates, MenuCommand.Quit];

    private readonly Application application;
    private readonly SettingsStore settings;
    private readonly Inbox inbox;
    private TrayIcon? tray;
    private HotKeys? hotKeys;
    private NaviPopup? open;

    public NaviApp(Application application)
    {
        this.application = application ?? throw new ArgumentNullException(nameof(application));
        var directory = NaviPaths.DataDirectory(Program.IsDev);
        settings = new SettingsStore(directory);
        inbox = new Inbox(directory);
    }

    public void Start()
    {
        tray = new TrayIcon(NaviPaths.AppName(Program.IsDev));
        tray.Clicked += (_, at) => Toggle(() => ShowMenu(at));
        hotKeys = new HotKeys();
        hotKeys.Pressed += (_, action) => OnHotKey(action);
        RegisterHotKeys();
        StartupRegistration.Apply(settings.Current.StartWithWindows);
        settings.Changed += OnSettingsChanged;
    }

    public void Dispose()
    {
        settings.Changed -= OnSettingsChanged;
        open?.Close();
        hotKeys?.Dispose();
        tray?.Dispose();
    }

    private void OnSettingsChanged(object? sender, NaviSettings next)
    {
        StartupRegistration.Apply(next.StartWithWindows);
        RegisterHotKeys();
    }

    private void RegisterHotKeys()
    {
        if (hotKeys is null) return;
        hotKeys.UnregisterAll();
        var style = settings.Current.ShortcutStyle;
        hotKeys.Register(NaviAction.MenuAtMouse, KeyMap.Get(style, NaviAction.MenuAtMouse));
    }

    private void OnHotKey(NaviAction action)
    {
        if (action == NaviAction.MenuAtMouse) Toggle(() => ShowMenu(Forms.Cursor.Position));
    }

    private void Toggle(Action show)
    {
        if (open is { IsVisible: true })
        {
            open.CloseAll();
            return;
        }
        show();
    }

    private void ShowMenu(System.Drawing.Point at)
    {
        var state = new MenuState(settings.Current.ShortcutStyle, IsRecording: false, HasPins: false);
        var menu = new MenuPanel(NaviMenuModel.Build(state), Built.Contains, command => Run(command, at));
        Present(menu, at);
    }

    private void ShowSettings(System.Drawing.Point at) => Present(new SettingsPanel(settings, inbox), at);

    private void Present(NaviPopup popup, System.Drawing.Point at)
    {
        open?.CloseAll();
        open = popup;
        popup.Closed += (_, _) => { if (open == popup) open = null; };
        popup.ShowAt(at, PopupAnchor.AboveLeft);
    }

    private void Run(MenuCommand command, System.Drawing.Point at)
    {
        switch (command)
        {
            case MenuCommand.Settings:
                application.Dispatcher.BeginInvoke(() => ShowSettings(at));
                break;
            case MenuCommand.CheckForUpdates:
                Shell.Open(ReleasesUrl);
                break;
            case MenuCommand.Quit:
                application.Shutdown();
                break;
            default:
                ErrorLog.Write($"{command} is not built yet on Windows");
                break;
        }
    }
}
