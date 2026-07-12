[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArgsFile
)

<#
Show-ProcessCloseWarning.ps1

Runs bridged into the interactive user's session (via SessionBridge.exe), never
directly by SCCM/Intune as SYSTEM - the WPF window would be invisible in Session 0.

IMPORTANT - this script is DISPLAY ONLY. It does not detect running processes and
it does not close them. Both of those stay with the SYSTEM-context caller:
  - Detection must stay with SYSTEM so it works reliably regardless of where the
    app is installed (%USERPROFILE%, Program Files, anywhere) - SYSTEM's process
    visibility is always complete, the user's own session-bridged token isn't.
  - Termination must stay with SYSTEM so it works even if the app happens to be
    running elevated (e.g. user launched it "as administrator") - a standard user
    token can hit Access Denied trying to close a higher-integrity process it
    doesn't have rights over, even if it's technically "their own" process.

This script's only job: show the list it's told to show, wait for the user to
click "Close & Continue" or for the timeout to elapse, then exit. The caller
does the actual detection before calling this, and the actual closing after.

Reads its parameters from a JSON file (rather than raw command-line args) so the
caller doesn't have to fight command-line quoting for an array of app names/paths.

Expected JSON shape:
{
  "DisplayName":    "Microsoft Visual Studio Code (User)",
  "TimeoutSeconds": 300,
  "WindowTitle":    "Action Required for Running Applications",
  "HeaderText":     "Applications Running",
  "SubHeaderText":  "Software deployment",
  "AppsToShow": [
    { "Name": "Visual Studio Code", "Path": "C:\\...\\Code.exe" }
  ]
}

Exit codes:
  0 = window closed normally (button clicked, or timeout elapsed - caller treats
      both the same: proceed to close the processes itself)
  1 = args file missing/unreadable, or an unexpected script error
#>

$ErrorActionPreference = "Stop"

try {
    if (-not (Test-Path $ArgsFile)) {
        Write-Host "ERROR: Args file not found: $ArgsFile"
        exit 1
    }

    $params = Get-Content -Path $ArgsFile -Raw | ConvertFrom-Json

    $DisplayName    = $params.DisplayName
    $TimeoutSeconds = if ($params.TimeoutSeconds) { [int]$params.TimeoutSeconds } else { 300 }
    $WindowTitle    = if ($params.WindowTitle)    { $params.WindowTitle }        else { "Action Required for Running Applications" }
    $HeaderText     = if ($params.HeaderText)     { $params.HeaderText }         else { "Applications Running" }
    $SubHeaderText  = if ($params.SubHeaderText)  { $params.SubHeaderText }      else { "Software deployment" }
    $AppsToShow     = @($params.AppsToShow)
}
catch {
    Write-Host "ERROR: Failed to read/parse args file: $($_.Exception.Message)"
    exit 1
}

# Best-effort cleanup of the temp args file - the caller already has everything
# it needs (it built this file itself), nothing further to hand back.
try { Remove-Item -Path $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }

if ($AppsToShow.Count -eq 0) {
    Write-Host "No apps to show for $DisplayName - nothing to display."
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, System.Drawing

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TitlePlaceholder"
        Width="540"
        MinHeight="360"
        SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        WindowStyle="ToolWindow"
        Topmost="True"
        Background="#FF0B4A80"
        FontFamily="Segoe UI">

    <Window.Resources>
        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="#FFD83B01"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="MinWidth" Value="160"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="15,0,15,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#FFEA4300"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#FFA42600"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="18">
        <Border Background="White" CornerRadius="12" Padding="24" SnapsToDevicePixels="True">
            <Border.Effect>
                <DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.22"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="44" Height="44" CornerRadius="22" Background="#FFFFF4CE" VerticalAlignment="Center">
                        <TextBlock Text="!" Foreground="#FF9A6700" FontSize="26" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
                        <TextBlock Name="HeaderText" Text="" FontSize="20" FontWeight="SemiBold" Foreground="#FF1F1F1F"/>
                        <TextBlock Name="SubHeaderText" Text="" FontSize="13" Foreground="#FF666666" Margin="0,2,0,0"/>
                    </StackPanel>
                </StackPanel>

                <TextBlock Grid.Row="1"
                           Text="The following applications are currently running and must be closed to continue:"
                           TextWrapping="Wrap" FontSize="14" Foreground="#FF333333" Margin="0,24,0,12"/>

                <Border Grid.Row="2" Background="#FFF8F9FA" CornerRadius="8" BorderBrush="#FFE9ECEF" BorderThickness="1" Padding="10">
                    <StackPanel Name="AppListContainer" />
                </Border>

                <TextBlock Grid.Row="3"
                           Text="Please save your work. These applications will be closed automatically when the timer below reaches zero, or immediately if you click the button."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF555555" Margin="0,16,0,16"/>

                <Border Grid.Row="4" Background="#FFFFF4CE" CornerRadius="6" Padding="11" Margin="0,0,0,18">
                    <TextBlock Name="TimerText" Text="" FontSize="13" FontWeight="SemiBold" Foreground="#FF5C4400" HorizontalAlignment="Center"/>
                </Border>

                <Button Grid.Row="5" Name="CloseAppButton" Content="Close &amp; Continue" HorizontalAlignment="Right" Style="{StaticResource PrimaryButtonStyle}"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = $WindowTitle
$window.FindName("HeaderText").Text = $HeaderText
$window.FindName("SubHeaderText").Text = $SubHeaderText
$AppListContainer = $window.FindName("AppListContainer")
$TimerText = $window.FindName("TimerText")
$CloseAppButton = $window.FindName("CloseAppButton")

# Purely cosmetic - just building the list of names/icons to display. No process
# handles, no PIDs, no Stop-Process anywhere in this script.
foreach ($app in $AppsToShow) {
    $itemPanel = New-Object System.Windows.Controls.StackPanel
    $itemPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $itemPanel.Margin = "8,6,8,6"

    if ($app.Path -and (Test-Path $app.Path)) {
        try {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($app.Path)
            $bitmapSource = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $icon.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $imageControl = New-Object System.Windows.Controls.Image
            $imageControl.Source = $bitmapSource
            $imageControl.Width = 24
            $imageControl.Height = 24
            $imageControl.Margin = "0,0,12,0"
            $imageControl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $itemPanel.Children.Add($imageControl) | Out-Null
        } catch { }
    }

    $textControl = New-Object System.Windows.Controls.TextBlock
    $textControl.Text = $app.Name
    $textControl.FontSize = 14
    $textControl.FontWeight = [System.Windows.FontWeights]::Medium
    $textControl.Foreground = "#FF1F1F1F"
    $textControl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $itemPanel.Children.Add($textControl) | Out-Null
    $AppListContainer.Children.Add($itemPanel) | Out-Null
}

$script:ForceCloseApproved = $false
$startTime = Get-Date

$window.Add_Closing({
    if (-not $script:ForceCloseApproved) { $_.Cancel = $true }
})

# NOTE: no Stop-Process here. Clicking the button (or hitting the timeout below)
# only closes the WINDOW - the caller (SYSTEM) does the actual process termination
# after this script exits.
$CloseAppButton.Add_Click({
    $script:ForceCloseApproved = $true
    if ($dispatcherTimer) { $dispatcherTimer.Stop() }
    $window.Close()
})

$dispatcherTimer = New-Object Windows.Threading.DispatcherTimer
$dispatcherTimer.Interval = [TimeSpan]::FromSeconds(1)
$dispatcherTimer.Add_Tick({
    $elapsed = (Get-Date) - $startTime
    $remaining = $TimeoutSeconds - [int]$elapsed.TotalSeconds
    if ($remaining -le 0) {
        $script:ForceCloseApproved = $true
        $dispatcherTimer.Stop()
        $window.Close()
    } else {
        $TimerText.Text = "Closing automatically in $remaining second(s)..."
    }
})

$dispatcherTimer.Start()
$window.ShowDialog() | Out-Null

exit 0
