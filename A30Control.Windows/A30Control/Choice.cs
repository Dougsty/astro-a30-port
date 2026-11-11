using System.Windows;
using System.Windows.Input;

namespace A30Control;

sealed class Relay(Action action) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? p) => true;
    public void Execute(object? p) => action();
}

/// One selectable row/pill/tab: preset, mic, noise gate, sleep, tones, base mode, saved curve, profile.
public sealed class Choice(string label, bool selected, Action apply, Action? remove = null)
{
    public string Label { get; } = label;
    public bool Selected { get; } = selected;
    public ICommand ApplyCmd { get; } = new Relay(apply);
    public ICommand? RemoveCmd { get; } = remove == null ? null : new Relay(remove);
    public Visibility RemoveVisibility => RemoveCmd == null ? Visibility.Collapsed : Visibility.Visible;
}
