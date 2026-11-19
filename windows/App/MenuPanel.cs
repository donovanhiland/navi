using System.Windows;
using System.Windows.Controls;
using Navi.Core;

namespace Navi.App;

public sealed class MenuPanel : NaviPopup
{
    private readonly Func<MenuCommand, bool> isBuilt;
    private readonly Action<MenuCommand> run;

    public MenuPanel(IReadOnlyList<MenuEntry> entries, Func<MenuCommand, bool> isBuilt, Action<MenuCommand> run, double width = NaviTheme.MenuWidth)
        : base(width)
    {
        ArgumentNullException.ThrowIfNull(entries);
        this.isBuilt = isBuilt ?? throw new ArgumentNullException(nameof(isBuilt));
        this.run = run ?? throw new ArgumentNullException(nameof(run));
        foreach (var entry in entries) Rows.Children.Add(RowFor(entry));
    }

    private Border RowFor(MenuEntry entry)
    {
        if (entry.IsSeparator) return PanelRows.Separator();
        if (entry.Submenu is { } submenu)
        {
            Border? row = null;
            row = PanelRows.Row(entry.Title, PanelRows.Shortcut("›"), () => OpenChild(new MenuPanel(submenu, isBuilt, run, 160), row!), submenu.Any(e => isBuilt(e.Command)));
            row.MouseEnter += (_, _) => { if (submenu.Any(e => isBuilt(e.Command))) OpenChild(new MenuPanel(submenu, isBuilt, run, 160), row); };
            return row;
        }
        var enabled = isBuilt(entry.Command);
        var item = PanelRows.Row(entry.Title, PanelRows.Shortcut(entry.Shortcut), () =>
        {
            CloseAll();
            run(entry.Command);
        }, enabled);
        if (!enabled) item.ToolTip = "Not built yet on Windows";
        item.MouseEnter += (_, _) => Child?.Close();
        return item;
    }
}
