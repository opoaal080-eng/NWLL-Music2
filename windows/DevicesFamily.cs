using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Nightwell.Native;

/// <summary>The same account-access device and family API used by the mobile clients.</summary>
public partial class MainWindow
{
    Border? familyPane;
    StackPanel? familyContents;
    TextBlock? familyMessage;
    bool familyLoading;

    void CreateFamilyPane()
    {
        familyPane = MakeWorkspacePane("Устройства и семья", out var pane);
        familyContents = pane;
    }

    void OpenFamilyPane()
    {
        if (account.Length == 0) { Login(); return; }
        ShowDesktopPane(familyPane);
        _ = RefreshFamilyPane();
    }

    async Task RefreshFamilyPane()
    {
        if (familyContents == null || familyLoading) return;
        familyLoading = true;
        var content = familyContents;
        content.Children.Clear();
        familyMessage = new TextBlock
        {
            Text = "Загружаем устройства и семейные настройки…",
            Foreground = SecondaryText, FontSize = 13, TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 16)
        };
        content.Children.Add(familyMessage);
        try
        {
            var results = await Task.WhenAll(api.Request("api/devices"), api.Request("api/family"));
            if (familyPane?.Visibility != Visibility.Visible) return;
            var devices = results[0];
            var familyResponse = results[1];
            content.Children.Clear();
            familyMessage = new TextBlock
            {
                Foreground = SecondaryText, TextWrapping = TextWrapping.Wrap, FontSize = 13,
                Margin = new Thickness(0, 4, 0, 12)
            };
            content.Children.Add(familyMessage);
            RenderDevices(content, devices);
            RenderFamily(content, familyResponse);
        }
        catch (Exception ex)
        {
            if (familyMessage != null)
                familyMessage.Text = "Не удалось загрузить устройства и семью: " + ex.Message +
                    "\nПроверь, что серверный модуль Account Access установлен.";
        }
        finally { familyLoading = false; }
    }

    static string SafeText(JsonElement element, string property, string fallback = "")
    {
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? fallback : fallback;
    }
    static bool SafeFlag(JsonElement element, string property)
    {
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.True;
    }
    static int SafeInt(JsonElement element, string property, int fallback = 0)
    {
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.Number &&
            value.TryGetInt32(out var number) ? number : fallback;
    }
    static string FriendlyDeviceType(string platform) => platform switch
    {
        "ios" => "iPhone / iPad", "android" => "Android", "windows" => "Windows",
        "web" => "Браузер", _ => "Устройство"
    };
    static string FriendlyTime(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Number &&
            element.TryGetInt64(out long time) && time > 0)
        {
            try { return DateTimeOffset.FromUnixTimeSeconds(time).ToLocalTime().ToString("dd.MM.yyyy HH:mm"); }
            catch (ArgumentOutOfRangeException) { }
        }
        return "Нет данных";
    }

    Button FamilyActionButton(string title, Action action, bool primary = false)
    {
        var button = new Button
        {
            Content = title,
            Style = (Style)FindResource(primary ? "PrimaryButton" : "QuietButton"),
            MinHeight = 40,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 6, 0, 6),
            Padding = new Thickness(16, 8, 16, 8)
        };
        button.Click += (_, _) => action();
        return button;
    }

    void RenderDevices(StackPanel content, JsonElement response)
    {
        int limit = SafeInt(response, "limit", 2);
        int count = SafeInt(response, "count");
        content.Children.Add(SectionLabel("МОИ УСТРОЙСТВА"));
        content.Children.Add(new TextBlock
        {
            Text = $"{count} из {limit} подключённых устройств",
            Foreground = SecondaryText, FontSize = 13, Margin = new Thickness(1, 0, 0, 10)
        });
        if (!response.TryGetProperty("devices", out var list) || list.ValueKind != JsonValueKind.Array) return;
        foreach (var device in list.EnumerateArray())
        {
            string id = SafeText(device, "id");
            if (id.Length == 0) continue;
            string name = SafeText(device, "name", FriendlyDeviceType(SafeText(device, "platform")));
            bool current = SafeFlag(device, "current");
            bool blocked = SafeFlag(device, "blocked");
            var row = new StackPanel { Margin = new Thickness(0, 3, 0, 3) };
            var header = new StackPanel { Orientation = Orientation.Horizontal };
            header.Children.Add(NightwellIcons.Draw("devices", 23));
            header.Children.Add(new TextBlock
            {
                Text = name,
                FontSize = 15, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center
            });
            row.Children.Add(header);
            string label = FriendlyDeviceType(SafeText(device, "platform")) +
                (current ? " · это устройство" : "") +
                (blocked ? " · вне лимита" : "");
            row.Children.Add(new TextBlock
            {
                Text = label + "\nБыл в сети: " +
                  (device.TryGetProperty("last_seen", out var seen) ? FriendlyTime(seen) : "Нет данных"),
                Foreground = SecondaryText, FontSize = 12,
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(35, 5, 0, 5)
            });
            row.Children.Add(FamilyActionButton(current ? "Отключить это устройство" : "Удалить устройство", () =>
            {
                if (!ConfirmFamily(current
                    ? "Это устройство будет отключено, потребуется повторный вход."
                    : "Отключить устройство от аккаунта?")) return;
                _ = FamilyOperation(async () =>
                {
                    await api.Request("api/devices/" + Uri.EscapeDataString(id), "DELETE");
                    if (current)
                    {
                        api.Clear();
                        account = "";
                        Show("Главная");
                        Status.Text = "Устройство отключено. Войди в аккаунт заново.";
                    }
                }, !current);
            }));
            content.Children.Add(SettingsCard(row));
        }
    }

    void RenderFamily(StackPanel content, JsonElement response)
    {
        content.Children.Add(SectionLabel("СЕМЕЙНАЯ ПОДПИСКА"));
        bool hasFamily = response.TryGetProperty("family", out var family) &&
            family.ValueKind == JsonValueKind.Object;
        bool billingOwner = response.TryGetProperty("access", out var access) &&
            SafeFlag(access, "billing_owner");
        if (!hasFamily)
        {
            content.Children.Add(new TextBlock
            {
                Text = "Семья не настроена. Premium позволяет делиться подпиской с двумя участниками.",
                Foreground = SecondaryText, TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 12)
            });
            if (billingOwner)
                content.Children.Add(FamilyActionButton("Пригласить участника", CreateFamilyInvite, true));
            AddFamilyInviteInput(content);
            return;
        }

        bool owner = SafeText(family, "role") == "owner";
        int members = SafeInt(family, "member_count");
        int capacity = SafeInt(family, "capacity", 3);
        content.Children.Add(new TextBlock
        {
            Text = $"Участники: {members} из {capacity}" + (owner ? " · вы организатор" : " · вы участник"),
            Foreground = SecondaryText, Margin = new Thickness(0, 0, 0, 12)
        });
        if (family.TryGetProperty("members", out var items) && items.ValueKind == JsonValueKind.Array)
        {
            foreach (var member in items.EnumerateArray())
            {
                string memberID = SafeText(member, "account_id");
                if (memberID.Length == 0) continue;
                bool isOwner = SafeText(member, "role") == "owner";
                var row = new StackPanel();
                row.Children.Add(new TextBlock
                {
                    Text = isOwner ? "Организатор" : "Участник",
                    FontSize = 15, FontWeight = FontWeights.SemiBold
                });
                row.Children.Add(new TextBlock
                {
                    Text = "Аккаунт · " + (memberID.Length > 8 ? memberID[^8..] : memberID),
                    Foreground = SecondaryText, FontSize = 12, Margin = new Thickness(0, 4, 0, 0)
                });
                if (owner && !isOwner)
                    row.Children.Add(FamilyActionButton("Удалить из семьи", () =>
                    {
                        if (!ConfirmFamily("Убрать участника из семейной подписки?")) return;
                        _ = FamilyOperation(() => api.Request("api/family/members/" +
                            Uri.EscapeDataString(memberID), "DELETE"));
                    }));
                content.Children.Add(SettingsCard(row));
            }
        }
        if (owner)
        {
            if (SafeInt(family, "available_invites", 0) > 0)
                content.Children.Add(FamilyActionButton("Создать приглашение", CreateFamilyInvite, true));
            if (family.TryGetProperty("pending_invites", out var pending) &&
                pending.ValueKind == JsonValueKind.Array)
            {
                foreach (var invitation in pending.EnumerateArray())
                {
                    var inviteID = SafeText(invitation, "id");
                    if (inviteID.Length == 0) continue;
                    content.Children.Add(FamilyActionButton("Отозвать неиспользованное приглашение", () =>
                    {
                        if (!ConfirmFamily("Отозвать это приглашение?")) return;
                        _ = FamilyOperation(() => api.Request("api/family/invitations/" +
                            Uri.EscapeDataString(inviteID), "DELETE"));
                    }));
                }
            }
            content.Children.Add(FamilyActionButton("Распустить семью", () =>
            {
                if (!ConfirmFamily("Распустить семью и отключить семейный доступ у участников?")) return;
                _ = FamilyOperation(() => api.Request("api/family", "DELETE"));
            }));
        }
        else
        {
            content.Children.Add(FamilyActionButton("Выйти из семьи", () =>
            {
                if (!ConfirmFamily("Покинуть семейную подписку?")) return;
                _ = FamilyOperation(() => api.Request("api/family/leave", "POST"));
            }));
        }
    }

    void AddFamilyInviteInput(StackPanel content)
    {
        var input = new TextBox
        {
            Tag = "Ссылка или код приглашения", MinWidth = 320,
            Margin = new Thickness(0, 12, 0, 6)
        };
        content.Children.Add(input);
        content.Children.Add(FamilyActionButton("Принять приглашение", () =>
        {
            string value = input.Text.Trim();
            int index = value.IndexOf("invite=", StringComparison.OrdinalIgnoreCase);
            if (index >= 0) value = value[(index + 7)..].Split('&', '#')[0];
            value = Uri.UnescapeDataString(value);
            if (value.Length < 32 || value.Length > 256)
            {
                SetFamilyMessage("Вставь действительную ссылку или код приглашения.");
                return;
            }
            var token = value;
            _ = FamilyOperation(() => api.Request("api/family/invitations/accept",
                "POST", new { token }));
        }, true));
    }

    void CreateFamilyInvite() => _ = FamilyOperation(async () =>
    {
        var response = await api.Request("api/family/invitations", "POST");
        string link = SafeText(response, "invite_url");
        if (link.Length == 0) throw new InvalidOperationException("Сервер не вернул ссылку приглашения");
        Clipboard.SetText(link);
        SetFamilyMessage("Ссылка скопирована в буфер обмена. Отправь её участнику.");
    });

    bool ConfirmFamily(string question) => MessageBox.Show(this, question, "Nightwell Music",
        MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

    void SetFamilyMessage(string text)
    {
        if (familyMessage != null) familyMessage.Text = text;
    }
    async Task FamilyOperation(Func<Task> action, bool refresh = true)
    {
        try
        {
            await action();
            if (refresh) await RefreshFamilyPane();
        }
        catch (Exception ex) { SetFamilyMessage(ex.Message); }
    }
}
