<#
.NOTES
    Author         : Om Prakash Bharati @samnickgammer
    Runspace Author: @samnickgammmer
    GitHub         : https://github.com/samnickgammer
    Version        : 26.02.18
#>

param (
    [switch]$Debug,
    [string]$Config,
    [switch]$Run
)

# Set DebugPreference based on the -Debug switch
if ($Debug) {
    $DebugPreference = "Continue"
}

if ($Config) {
    $PARAM_CONFIG = $Config
}

$PARAM_RUN = $false
# Handle the -Run switch
if ($Run) {
    Write-Host "Running config file tasks..."
    $PARAM_RUN = $true
}

# Load DLLs
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.PSScriptRoot = $PSScriptRoot
$sync.version = "26.02.18"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.ProcessRunning = $false
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"
$sync.selectedAppsStackPanel
$sync.selectedAppsPopup


if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Winutil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# Set the path for the winutil directory
$winutildir = "$env:LocalAppData\winutil"
New-Item $winutildir -ItemType Directory -Force | Out-Null

$logdir = "$winutildir\logs"
New-Item $logdir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$logdir\winutil_$dateTime.log" -Append -NoClobber | Out-Null

# Set PowerShell window title
$Host.UI.RawUI.WindowTitle = "WinUtil (Admin)"
clear-host
    function Add-SelectedAppsMenuItem {
        <#
        .SYNOPSIS
            This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

        .Parameter name
            The actual Name of an App like "Chrome" or "Brave"
            This name is contained in the "Content" property inside the applications.json
        .PARAMETER key
            The key which identifies an app object in applications.json
            For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
        #>

        param ([string]$name, [string]$key)

        $selectedAppGrid = New-Object Windows.Controls.Grid

        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

        # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
        # With the tooltip, you can still read the whole entry on hover
        $selectedAppLabel = New-Object Windows.Controls.Label
        $selectedAppLabel.Content = $name
        $selectedAppLabel.ToolTip = $name
        $selectedAppLabel.HorizontalAlignment = "Left"
        $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
        $selectedAppGrid.Children.Add($selectedAppLabel)

        $selectedAppRemoveButton = New-Object Windows.Controls.Button
        $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
        $selectedAppRemoveButton.Content = [string]([char]0xE711)
        $selectedAppRemoveButton.HorizontalAlignment = "Center"
        $selectedAppRemoveButton.Tag = $key
        $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

        # Highlight the Remove icon on Hover
        $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
        $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
        $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
        })
        [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
        $selectedAppGrid.Children.Add($selectedAppRemoveButton)
        # Add new Element to Popup
        $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
    }
function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )
    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container
            $_.Visibility = [Windows.Visibility]::Visible

            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # Respect the collapsed state of categories (indicated by + prefix)
                if ($categoryLabel.Content -like "+*") {
                    $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                } else {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                }

                # Show all apps within the category
                $wrapPanel.Children | ForEach-Object {
                    $_.Visibility = [Windows.Visibility]::Visible
                }
            }
        }
        return
    }

    # Perform search
    $sync.ItemsControl.Items | ForEach-Object {
        # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
        if ($_.Children.Count -ge 2) {
            $categoryLabel = $_.Children[0]
            $wrapPanel = $_.Children[1]
            $categoryHasMatch = $false

            # Keep category label visible
            $categoryLabel.Visibility = [Windows.Visibility]::Visible

            # Search through apps in this category
            $wrapPanel.Children | ForEach-Object {
                $appEntry = $sync.configs.applicationsHashtable.$($_.Tag)
                if ($appEntry.Content -like "*$SearchString*" -or $appEntry.Description -like "*$SearchString*") {
                    # Show the App and mark that this category has a match
                    $_.Visibility = [Windows.Visibility]::Visible
                    $categoryHasMatch = $true
                }
                else {
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }

            # If category has matches, show the WrapPanel and update the category label to expanded state
            if ($categoryHasMatch) {
                $wrapPanel.Visibility = [Windows.Visibility]::Visible
                $_.Visibility = [Windows.Visibility]::Visible
                # Update category label to show expanded state (-)
                if ($categoryLabel.Content -like "+*") {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                }
            } else {
                # Hide the entire category container if no matches
                $_.Visibility = [Windows.Visibility]::Collapsed
            }
        }
    }
}
function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )

    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        # Show all categories
        $tweakspanel = $sync.Form.FindName("tweakspanel")
        $tweakspanel.Children | ForEach-Object {
            $_.Visibility = [Windows.Visibility]::Visible

            # Foreach category section, show all items
            if ($_ -is [Windows.Controls.Border]) {
                $_.Visibility = [Windows.Visibility]::Visible

                # Find ItemsControl
                $dockPanel = $_.Child
                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                    if ($itemsControl) {
                        # Show items in the category
                        foreach ($item in $itemsControl.Items) {
                            if ($item -is [Windows.Controls.Label]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            } elseif ($item -is [Windows.Controls.DockPanel] -or
                                      $item -is [Windows.Controls.StackPanel]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            }
                        }
                    }
                }
            }
        }
        return
    }

    # Search for matching tweaks when search string is not null
    $tweakspanel = $sync.Form.FindName("tweakspanel")

    $tweakspanel.Children | ForEach-Object {
        $categoryBorder = $_
        $categoryVisible = $false

        if ($_ -is [Windows.Controls.Border]) {
            # Find the ItemsControl
            $dockPanel = $_.Child
            if ($dockPanel -is [Windows.Controls.DockPanel]) {
                $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                if ($itemsControl) {
                    $categoryLabel = $null

                    # Process all items in the ItemsControl
                    for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                        $item = $itemsControl.Items[$i]

                        if ($item -is [Windows.Controls.Label]) {
                            $categoryLabel = $item
                            $item.Visibility = [Windows.Visibility]::Collapsed
                        } elseif ($item -is [Windows.Controls.DockPanel]) {
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                            $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                            if ($label -and ($label.Content -like "*$SearchString*" -or $label.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        } elseif ($item -is [Windows.Controls.StackPanel]) {
                            # StackPanel which contain checkboxes or other elements
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                            if ($checkbox -and ($checkbox.Content -like "*$SearchString*" -or $checkbox.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        }
                    }
                }
            }

            # Set the visibility based on if any item matched
            $categoryBorder.Visibility = if ($categoryVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

        }
    }
}
function Get-LocalizedYesNo {
    <#
    .SYNOPSIS
    This function runs choice.exe and captures its output to extract yes no in a localized Windows

    .DESCRIPTION
    The function retrieves the output of the command 'cmd /c "choice <nul 2>nul"' and converts the default output for Yes and No
    in the localized format, such as "Yes=<first character>, No=<second character>".

    .EXAMPLE
    $yesNoArray = Get-LocalizedYesNo
    Write-Host "Yes=$($yesNoArray[0]), No=$($yesNoArray[1])"
    #>

    # Run choice and capture its options as output
    # The output shows the options for Yes and No as "[Y,N]?" in the (partially) localized format.
    # eg. English: [Y,N]?
    # Dutch: [Y,N]?
    # German: [J,N]?
    # French: [O,N]?
    # Spanish: [S,N]?
    # Italian: [S,N]?
    # Russian: [Y,N]?

    $line = cmd /c "choice <nul 2>nul"
    $charactersArray = @()
    $regexPattern = '([a-zA-Z])'
    $charactersArray = [regex]::Matches($line, $regexPattern) | ForEach-Object { $_.Groups[1].Value }

    Write-Debug "According to takeown.exe local Yes is $charactersArray[0]"
    # Return the array of characters
    return $charactersArray

  }
function Get-WinUtilInstallerProcess {
    <#

    .SYNOPSIS
        Checks if the given process is running

    .PARAMETER Process
        The process to check

    .OUTPUTS
        Boolean - True if the process is running

    #>

    param($Process)

    if ($Null -eq $Process) {
        return $false
    }
    if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}
function Get-WinUtilSelectedPackages
{
     <#
    .SYNOPSIS
        Sorts given packages based on installer preference and availability.

    .OUTPUTS
        Hashtable. Key = Package Manager, Value = ArrayList of packages to install
    #>
    param (
        [Parameter(Mandatory=$true)]
        $PackageList,
        [Parameter(Mandatory=$true)]
        [PackageManagers]$Preference
    )

    if ($PackageList.count -eq 1) {
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
    } else {
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
    }

    $packages = [System.Collections.Hashtable]::new()
    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages[[PackageManagers]::Winget] = $packagesWinget
    $packages[[PackageManagers]::Choco] = $packagesChoco

    Write-Debug "Checking packages using Preference '$($Preference)'"

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ($package.choco -eq "na") {
                    Write-Debug "$($package.content) has no Choco value."
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for Winget"
                } else {
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey"
                }
                break
            }
            "Winget" {
                if ($package.winget -eq "na") {
                    Write-Debug "$($package.content) has no Winget value."
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey"
                } else {
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for Winget"
                }
                break
            }
        }
    }

    return $packages
}
Function Get-WinUtilToggleStatus {
    <#

    .SYNOPSIS
        Pulls the registry keys for the given toggle switch and checks whether the toggle should be checked or unchecked

    .PARAMETER ToggleSwitch
        The name of the toggle to check

    .OUTPUTS
        Boolean to set the toggle's status to

    #>

    Param($ToggleSwitch)

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    try {
        if (($ToggleSwitchReg.path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
            if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                Write-Debug "HKU drive created successfully"
            } else {
                Write-Debug "Failed to create HKU drive"
            }
        }
    } catch {
        Write-Error "An error occurred regarding the HKU Drive: $_"
        return $false
    }

    if ($ToggleSwitchReg) {
        $count = 0

        foreach ($regentry in $ToggleSwitchReg) {
            try {
                if (!(Test-Path $regentry.Path)) {
                    New-Item -Path $regentry.Path -Force | Out-Null
                }
                $regstate = (Get-ItemProperty -path $regentry.Path).$($regentry.Name)
                if ($regstate -eq $regentry.Value) {
                    $count += 1
                    Write-Debug "$($regentry.Name) is true (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                } else {
                    Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                }
                if ($null -eq $regstate) {
                    switch ($regentry.DefaultState) {
                        "true" {
                            $regstate = $regentry.Value
                            $count += 1
                        }
                        "false" {
                            $regstate = $regentry.OriginalValue
                        }
                        default {
                            Write-Error "Entry for $($regentry.Name) does not exist and no DefaultState is defined."
                            $regstate = $regentry.OriginalValue
                        }
                    }
                }
            } catch {
                Write-Error "An unexpected error occurred: $_"
            }
        }

        if ($count -eq $ToggleSwitchReg.Count) {
            Write-Debug "$($ToggleSwitchReg.Name) is true (count: $count)"
            return $true
        } else {
            Write-Debug "$($ToggleSwitchReg.Name) is false (count: $count)"
            return $false
        }
    } else {
        return $false
    }
}
function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            } catch {
                <#I am here so errors don't get outputted for a couple variables that don't have the .GetType() attribute#>
            }
        }
        return $output
    }
    return $keys
}
function Get-WPFObjectName {
    <#
        .SYNOPSIS
            This is a helper function that generates an objectname with the prefix WPF that can be used as a Powershell Variable after compilation.
            To achieve this, all characters that are not a-z, A-Z or 0-9 are simply removed from the name.

        .PARAMETER type
            The type of object for which the name should be generated. (e.g. Label, Button, CheckBox...)

        .PARAMETER name
            The name or description to be used for the object. (invalid characters are removed)

        .OUTPUTS
            A string that can be used as a object/variable name in powershell.
            For example: WPFLabelMicrosoftTools

        .EXAMPLE
            Get-WPFObjectName -type Label -name "Microsoft Tools"
    #>

    param(
        [Parameter(Mandatory, position=0)]
        [string]$type,

        [Parameter(position=1)]
        [string]$name
    )

    $Output = $("WPF"+$type+$name) -replace '[^a-zA-Z0-9]', ''
    return $Output
}
function Hide-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Hides the busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall has finished.
    #>
    $sync.form.Dispatcher.Invoke([action]{
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Collapsed
        $sync.InstallAppAreaBorder.IsEnabled = $true
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 0
    })
}
    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

                Also creates an overlay with a progress bar and text to indicate that an install or uninstall is in progress

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        $sync.InstallAppAreaBorder = $Border

        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $sync.InstallAppAreaScrollViewer = $scrollViewer
        $Border.Child = $scrollViewer

        # Initialize the Blur Effect for the ScrollViewer, which will be used to indicate that an install/uninstall is in progress
        $blurEffect = New-Object Windows.Media.Effects.BlurEffect
        $blurEffect.Radius = 0
        $scrollViewer.Effect = $blurEffect

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        $overlay = New-Object Windows.Controls.Border
        $overlay.CornerRadius = New-Object Windows.CornerRadius(10)
        $overlay.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallOverlayBackgroundColor")
        $overlay.Visibility = [Windows.Visibility]::Collapsed

        # Also add the overlay to the target Grid on top of the App Area
        $targetGrid.Children.Add($overlay) | Out-Null
        $sync.InstallAppAreaOverlay = $overlay

        $overlayText = New-Object Windows.Controls.TextBlock
        $overlayText.Text = "Installing apps..."
        $overlayText.HorizontalAlignment = 'Center'
        $overlayText.VerticalAlignment = 'Center'
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        $overlayText.Background = "Transparent"
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "HeaderFontSize")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontFamilyProperty, "MainFontFamily")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontWeightProperty, "MainFontWeight")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::MarginProperty, "MainMargin")
        $sync.InstallAppAreaOverlayText = $overlayText

        $progressbar = New-Object Windows.Controls.ProgressBar
        $progressbar.Name = "ProgressBar"
        $progressbar.Width = 250
        $progressbar.Height = 50
        $sync.ProgressBar = $progressbar

        # Add a TextBlock overlay for the progress bar text
        $progressBarTextBlock = New-Object Windows.Controls.TextBlock
        $progressBarTextBlock.Name = "progressBarTextBlock"
        $progressBarTextBlock.FontWeight = [Windows.FontWeights]::Bold
        $progressBarTextBlock.FontSize = 16
        $progressBarTextBlock.Width = $progressbar.Width
        $progressBarTextBlock.Height = $progressbar.Height
        $progressBarTextBlock.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ProgressBarTextColor")
        $progressBarTextBlock.TextTrimming = "CharacterEllipsis"
        $progressBarTextBlock.Background = "Transparent"
        $sync.progressBarTextBlock = $progressBarTextBlock

        # Create a Grid to overlay the text on the progress bar
        $progressGrid = New-Object Windows.Controls.Grid
        $progressGrid.Width = $progressbar.Width
        $progressGrid.Height = $progressbar.Height
        $progressGrid.Margin = "0,10,0,10"
        $progressGrid.Children.Add($progressbar) | Out-Null
        $progressGrid.Children.Add($progressBarTextBlock) | Out-Null

        $overlayStackPanel = New-Object Windows.Controls.StackPanel
        $overlayStackPanel.Orientation = "Vertical"
        $overlayStackPanel.HorizontalAlignment = 'Center'
        $overlayStackPanel.VerticalAlignment = 'Center'
        $overlayStackPanel.Children.Add($overlayText) | Out-Null
        $overlayStackPanel.Children.Add($progressGrid) | Out-Null

        $overlay.Child = $overlayStackPanel

        return $itemsControl
    }
function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $Apps.$appKey.description
        $border.Add_MouseLeftButtonUp({
            $childCheckbox = ($this.Child | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $Apps.$appKey.content

        # Change color to Green if FOSS
        if ($Apps.$appKey.foss -eq $true) {
            $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "FOSSColor")
            $appName.FontWeight = "Bold"
        }

        # Add the name to the Checkbox
        $checkBox.Content = $appName

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)

        $border.Child = $checkBox
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }
function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($sender, $e)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $sender.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $sender.Content = $sender.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $sender.Content = $sender.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            # Add apps to the wrap panel
            $appsByCategory[$category] | Sort-Object | ForEach-Object {
                $sync.$_ = $(Initialize-InstallAppEntry -TargetElement $wrapPanel -AppKey $_)
            }
        }
    }
function Install-WinUtilChoco {

    <#

    .SYNOPSIS
        Installs Chocolatey if it is not already installed

    #>
    if ((Test-WinUtilPackageManager -choco) -eq "installed") {
        return
    }

    Write-Host "Chocolatey is not installed, installing now."
    Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
}
function Install-WinUtilProgramChoco {
    <#
    .SYNOPSIS
    Manages the installation or uninstallation of a list of Chocolatey packages.

    .PARAMETER Programs
    A string array containing the programs to be installed or uninstalled.

    .PARAMETER Action
    Specifies the action to perform: "Install" or "Uninstall". The default value is "Install".

    .DESCRIPTION
    This function processes a list of programs to be managed using Chocolatey. Depending on the specified action, it either installs or uninstalls each program in the list, updating the taskbar progress accordingly. After all operations are completed, temporary output files are cleaned up.

    .EXAMPLE
    Install-WinUtilProgramChoco -Programs @("7zip","chrome") -Action "Uninstall"
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Programs,

        [Parameter(Position = 1)]
        [String]$Action = "Install"
    )

    function Initialize-OutputFile {
        <#
        .SYNOPSIS
        Initializes an output file by removing any existing file and creating a new, empty file at the specified path.

        .PARAMETER filePath
        The full path to the file to be initialized.

        .DESCRIPTION
        This function ensures that the specified file is reset by removing any existing file at the provided path and then creating a new, empty file. It is useful when preparing a log or output file for subsequent operations.

        .EXAMPLE
        Initialize-OutputFile -filePath "C:\temp\output.txt"
        #>

        param ($filePath)
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $filePath | Out-Null
    }

    function Invoke-ChocoCommand {
        <#
        .SYNOPSIS
        Executes a Chocolatey command with the specified arguments and returns the exit code.

        .PARAMETER arguments
        The arguments to be passed to the Chocolatey command.

        .DESCRIPTION
        This function runs a specified Chocolatey command by passing the provided arguments to the `choco` executable. It waits for the process to complete and then returns the exit code, allowing the caller to determine success or failure based on the exit code.

        .RETURNS
        [int]
        The exit code of the Chocolatey command.

        .EXAMPLE
        $exitCode = Invoke-ChocoCommand -arguments "install 7zip -y"
        #>

        param ($arguments)
        return (Start-Process -FilePath "choco" -ArgumentList $arguments -Wait -PassThru).ExitCode
    }

    function Test-UpgradeNeeded {
        <#
        .SYNOPSIS
        Checks if an upgrade is needed for a Chocolatey package based on the content of a log file.

        .PARAMETER filePath
        The path to the log file that contains the output of a Chocolatey install command.

        .DESCRIPTION
        This function reads the specified log file and checks for keywords that indicate whether an upgrade is needed. It returns a boolean value indicating whether the terms "reinstall" or "already installed" are present, which suggests that the package might need an upgrade.

        .RETURNS
        [bool]
        True if the log file indicates that an upgrade is needed; otherwise, false.

        .EXAMPLE
        $isUpgradeNeeded = Test-UpgradeNeeded -filePath "C:\temp\install-output.txt"
        #>

        param ($filePath)
        return Get-Content -Path $filePath | Select-String -Pattern "reinstall|already installed" -Quiet
    }

    function Update-TaskbarProgress {
        <#
        .SYNOPSIS
        Updates the taskbar progress based on the current installation progress.

        .PARAMETER currentIndex
        The current index of the program being installed or uninstalled.

        .PARAMETER totalPrograms
        The total number of programs to be installed or uninstalled.

        .DESCRIPTION
        This function calculates the progress of the installation or uninstallation process and updates the taskbar accordingly. The taskbar is set to "Normal" if all programs have been processed, otherwise, it is set to "Error" as a placeholder.

        .EXAMPLE
        Update-TaskbarProgress -currentIndex 3 -totalPrograms 10
        #>

        param (
            [int]$currentIndex,
            [int]$totalPrograms
        )
        $progressState = if ($currentIndex -eq $totalPrograms) { "Normal" } else { "Error" }
        $sync.form.Dispatcher.Invoke([action] { Set-WinUtilTaskbaritem -state $progressState -value ($currentIndex / $totalPrograms) })
    }

    function Install-ChocoPackage {
        <#
        .SYNOPSIS
        Installs a Chocolatey package and optionally upgrades it if needed.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be installed.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be installed.

        .DESCRIPTION
        This function installs a Chocolatey package by running the `choco install` command. If the installation output indicates that an upgrade might be needed, the function will attempt to upgrade the package. The taskbar progress is updated after each package is processed.

        .EXAMPLE
        Install-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $installOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt"
        Initialize-OutputFile $installOutputFile

        Write-Host "Starting installation of $Program with Chocolatey."

        try {
            $installStatusCode = Invoke-ChocoCommand "install $Program -y --log-file $installOutputFile"
            if ($installStatusCode -eq 0) {

                if (Test-UpgradeNeeded $installOutputFile) {
                    $upgradeStatusCode = Invoke-ChocoCommand "upgrade $Program -y"
                    Write-Host "$Program was" $(if ($upgradeStatusCode -eq 0) { "upgraded successfully." } else { "not upgraded." })
                }
                else {
                    Write-Host "$Program installed successfully."
                }
            }
            else {
                Write-Host "Failed to install $Program."
            }
        }
        catch {
            Write-Host "Failed to install $Program due to an error: $_"
        }
        finally {
            Update-TaskbarProgress $currentIndex $totalPrograms
        }
    }

    function Uninstall-ChocoPackage {
        <#
        .SYNOPSIS
        Uninstalls a Chocolatey package and any related metapackages.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be uninstalled.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be uninstalled.

        .DESCRIPTION
        This function uninstalls a Chocolatey package and any related metapackages (e.g., .install or .portable variants). It updates the taskbar progress after processing each package.

        .EXAMPLE
        Uninstall-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $uninstallOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt"
        Initialize-OutputFile $uninstallOutputFile

        Write-Host "Searching for metapackages of $Program (.install or .portable)"
        $chocoPackages = ((choco list | Select-String -Pattern "$Program(\.install|\.portable)?").Matches.Value) -join " "
        if ($chocoPackages) {
            Write-Host "Starting uninstallation of $chocoPackages with Chocolatey."
            try {
                $uninstallStatusCode = Invoke-ChocoCommand "uninstall $chocoPackages -y"
                Write-Host "$Program" $(if ($uninstallStatusCode -eq 0) { "uninstalled successfully." } else { "failed to uninstall." })
            }
            catch {
                Write-Host "Failed to uninstall $Program due to an error: $_"
            }
            finally {
                Update-TaskbarProgress $currentIndex $totalPrograms
            }
        }
        else {
            Write-Host "$Program is not installed."
        }
    }

    $totalPrograms = $Programs.Count
    if ($totalPrograms -le 0) {
        throw "Parameter 'Programs' must have at least one item."
    }

    Write-Host "==========================================="
    Write-Host "--   Configuring Chocolatey packages   ---"
    Write-Host "==========================================="

    for ($currentIndex = 0; $currentIndex -lt $totalPrograms; $currentIndex++) {
        $Program = $Programs[$currentIndex]
        Set-WinUtilProgressBar -label "$Action $($Program)" -percent ($currentIndex / $totalPrograms * 100)
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($currentIndex / $totalPrograms)})

        switch ($Action) {
            "Install" {
                Install-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            "Uninstall" {
                Uninstall-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            default {
                throw "Invalid action parameter value: '$Action'."
            }
        }
    }
    Set-WinUtilProgressBar -label "$($Action)ation done" -percent 100
    # Cleanup Output Files
    $outputFiles = @("$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt", "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt")
    foreach ($filePath in $outputFiles) {
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    }
}

Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
    Runs the designated action on the provided programs using Winget

    .PARAMETER Programs
    A list of programs to process

    .PARAMETER action
    The action to perform on the programs, can be either 'Install' or 'Uninstall'

    .NOTES
    The triple quotes are required any time you need a " in a normal script block.
    The winget Return codes are documented here: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-actionr/winget/returnCodes.md
    #>

    param(
        [Parameter(Mandatory, Position=0)]$Programs,

        [Parameter(Mandatory, Position=1)]
        [ValidateSet("Install", "Uninstall")]
        [String]$Action
    )

    Function Invoke-Winget {
    <#
    .SYNOPSIS
    Invokes the winget.exe with the provided arguments and return the exit code

    .PARAMETER wingetId
    The Id of the Program that Winget should Install/Uninstall

    .NOTES
    Invoke Winget uses the public variable $Action defined outside the function to determine if a Program should be installed or removed
    #>
        param (
            [string]$wingetId
        )

        $commonArguments = "--id $wingetId --silent"
        $arguments = if ($Action -eq "Install") {
            "install $commonArguments --accept-source-agreements --accept-package-agreements --source winget"
        } else {
            "uninstall $commonArguments --source winget"
        }

        $processParams = @{
            FilePath = "winget"
            ArgumentList = $arguments
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }

        return (Start-Process @processParams).ExitCode
    }

    Function Invoke-Install {
    <#
    .SYNOPSIS
    Contains the Install Logic and return code handling from winget

    .PARAMETER Program
    The Winget ID of the Program that should be installed
    #>
        param (
            [string]$Program
        )
        $status = Invoke-Winget -wingetId $Program
        if ($status -eq 0) {
            Write-Host "$($Program) installed successfully."
            return $true
        } elseif ($status -eq -1978335189) {
            Write-Host "$($Program) No applicable update found"
            return $true
        }

        Write-Host "Failed to install $($Program)."
        return $false
    }

    Function Invoke-Uninstall {
        <#
        .SYNOPSIS
        Contains the Uninstall Logic and return code handling from winget

        .PARAMETER Program
        The Winget ID of the Program that should be uninstalled
        #>
        param (
            [string]$Program
        )

        try {
            $status = Invoke-Winget -wingetId $Program
            if ($status -eq 0) {
                Write-Host "$($Program) uninstalled successfully."
                return $true
            } else {
                Write-Host "Failed to uninstall $($Program)."
                return $false
            }
        } catch {
            Write-Host "Failed to uninstall $($Program) due to an error: $_"
            return $false
        }
    }

    $count = $Programs.Count
    $failedPackages = @()

    Write-Host "==========================================="
    Write-Host "--    Configuring winget packages       ---"
    Write-Host "==========================================="

    for ($i = 0; $i -lt $count; $i++) {
        $Program = $Programs[$i]
        $result = $false
        Set-WinUtilProgressBar -label "$Action $($Program)" -percent ($i / $count * 100)
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($i / $count)})

        $result = switch ($Action) {
            "Install" {Invoke-Install -Program $Program}
            "Uninstall" {Invoke-Uninstall -Program $Program}
            default {throw "[Install-WinUtilProgramWinget] Invalid action: $Action"}
        }

        if (-not $result) {
            $failedPackages += $Program
        }
    }

    Set-WinUtilProgressBar -label "$($Action)ation done" -percent 100
    return $failedPackages
}
function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs Winget if not already installed.

    .DESCRIPTION
        installs winget if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "Winget is not Installed. Installing." -ForegroundColor Red
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Install-PackageProvider -Name NuGet -Force
    Install-Module Microsoft.WinGet.Client -Force
    Import-Module Microsoft.WinGet.Client
    Repair-WinGetPackageManager
}
function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoBase64 = "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"

          $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
          $bitmap.BeginInit()
          $bitmap.StreamSource = [System.IO.MemoryStream]::new([Convert]::FromBase64String($LogoBase64))
          $bitmap.EndInit()
          
          $image = New-Object Windows.Controls.Image
          $image.Source = $bitmap
          $image.Width = $Size
          $image.Height = $Size
          
          $canvas.Children.Add($image) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}
Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $Sync.InstalledPrograms = winget list -s winget | Select-Object -skip 3 | ConvertFrom-String -PropertyNames "Name", "Id", "Version", "Available" -Delimiter '\s{2,}'
        [Console]::OutputEncoding = $originalEncoding

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).winget -split ";")

            if ($dependencies[-1] -in $sync.InstalledPrograms.Id) {
                Write-Output $psitem.name
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}
        $ScheduledTasks = Get-ScheduledTask

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            #WPFEssTweaksTele
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $scheduledtaskKeys = $entry.scheduledtask
            $serviceKeys = $entry.service
            $appxKeys = $entry.appx
            $invokeScript = $entry.InvokeScript
            $entryType = $entry.Type

            if ($registryKeys -or $scheduledtaskKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $scheduledtaskKeys) {
                    Foreach ($tweak in $tweaks) {
                        $task = $ScheduledTasks | Where-Object {$($psitem.TaskPath + $psitem.TaskName) -like "\$($tweak.name)"}

                        if ($task) {
                            $actualValue = $task.State
                            $expectedValue = $tweak.State
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            } else {
                if ($invokeScript -or $appxKeys) {
                    Write-Debug "Skipping $Config in Get Installed: no detectable registry, scheduled task, or service state."
                }
            }
        }
    }
}
function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -DebugPreference $DebugPreference -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}
function Invoke-WinUtilFeatureInstall {
    <#

    .SYNOPSIS
        Converts all the values from the tweaks.json and routes them to the appropriate function

    #>

    param(
        $CheckBox
    )

    $x = 0

    $CheckBox | ForEach-Object {
        if($sync.configs.feature.$psitem.feature) {
            Foreach( $feature in $sync.configs.feature.$psitem.feature ) {
                try {
                    Write-Host "Installing $feature"
                    Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
                } catch {
                    if ($psitem.Exception.Message -like "*requires elevation*") {
                        Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" })
                    } else {

                        Write-Warning "Unable to Install $feature due to unhandled exception"
                        Write-Warning $psitem.Exception.StackTrace
                    }
                }
            }
        }
        if($sync.configs.feature.$psitem.InvokeScript) {
            Foreach( $script in $sync.configs.feature.$psitem.InvokeScript ) {
                try {
                    $Scriptblock = [scriptblock]::Create($script)

                    Write-Host "Running Script for $psitem"
                    Invoke-Command $scriptblock -ErrorAction stop
                } catch {
                    if ($psitem.Exception.Message -like "*requires elevation*") {
                        Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" })
                    } else {
                        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" })
                        Write-Warning "Unable to Install $feature due to unhandled exception"
                        Write-Warning $psitem.Exception.StackTrace
                    }
                }
            }
        }
        $X++
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($x/$CheckBox.Count) })
    }
}
function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
                Write-Debug "Scaled $resourceName from original $originalValue to $newValue (factor: $ScaleFactor)"
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }

    Write-Debug "Font scaling applied with factor: $ScaleFactor"
}


function Invoke-WinUtilGPU {
    $gpuInfo = Get-CimInstance Win32_VideoController

    # GPUs to blacklist from using Demanding Theming
    $lowPowerGPUs = (
        "*NVIDIA GeForce*M*",
        "*NVIDIA GeForce*Laptop*",
        "*NVIDIA GeForce*GT*",
        "*AMD Radeon(TM)*",
        "*Intel(R) HD Graphics*",
        "*UHD*"

    )

    foreach ($gpu in $gpuInfo) {
        foreach ($gpuPattern in $lowPowerGPUs) {
            if ($gpu.Name -like $gpuPattern) {
                return $false
            }
        }
    }
    return $true
}
function Invoke-WinUtilInstallPSProfile {

    if (Test-Path $Profile) {
        Rename-Item $Profile -NewName ($Profile + '.bak')
    }

    Start-Process pwsh -ArgumentList '-Command "irm https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1 | iex"'
}
function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $name"
        Invoke-Command $scriptblock -ErrorAction Stop
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }

}
Function Invoke-WinUtilSponsors {
    <#
    .SYNOPSIS
        Lists Sponsors from ChrisTitusTech
    .DESCRIPTION
        Lists Sponsors from ChrisTitusTech
    .EXAMPLE
        Invoke-WinUtilSponsors
    .NOTES
        This function is used to list sponsors from ChrisTitusTech
    #>
    try {
        # Define the URL and headers
        # Return the sponsors
        return "No Sponsors Yet"
    } catch {
        Write-Error "An error occurred while fetching or processing the sponsors: $_"
        return $null
    }
}
function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Get the latest version of OpenSSH Server
    $FeatureName = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" }

    # Install the OpenSSH Server feature if not already installed
    if ($FeatureName.State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server"
        Add-WindowsCapability -Online -Name $FeatureName.Name
    }

    # Sets up the OpenSSH Server service
    Write-Host "Starting the services"
    Start-Service -Name sshd
    Set-Service -Name sshd -StartupType Automatic

    # Sets up the ssh-agent service
    Start-Service 'ssh-agent'
    Set-Service -Name 'ssh-agent' -StartupType 'Automatic'

    # Confirm the required services are running
    $SSHDaemonService = Get-Service -Name sshd
    $SSHAgentService = Get-Service -Name 'ssh-agent'

    if ($SSHDaemonService.Status -eq 'Running') {
        Write-Host "OpenSSH Server is running."
    } else {
        try {
            Write-Host "OpenSSH Server is not running. Attempting to restart..."
            Restart-Service -Name sshd -Force
            Write-Host "OpenSSH Server has been restarted successfully."
        } catch {
            Write-Host "Failed to restart OpenSSH Server: $_"
        }
    }
    if ($SSHAgentService.Status -eq 'Running') {
        Write-Host "ssh-agent is running."
    } else {
        try {
            Write-Host "ssh-agent is not running. Attempting to restart..."
            Restart-Service -Name sshd -Force
            Write-Host "ssh-agent has been restarted successfully."
        } catch {
            Write-Host "Failed to restart ssh-agent : $_"
        }
    }

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    $firewallRule = (Get-NetFirewallRule -Name 'sshd').Enabled
    if ($firewallRule) {
        Write-Host "Firewall rule for OpenSSH Server (sshd) already exists."
    } else {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$env:HOMEDRIVE\$env:HOMEPATH\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    } else {
        Write-Host "authorized_keys file already exists at $authorizedKeysPath."
    }
    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config "
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}
function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .PARAMETER init
        A switch parameter. If set to $true, the function initializes the theme based on the system?s current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.

    .EXAMPLE
        Invoke-WinutilThemeChange -init
        # Initializes the theme based on the system's dark mode and applies the shared theme.
    #>
    param (
        [switch]$init = $false,
        [string]$theme
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($_ in $themeProperties) {
            # Apply properties that deal with colors
            if ($_.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($_.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($_.Name)" -Value $_.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($_.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($_.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($_.Name -like "*Thickness*") -or ($_.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($_.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Double"
            }
        }
    }

    $LightPreferencePath = "$winutildir\LightTheme.ini"
    $DarkPreferencePath = "$winutildir\DarkTheme.ini"

    if ($init) {
        Set-WinutilTheme -currentTheme "shared"
        if (Test-Path $LightPreferencePath) {
            $theme = "Light"
        }
        elseif (Test-Path $DarkPreferencePath) {
            $theme = "Dark"
        }
        else {
            $theme = "Auto"
        }
    }

    switch ($theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                Set-WinutilTheme  -currentTheme "Dark"
            }
            else{
                Set-WinutilTheme  -currentTheme "Light"
            }


            $themeButtonIcon = [char]0xF08C
            Remove-Item $LightPreferencePath -Force -ErrorAction SilentlyContinue
            Remove-Item $DarkPreferencePath -Force -ErrorAction SilentlyContinue
        }
        "Dark" {
            Set-WinutilTheme  -currentTheme $theme
            $themeButtonIcon = [char]0xE708
            $null = New-Item $DarkPreferencePath -Force
            Remove-Item $LightPreferencePath -Force -ErrorAction SilentlyContinue
           }
        "Light" {
            Set-WinutilTheme  -currentTheme $theme
            $themeButtonIcon = [char]0xE706
            $null = New-Item $LightPreferencePath -Force
            Remove-Item $DarkPreferencePath -Force -ErrorAction SilentlyContinue
        }
    }

    # Set FOSS Highlight Color
    $fossEnabled = $true
    if ($sync.WPFToggleFOSSHighlight) {
        $fossEnabled = $sync.WPFToggleFOSSHighlight.IsChecked
    }

    if ($fossEnabled) {
         $sync.Form.Resources["FOSSColor"] = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(76, 175, 80)) # #4CAF50
    } else {
         $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}
function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    Write-Debug "Tweaks: $($CheckBox)"
    if($undo) {
        $Values = @{
            Registry = "OriginalValue"
            ScheduledTask = "OriginalState"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            ScheduledTask = "State"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if($sync.configs.tweaks.$CheckBox.ScheduledTask) {
        $sync.configs.tweaks.$CheckBox.ScheduledTask | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.ScheduledTask))"
            Set-WinUtilScheduledTask -Name $psitem.Name -State $psitem.$($values.ScheduledTask)
        }
    }
    if($sync.configs.tweaks.$CheckBox.service) {
        Write-Debug "KeepServiceStartup is $KeepServiceStartup"
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        Write-Debug "Service $($service.Name) was changed in the past to $($service.StartType.ToString()) from it's original type of $($psitem.$($values.OriginalService)), will not change it to $($psitem.$($values.service))"
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found"
                }
            }

            if($changeservice) {
                Write-Debug "$($psitem.Name) and state is $($psitem.$($values.service))"
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.registry))"
            if (($psitem.Path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
                if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                    Write-Debug "HKU drive created successfully"
                } else {
                    Write-Debug "Failed to create HKU drive"
                }
            }
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            Write-Debug "$($psitem) and state is $($psitem.$($values.ScriptType))"
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if(!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Write-Debug "UNDO $($psitem.Name)"
                Remove-WinUtilAPPX -Name $psitem
            }
        }

    }
}
function Invoke-WinUtilUninstallPSProfile {
    if (Test-Path ($Profile + '.bak')) {
        Remove-Item $Profile
        Rename-Item ($Profile + '.bak') -NewName $Profile
    }
    else {
        Remove-Item $Profile
    }

    Write-Host "Successfully uninstalled CTT Powershell Profile" -ForegroundColor Green
}
function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Get-AppxPackage $Name -AllUsers | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $Name | Remove-AppxProvisionedPackage -Online
}
function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )

    $CheckBoxesToCheck = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures
    $CheckBoxes = ($sync.GetEnumerator()).where{ $_.Value -is [System.Windows.Controls.CheckBox] -and $_.Name -notlike "WPFToggle*" -and $_.Name -like "$checkboxfilterpattern"}
    Write-Debug "Getting checkboxes to set, number of checkboxes: $($CheckBoxes.Count)"

    if ($CheckBoxesToCheck -ne "") {
        $debugMsg = "CheckBoxes to Check are: "
        $CheckBoxesToCheck | ForEach-Object { $debugMsg += "$_, " }
        $debugMsg = $debugMsg -replace (',\s*$', '')
        Write-Debug "$debugMsg"
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key
        if (-not $CheckBoxesToCheck) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
            Write-Debug "$checkboxName is checked"
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
            Write-Debug "$checkboxName is not checked"
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states
        $importedToggles = $sync.selectedToggles
        $allToggles = $sync.GetEnumerator() | Where-Object { $_.Key -like "WPFToggle*" -and $_.Value -is [System.Windows.Controls.CheckBox] }
        foreach ($toggle in $allToggles) {
            if ($importedToggles -contains $toggle.Key) {
                $sync[$toggle.Key].IsChecked = $true
                Write-Debug "Restoring toggle: $($toggle.Key) = checked"
            } else {
                $sync[$toggle.Key].IsChecked = $false
                Write-Debug "Restoring toggle: $($toggle.Key) = unchecked"
            }
        }
    }
}
function Set-PackageManagerPreference {
    <#
    .SYNOPSIS
        Sets the currently selected package manager to global "ManagerPreference" in sync.
        Also persists preference across Winutil restarts via preference.ini.

        Reads from preference.ini if no argument sent.

    .PARAMETER preferredPackageManager
        The PackageManager that was selected.
    #>
    param(
        [Parameter(Position=0, Mandatory=$false)]
        [PackageManagers]$preferredPackageManager
    )

    $preferencePath = "$winutildir\preferences.ini"
    $oldChocoPath = "$winutildir\preferChocolatey.ini"

    #Try loading from file if no argument given.
    if ($null -eq $preferredPackageManager) {
        # Backwards compat for preferChocolatey.ini
        if (Test-Path -Path $oldChocoPath) {
            $preferredPackageManager = [PackageManagers]::Choco
            Remove-Item -Path $oldChocoPath
        }
        elseif (Test-Path -Path $preferencePath) {
            $potential = Get-Content -Path $preferencePath -TotalCount 1
            $preferredPackageManager = [PackageManagers]$potential
        }
        else {
            Write-Debug "Creating new preference file, defaulting to winget."
            $preferredPackageManager = [PackageManagers]::Winget
        }
    }

    $sync["ManagerPreference"] = [PackageManagers]::$preferredPackageManager
    Write-Debug "Manager Preference changed to '$($sync["ManagerPreference"])'"


    # Write preference to file to persist across restarts.
    Out-File -FilePath $preferencePath -InputObject $sync["ManagerPreference"]
}
function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)
    if($DNSProvider -eq "Default") {return}
    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces"
        Write-Host $($Adapters | Out-String)

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary)", "$($sync.configs.dns.$DNSProvider.Secondary)")
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary6)", "$($sync.configs.dns.$DNSProvider.Secondary6)")
            }
        }
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilProgressbar{
    <#
    .SYNOPSIS
        This function is used to Update the Progress Bar displayed in the winutil GUI.
        It will be automatically hidden if the user clicks something and no process is running
    .PARAMETER Label
        The Text to be overlaid onto the Progress Bar
    .PARAMETER PERCENT
        The percentage of the Progress Bar that should be filled (0-100)
    #>
    param(
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    $sync.form.Dispatcher.Invoke([action]{$sync.progressBarTextBlock.Text = $label})
    $sync.form.Dispatcher.Invoke([action]{$sync.progressBarTextBlock.ToolTip = $label})
    if ($percent -lt 5 ) {
        $percent = 5 # Ensure the progress bar is not empty, as it looks weird
    }
    $sync.form.Dispatcher.Invoke([action]{ $sync.ProgressBar.Value = $percent})

}
function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found, Creating..."
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilScheduledTask {
    <#

    .SYNOPSIS
        Enables/Disables the provided Scheduled Task

    .PARAMETER Name
        The path to the Scheduled Task

    .PARAMETER State
        The State to set the Task to

    .EXAMPLE
        Set-WinUtilScheduledTask -Name "Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -State "Disabled"

    #>
    param (
        $Name,
        $State
    )

    try {
        if($State -eq "Disabled") {
            Write-Host "Disabling Scheduled Task $Name"
            Disable-ScheduledTask -TaskName $Name -ErrorAction Stop
        }
        if($State -eq "Enabled") {
            Write-Host "Enabling Scheduled Task $Name"
            Enable-ScheduledTask -TaskName $Name -ErrorAction Stop
        }
    } catch [System.Exception] {
        if($psitem.Exception.Message -like "*The system cannot find the file specified*") {
            Write-Warning "Scheduled Task $name was not Found"
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception"
            Write-Warning $psitem.Exception.Message
        }
    } catch {
        Write-Warning "Unable to run script for $name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
    } catch [System.ServiceProcess.ServiceNotFoundException] {
        Write-Warning "Service $Name was not found"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception"
        Write-Warning $_.Exception.Message
    }

}
function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}
function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "Winutil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($sender, $args)
            Start-Process $sender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($sender, $args)
            $sender.Foreground = $LinkHoverForegroundColor
            $sender.FontSize = ($FontSize + ($FontSize / 4))
            $sender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($sender, $args)
            $sender.Foreground = $LinkForegroundColor
            $sender.FontSize = $FontSize
            $sender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}
function Show-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Displays a busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall is in progress.
        Dynamically updates the size of the overlay based on the app area on each invocation.
    .PARAMETER text
        The text to display in the busy overlay. Defaults to "Installing apps...".
    #>
    param (
        $text = "Installing apps..."
    )
    $sync.form.Dispatcher.Invoke([action]{
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Visible
        $sync.InstallAppAreaOverlay.Width = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlay.Height = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlayText.Text = $text
        $sync.InstallAppAreaBorder.IsEnabled = $false
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 5
        })
    }
function Test-WinUtilInternetConnection {
    <#
    .SYNOPSIS
        Tests if the computer has internet connectivity
    .OUTPUTS
        Boolean - True if connected, False if offline
    #>
    try {
        # Test multiple reliable endpoints
        $testSites = @(
            "8.8.8.8",           # Google DNS
            "1.1.1.1",           # Cloudflare DNS
            "208.67.222.222"     # OpenDNS
        )

        foreach ($site in $testSites) {
            if (Test-Connection -ComputerName $site -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                return $true
            }
        }
        return $false
    }
    catch {
        return $false
    }
}
function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if Winget and/or Choco are installed

    .PARAMETER winget
        Check if Winget is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        Winget is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      Winget is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}
Function Update-WinUtilProgramWinget {

    <#

    .SYNOPSIS
        This will update all programs using Winget

    #>

    [ScriptBlock]$wingetinstall = {

        $host.ui.RawUI.WindowTitle = """Winget Install"""

        Start-Transcript "$logdir\winget-update_$dateTime.log" -Append
        winget upgrade --all --accept-source-agreements --accept-package-agreements --scope=machine --silent

    }

    $global:WinGetInstall = Start-Process -Verb runas powershell -ArgumentList "-command invoke-command -scriptblock {$wingetinstall} -argumentlist '$($ProgramsToInstall -join ",")'" -PassThru

}
function Update-WinUtilSelections {
    <#

    .SYNOPSIS
        Updates the $sync.selected variables with a given preset.

    .PARAMETER flatJson
        The flattened json list of $sync values to select.
    #>

    param (
        $flatJson
    )

    Write-Debug "JSON to import: $($flatJson)"

    foreach ($cbkey in $flatJson) {
        $group = if ($cbkey.StartsWith("WPFInstall")) { "Install" }
                    elseif ($cbkey.StartsWith("WPFTweaks")) { "Tweaks" }
                    elseif ($cbkey.StartsWith("WPFToggle")) { "Toggle" }
                    elseif ($cbkey.StartsWith("WPFFeature")) { "Feature" }
                    else { "na" }

        switch ($group) {
            "Install" {
                if (!$sync.selectedApps.Contains($cbkey)) {
                    $sync.selectedApps.Add($cbkey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[pscustomobject]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            "Tweaks" {
                if (!$sync.selectedTweaks.Contains($cbkey)) {
                    $sync.selectedTweaks.Add($cbkey)
                }
            }
            "Toggle" {
                if (!$sync.selectedToggles.Contains($cbkey)) {
                    $sync.selectedToggles.Add($cbkey)
                }
            }
            "Feature" {
                if (!$sync.selectedFeatures.Contains($cbkey)) {
                    $sync.selectedFeatures.Add($cbkey)
                }
            }
            default {
                Write-Host "Unknown group for checkbox: $($cbkey)"
            }
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
}
function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}

function Invoke-WinUtilRemoveEdge {
  Write-Host "Unlocking The Offical Edge Uninstaller And Removing Microsoft Edge..."

  $Path = (Get-ChildItem "C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe")[0].FullName
  New-Item "C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
  Start-Process $Path -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile'
}
function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning) {
        Set-WinUtilProgressBar  -label "" -percent 0
    }

    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -State "Enable"}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance -State "Disable"}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFFeatureInstall" {Invoke-WPFFeatureInstall}
        "WPFPanelDISM" {Invoke-WPFSystemRepair}
        "WPFPanelAutologin" {Invoke-WPFPanelAutologin}
        "WPFPanelComputer" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelControl" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelNetwork" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelPower" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelPrinter" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelRegion" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelRestore" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelSound" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelSystem" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelTimedate" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelUser" {Invoke-WPFControlPanel -Panel $button}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFFixesUpdate" {Invoke-WPFFixesUpdate}
        "WPFFixesWinget" {Invoke-WPFFixesWinget}
        "WPFRunAdobeCCCleanerTool" {Invoke-WPFRunAdobeCCCleanerTool}
        "WPFFixesNetwork" {Invoke-WPFFixesNetwork}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFWinUtilShortcut" {Invoke-WPFShortcut -ShortcutToAdd "WinUtil" -RunAsAdmin $true}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFCloseButton" {Invoke-WPFCloseButton}
        "WPFWinUtilInstallPSProfile" {Invoke-WinUtilInstallPSProfile}
        "WPFWinUtilUninstallPSProfile" {Invoke-WinUtilUninstallPSProfile}
        "WPFWinUtilSSHServer" {Invoke-WPFSSHServer}
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
        "WPFToggleFOSSHighlight" {
            if ($sync.WPFToggleFOSSHighlight.IsChecked) {
                 $sync.Form.Resources["FOSSColor"] = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(76, 175, 80)) # #4CAF50
            } else {
                 $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
            }
        }
    }
}
function Invoke-WPFCloseButton {

    <#

    .SYNOPSIS
        Close application

    .PARAMETER Button
    #>
    $sync["Form"].Close()
    Write-Host "Bye bye!"
}
function Invoke-WPFControlPanel {
    <#

    .SYNOPSIS
        Opens the requested legacy panel

    .PARAMETER Panel
        The panel to open

    #>
    param($Panel)

    switch ($Panel) {
        "WPFPanelControl" {control}
        "WPFPanelComputer" {compmgmt.msc}
        "WPFPanelNetwork" {ncpa.cpl}
        "WPFPanelPower"   {powercfg.cpl}
        "WPFPanelPrinter" {Start-Process "shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}"}
        "WPFPanelRegion"  {intl.cpl}
        "WPFPanelRestore"  {rstrui.exe}
        "WPFPanelSound"   {mmsys.cpl}
        "WPFPanelSystem"  {sysdm.cpl}
        "WPFPanelTimedate" {timedate.cpl}
        "WPFPanelUser"    {control userpasswords2}
    }
}
function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $Features = $sync.selectedFeatures

    Invoke-WPFRunspace -ArgumentList $Features -DebugPreference $DebugPreference -ScriptBlock {
        param($Features, $DebugPreference)
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
        } else {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
        }

        Invoke-WinUtilFeatureInstall $Features

        $sync.ProcessRunning = $false
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}
function Invoke-WPFFixesNetwork {
    <#

    .SYNOPSIS
        Resets various network configurations

    #>

    Write-Host "Resetting Network with netsh"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo"
    # Reset WinSock catalog to a clean state
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.35 -overlay "logo"
    # Resets WinHTTP proxy setting to DIRECT
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.7 -overlay "logo"
    # Removes all user configured IP settings
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    Write-Host "Process complete. Please reboot your computer."

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Network Reset "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "=========================================="
    Write-Host "-- Network Configuration has been Reset --"
    Write-Host "=========================================="
}
function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}
function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes Winget by running choco install winget
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall winget
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting Winget Repair"
        Install-WinUtilWinget -Force
    } catch {
        Write-Error "Failed to install winget: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished Winget Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}
function Invoke-WPFGetInstalled {
    <#
    TODO: Add the Option to use Chocolatey as Engine
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync["ManagerPreference"]

    Invoke-WPFRunspace -ParameterList @(("managerPreference", $managerPreference),("checkbox", $checkbox)) -DebugPreference $DebugPreference -ScriptBlock {
        param (
            [string]$checkbox,
            [PackageManagers]$managerPreference
        )
        $sync.ProcessRunning = $true
        $sync.form.Dispatcher.Invoke([action] { Set-WinUtilTaskbaritem -state "Indeterminate" })

        if ($checkbox -eq "winget") {
            Write-Host "Getting Installed Programs..."
            switch ($managerPreference) {
                "Choco"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox "choco"; break}
                "Winget"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox; break}
            }
        }
        elseif ($checkbox -eq "tweaks") {
            Write-Host "Getting Installed Tweaks..."
            $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox
        }

        $sync.form.Dispatcher.invoke({
            foreach ($checkbox in $Checkboxes) {
                $sync.$checkbox.ischecked = $True
            }
        })

        Write-Host "Done..."
        $sync.ProcessRunning = $false
        $sync.form.Dispatcher.Invoke([action] { Set-WinUtilTaskbaritem -state "None" })
    }
}
function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile
                    Update-WinUtilSelections -flatJson $flattenedJson
                    # TODO test with toggles
                    Reset-WPFCheckBoxes -doToggles $true
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}
function Invoke-WPFInstall {
    param (
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToInstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade"
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ManagerPreference = $sync["ManagerPreference"]

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -DebugPreference $DebugPreference -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference, $DebugPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Show-WPFInstallAppBusy -text "Installing apps..."
                Install-WinUtilWinget
                Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" -overlay "warning" })
        }
        $sync.ProcessRunning = $False
    }
}
function Invoke-WPFInstallUpgrade {
    <#

    .SYNOPSIS
        Invokes the function that upgrades all installed programs

    #>
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco
        $chocoUpgradeStatus = (Start-Process "choco" -ArgumentList "upgrade all -y" -Wait -PassThru -NoNewWindow).ExitCode
        if ($chocoUpgradeStatus -eq 0) {
            Write-Host "Upgrade Successful"
        }
        else{
            Write-Host "Error Occurred. Return Code: $chocoUpgradeStatus"
        }
    }
    else{
        if((Test-WinUtilPackageManager -winget) -eq "not-installed") {
            return
        }

        if(Get-WinUtilInstallerProcess -Process $global:WinGetInstall) {
            $msg = "[Invoke-WPFInstallUpgrade] Install process is currently running. Please check for a powershell window labeled 'Winget Install'"
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }

        Update-WinUtilProgramWinget

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="
    }
}
function Invoke-WPFOOSU {
    <#
    .SYNOPSIS
        Downloads and runs OO Shutup 10
    #>
    try {
        $OOSU_filepath = "$ENV:temp\OOSU10.exe"
        $Initial_ProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue" # Disables the Progress Bar to drasticly speed up Invoke-WebRequest
        Invoke-WebRequest -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -OutFile $OOSU_filepath
        Write-Host "Starting OO Shutup 10 ..."
        Start-Process $OOSU_filepath
    } catch {
        Write-Host "Error Downloading and Running OO Shutup 10" -ForegroundColor Red
    }
    finally {
        $ProgressPreference = $Initial_ProgressPreference
    }
}
function Invoke-WPFPanelAutologin {
    <#

    .SYNOPSIS
        Enables autologin using Sysinternals Autologon.exe

    #>

    # Official Microsoft recommendation: https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon.exe" -OutFile "$env:temp\autologin.exe"
    cmd /c "$env:temp\autologin.exe" /accepteula
}
function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}
function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern
    if (!$preset) {
        switch ($checkboxfilterpattern) {
            "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
            "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
            "WPFeatures" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
            "WPFToggle" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
            default {}
        }
    }
    else {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}
function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList,
        $DebugPreference
    )

    # Create a PowerShell instance
    $script:powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    $script:powershell.AddScript($ScriptBlock)
    $script:powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        $script:powershell.AddParameter($parameter[0], $parameter[1])
    }
    $script:powershell.AddArgument($DebugPreference)  # Pass DebugPreference to the script block
    $script:powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $script:handle = $script:powershell.BeginInvoke()

    # Clean up the RunspacePool threads when they are complete, and invoke the garbage collector to clean up the memory
    if ($script:handle.IsCompleted) {
        $script:powershell.EndInvoke($script:handle)
        $script:powershell.Dispose()
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
    }
    # Return the handle
    return $handle
}
function Invoke-WPFSelectedCheckboxesUpdate{
    <#
        .SYNOPSIS
            This is a helper function that is called by the Checked and Unchecked events of the Checkboxes.
            It also Updates the "Selected Apps" selectedAppLabel on the Install Tab to represent the current collection
        .PARAMETER type
            Either: Add | Remove
        .PARAMETER checkboxName
            should contain the name of the current instance of the checkbox that triggered the Event.
            Most of the time will be the automatic variable $this.Parent.Tag
        .EXAMPLE
            $checkbox.Add_Unchecked({Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag})
            OR
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $specificCheckbox.Parent.Tag
    #>
    param (
        $type,
        $checkboxName
    )

    if (($type -ne "Add") -and ($type -ne "Remove"))
    {
        Write-Error "Type: $type not implemented"
        return
    }

    # Get the actual Name from the selectedAppLabel inside the Checkbox
    $appKey = $checkboxName
    $group = if ($appKey.StartsWith("WPFInstall")) { "Install" }
                elseif ($appKey.StartsWith("WPFTweaks")) { "Tweaks" }
                elseif ($appKey.StartsWith("WPFToggle")) { "Toggle" }
                elseif ($appKey.StartsWith("WPFFeature")) { "Feature" }
                else { "na" }

    switch ($group) {
        "Install" {
            if ($type -eq "Add") {
               if (!$sync.selectedApps.Contains($appKey)) {
                    $sync.selectedApps.Add($appKey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[pscustomobject]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            else{
                $sync.selectedApps.Remove($appKey)
            }

            $count = $sync.SelectedApps.Count
            $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
            # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
            $sync.selectedAppsstackPanel.Children.Clear()
            $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }
        }
        "Tweaks" {
            if ($type -eq "Add") {
                if (!$sync.selectedTweaks.Contains($appKey)) {
                    $sync.selectedTweaks.Add($appKey)
                }
            }
            else{
                $sync.selectedTweaks.Remove($appKey)
            }
        }
        "Toggle" {
            if ($type -eq "Add") {
                if (!$sync.selectedToggles.Contains($appKey)) {
                    $sync.selectedToggles.Add($appKey)
                }
            }
            else{
                $sync.selectedToggles.Remove($appKey)
            }
        }
        "Feature" {
            if ($type -eq "Add") {
                if (!$sync.selectedFeatures.Contains($appKey)) {
                    $sync.selectedFeatures.Add($appKey)
                }
            }
            else{
                $sync.selectedFeatures.Remove($appKey)
            }
        }
        default {
            Write-Host "Unknown group for checkbox: $($appKey)"
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
}
function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -DebugPreference $DebugPreference -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}
function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM

    .DESCRIPTION
        1. SFC - Fixes system file corruption, and fixes DISM if it was corrupted
        2. DISM - Fixes system image corruption, and fixes SFC's system image if it was corrupted
        3. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
    #>
    Start-Process cmd.exe -ArgumentList "/c chkdsk.exe /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}
function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
            $tabNumber = [int]($ClickedTab-replace "WPFTab","" -replace "BT","") - 1
            $sync.$tabNav.Items[$tabNumber].IsSelected = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install and Tweaks tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}
function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}
function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] Install process is currently running."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks

  Set-WinUtilDNS -DNSProvider $sync["WPFchangedns"].text

  if ($tweaks.count -eq 0 -and  $sync["WPFchangedns"].text -eq "Default") {
    $msg = "Please check the tweaks you wish to perform."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  Write-Debug "Number of tweaks to process: $($Tweaks.Count)"

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  Invoke-WPFRunspace -ParameterList @(,("tweaks",$tweaks)) -DebugPreference $DebugPreference -ScriptBlock {
    param(
      $tweaks,
      $DebugPreference
      )
    Write-Debug "Inside Number of tweaks to process: $($Tweaks.Count)"

    $sync.ProcessRunning = $true

    if ($Tweaks.count -eq 1) {
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
    } else {
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
    }
    # Execute other selected tweaks

    for ($i = 0; $i -lt $Tweaks.Count; $i++) {
      Set-WinUtilProgressBar -Label "Applying $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($i/$Tweaks.Count) })
    }
    Set-WinUtilProgressBar -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="

    # $ButtonType = [System.Windows.MessageBoxButton]::OK
    # $MessageboxTitle = "Tweaks are Finished "
    # $Messageboxbody = ("Done")
    # $MessageIcon = [System.Windows.MessageBoxImage]::Information
    # [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
  }
}
function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        if ($entryInfo.Name -eq "WPFToggleFOSSHighlight") {
                             if ($entryInfo.Checked -eq $true) {
                                 $sync[$entryInfo.Name].IsChecked = $true
                             }

                             $sync[$entryInfo.Name].Add_Checked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                             $sync[$entryInfo.Name].Add_Unchecked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                        } else {
                            $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                            $sync[$entryInfo.Name].Add_Checked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                                Invoke-WinUtilTweaks $Sender.name
                            })

                            $sync[$entryInfo.Name].Add_Unchecked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            })
                        }
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkbox $Sender.name
                        })
                    }
                }
            }
        }
    }
}
Function Invoke-WPFUltimatePerformance {
    <#

    .SYNOPSIS
        Enables or disables the Ultimate Performance power scheme based on its GUID.

    .PARAMETER State
        Specifies whether to "Enable" or "Disable" the Ultimate Performance power scheme.

    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Enable", "Disable")]
        [string]$State
    )

    try {
        # GUID of the Ultimate Performance power plan
        $ultimateGUID = "e9a42b02-d5df-448d-aa00-03f14749eb61"

        switch ($State) {
            "Enable" {
                # Duplicate the Ultimate Performance power plan using its GUID
                $duplicateOutput = powercfg /duplicatescheme $ultimateGUID

                $guid = $null
                $nameFromFile = "ChrisTitus - Ultimate Power Plan"
                $description = "Ultimate Power Plan, added via WinUtils"

                # Extract the new GUID from the duplicateOutput
                foreach ($line in $duplicateOutput) {
                    if ($line -match "\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b") {
                        $guid = $matches[0]  # $matches[0] will contain the first match, which is the GUID
                        Write-Output "GUID: $guid has been extracted and stored in the variable."
                        break
                    }
                }

                if (-not $guid) {
                    Write-Output "No GUID found in the duplicateOutput. Check the output format."
                    exit 1
                }

                # Change the name of the power plan and set its description
                $changeNameOutput = powercfg /changename $guid "$nameFromFile" "$description"
                Write-Output "The power plan name and description have been changed. Output:"
                Write-Output $changeNameOutput

                # Set the duplicated Ultimate Performance plan as active
                $setActiveOutput = powercfg /setactive $guid
                Write-Output "The power plan has been set as active. Output:"
                Write-Output $setActiveOutput

                Write-Host "> Ultimate Performance plan installed and set as active."
            }
            "Disable" {
                # Check if the Ultimate Performance plan is installed by GUID
                $installedPlan = powercfg -list | Select-String -Pattern "ChrisTitus - Ultimate Power Plan"

                if ($installedPlan) {
                    # Extract the GUID of the installed Ultimate Performance plan
                    $ultimatePlanGUID = $installedPlan.Line.Split()[3]

                    # Set a different power plan as active before deleting the Ultimate Performance plan
                    $balancedPlanGUID = "381b4222-f694-41f0-9685-ff5bb260df2e"
                    powercfg -setactive $balancedPlanGUID

                    # Delete the Ultimate Performance plan by GUID
                    powercfg -delete $ultimatePlanGUID

                    Write-Host "Ultimate Performance plan has been uninstalled."
                    Write-Host "> Balanced plan is now active."
                } else {
                    Write-Host "Ultimate Performance plan is not installed."
                }
            }
            default {
                Write-Host "Invalid state. Please use 'Enable' or 'Disable'."
            }
        }
    } catch {
        Write-Error "Error occurred: $_"
    }
}
function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Please check the tweaks you wish to undo."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -DebugPreference $DebugPreference -ScriptBlock {
        param($tweaks, $DebugPreference)

        $sync.ProcessRunning = $true
        if ($tweaks.count -eq 1) {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
        } else {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilProgressBar -Label "Undoing $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) })
        }

        Set-WinUtilProgressBar -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="

    }
}
function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ButtonType = [System.Windows.MessageBoxButton]::YesNo
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    $confirm = [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync["ManagerPreference"]

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -DebugPreference $DebugPreference -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference, $DebugPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference
        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            Show-WPFInstallAppBusy -text "Uninstalling apps..."

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" -overlay "warning" })
        }
        $sync.ProcessRunning = $False

    }
}
function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Removing Windows Update policy settings..." -ForegroundColor Green

    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green

    Write-Host "Restored BITS to Manual"
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual"
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic"
    Set-Service -Name UsoSvc -StartupType Automatic

    Write-Host "Restored WaaSMedicSvc to Manual"
    Set-Service -Name WaaSMedicSvc -StartupType Manual

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Windows Local Policies Reset to Default"
    secedit /configure /cfg "$Env:SystemRoot\inf\defltbase.inf" /db defltbase.sdb

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
}
function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    Write-Host "Disabled BITS Service"
    Set-Service -Name BITS -StartupType Disabled

    Write-Host "Disabled wuauserv Service"
    Set-Service -Name wuauserv -StartupType Disabled

    Write-Host "Disabled UsoSvc Service"
    Set-Service -Name UsoSvc -StartupType Disabled

    Write-Host "Disabled WaaSMedicSvc Service"
    Set-Service -Name WaaSMedicSvc -StartupType Disabled

    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force
    Write-Host "Cleared SoftwareDistribution folder"

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "---   Updates Are Disabled    ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
}
function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Disables Windows Update automatic restart
        3. Sets Windows Update to Semi-Annual Channel (Targeted)
        4. Defers feature updates for 365 days
        5. Defers quality updates for 4 days

    #>

    Write-Host "Disabling driver offering through Windows Update..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Setting cumulative updates back by 1 year and security updates by 4 days"

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -Type DWord -Value 20
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    Write-Host "Disabling Windows Update automatic restart..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
}
Function Show-CTTLogo {
    <#
        .SYNOPSIS
            Displays the CTT logo in ASCII art.
        .DESCRIPTION
            This function displays the CTT logo in ASCII art format.
        .PARAMETER None
            No parameters are required for this function.
        .EXAMPLE
            Show-CTTLogo
            Prints the CTT logo in ASCII art format to the console.
    #>

$asciiArt = @"
WWWWWWWW                           WWWWWWWWUUUUUUUU     UUUUUUUUTTTTTTTTTTTTTTTTTTTTTTT
W::::::W                           W::::::WU::::::U     U::::::UT:::::::::::::::::::::T
W::::::W                           W::::::WU::::::U     U::::::UT:::::::::::::::::::::T
W::::::W                           W::::::WUU:::::U     U:::::UUT:::::TT:::::::TT:::::T
 W:::::W           WWWWW           W:::::W  U:::::U     U:::::U TTTTTTT  T:::::T  TTTTT
  W:::::W         W:::::W         W:::::W   U:::::D     U:::::U          T:::::T
   W:::::W       W:::::::W       W:::::W    U:::::U     U:::::U          T:::::T
    W:::::W     W:::::::::W     W:::::W     U:::::U     U:::::U          T:::::T
     W:::::W   W:::::W:::::W   W:::::W      U:::::U     U:::::U          T:::::T
      W:::::W W:::::W W:::::W W:::::W       U:::::U     U:::::U          T:::::T
       W:::::W:::::W   W:::::W:::::W        U:::::U     U:::::U          T:::::T
        W:::::::::W     W:::::::::W         U::::::U   U::::::U          T:::::T
         W:::::::W       W:::::::W          U:::::::UUU:::::::U        TT:::::::TT
          W:::::W         W:::::W            UU:::::::::::::UU         T:::::::::T
           W:::W           W:::W               UU:::::::::UU           T:::::::::T
            WWW             WWW                  UUUUUUUUU             TTTTTTTTTTT

=========================================
===== Windows Utility Tool =====
===== By SamNickGammer =====
=========================================
"@

    Write-Host $asciiArt
}

$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "Utilities",
    "choco": "1password",
    "content": "1Password",
    "description": "1Password is a password manager that allows you to store and manage your passwords securely.",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password"
  },
  "WPFInstall7zip": {
    "category": "Utilities",
    "choco": "7zip",
    "content": "7-Zip",
    "description": "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip",
    "foss": true
  },
  "WPFInstalladobe": {
    "category": "Document",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader",
    "description": "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit"
  },
  "WPFInstalladvancedip": {
    "category": "Pro Tools",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner",
    "description": "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner"
  },
  "WPFInstallaffine": {
    "category": "Document",
    "choco": "na",
    "content": "AFFiNE",
    "description": "AFFiNE is an open source alternative to Notion. Write, draw, plan all at once. Selfhost it to sync across devices.",
    "link": "https://affine.pro/",
    "winget": "ToEverything.AFFiNE",
    "foss": true
  },
  "WPFInstallaimp": {
    "category": "Multimedia Tools",
    "choco": "aimp",
    "content": "AIMP (Music Player)",
    "description": "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP"
  },
  "WPFInstallalacritty": {
    "category": "Utilities",
    "choco": "alacritty",
    "content": "Alacritty Terminal",
    "description": "Alacritty is a fast, cross-platform, and GPU-accelerated terminal emulator. It is designed for performance and aims to be the fastest terminal emulator available.",
    "link": "https://alacritty.org/",
    "winget": "Alacritty.Alacritty",
    "foss": true
  },
  "WPFInstallanaconda3": {
    "category": "Development",
    "choco": "anaconda3",
    "content": "Anaconda",
    "description": "Anaconda is a distribution of the Python and R programming languages for scientific computing.",
    "link": "https://www.anaconda.com/products/distribution",
    "winget": "Anaconda.Anaconda3"
  },
  "WPFInstallangryipscanner": {
    "category": "Pro Tools",
    "choco": "angryip",
    "content": "Angry IP Scanner",
    "description": "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner",
    "foss": true
  },
  "WPFInstallanki": {
    "category": "Document",
    "choco": "anki",
    "content": "Anki",
    "description": "Anki is a flashcard application that helps you memorize information with intelligent spaced repetition.",
    "link": "https://apps.ankiweb.net/",
    "winget": "Anki.Anki",
    "foss": true
  },
  "WPFInstallanydesk": {
    "category": "Utilities",
    "choco": "anydesk",
    "content": "AnyDesk",
    "description": "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
    "link": "https://anydesk.com/",
    "winget": "AnyDesk.AnyDesk"
  },
  "WPFInstallaudacity": {
    "category": "Multimedia Tools",
    "choco": "audacity",
    "content": "Audacity",
    "description": "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity",
    "foss": true
  },
  "WPFInstallautoruns": {
    "category": "Microsoft Tools",
    "choco": "autoruns",
    "content": "Autoruns",
    "description": "This utility shows you what programs are configured to run during system bootup or login",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns"
  },
  "WPFInstallrdcman": {
    "category": "Microsoft Tools",
    "choco": "rdcman",
    "content": "RDCMan",
    "description": "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan"
  },
  "WPFInstallautohotkey": {
    "category": "Utilities",
    "choco": "autohotkey",
    "content": "AutoHotkey",
    "description": "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey",
    "foss": true
  },
  "WPFInstallazuredatastudio": {
    "category": "Microsoft Tools",
    "choco": "azure-data-studio",
    "content": "Microsoft Azure Data Studio",
    "description": "Azure Data Studio is a data management tool that enables you to work with SQL Server, Azure SQL DB and SQL DW from Windows, macOS and Linux.",
    "link": "https://docs.microsoft.com/sql/azure-data-studio/what-is-azure-data-studio",
    "winget": "Microsoft.AzureDataStudio"
  },
  "WPFInstallbarrier": {
    "category": "Utilities",
    "choco": "barrier",
    "content": "Barrier",
    "description": "Barrier is an open-source software KVM (keyboard, video, and mouseswitch). It allows users to control multiple computers with a single keyboard and mouse, even if they have different operating systems.",
    "link": "https://github.com/debauchee/barrier",
    "winget": "DebaucheeOpenSourceGroup.Barrier",
    "foss": true
  },
  "WPFInstallbat": {
    "category": "Utilities",
    "choco": "bat",
    "content": "Bat (Cat)",
    "description": "Bat is a cat command clone with syntax highlighting. It provides a user-friendly and feature-rich alternative to the traditional cat command for viewing and concatenating files.",
    "link": "https://github.com/sharkdp/bat",
    "winget": "sharkdp.bat",
    "foss": true
  },
  "WPFInstallbeeper": {
    "category": "Communications",
    "choco": "na",
    "content": "Beeper",
    "description": "All your chats in one app",
    "link": "https://www.beeper.com/",
    "winget": "Beeper.Beeper"
  },
  "WPFInstallbitwarden": {
    "category": "Utilities",
    "choco": "bitwarden",
    "content": "Bitwarden",
    "description": "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden",
    "foss": true
  },
  "WPFInstallbleachbit": {
    "category": "Utilities",
    "choco": "bleachbit",
    "content": "BleachBit",
    "description": "Clean Your System and Free Disk Space",
    "link": "https://www.bleachbit.org/",
    "winget": "BleachBit.BleachBit",
    "foss": true
  },
  "WPFInstallblender": {
    "category": "Multimedia Tools",
    "choco": "blender",
    "content": "Blender (3D Graphics)",
    "description": "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender",
    "foss": true
  },
  "WPFInstallbrave": {
    "category": "Browsers",
    "choco": "brave",
    "content": "Brave",
    "description": "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave",
    "foss": true
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "Utilities",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller",
    "description": "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller",
    "foss": true
  },
  "WPFInstallbulkrenameutility": {
    "category": "Utilities",
    "choco": "bulkrenameutility",
    "content": "Bulk Rename Utility",
    "description": "Bulk Rename Utility allows you to easily rename files and folders recursively based upon find-replace, character place, fields, sequences, regular expressions, EXIF data, and more.",
    "link": "https://www.bulkrenameutility.co.uk",
    "winget": "TGRMNSoftware.BulkRenameUtility"
  },
  "WPFInstallAdvancedRenamer": {
    "category": "Utilities",
    "choco": "advanced-renamer",
    "content": "Advanced Renamer",
    "description": "Advanced Renamer is a program for renaming multiple files and folders at once. By configuring renaming methods the names can be manipulated in various ways.",
    "link": "https://www.advancedrenamer.com/",
    "winget": "HulubuluSoftware.AdvancedRenamer"
  },
  "WPFInstallcalibre": {
    "category": "Document",
    "choco": "calibre",
    "content": "Calibre",
    "description": "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre",
    "foss": true
  },
  "WPFInstallcarnac": {
    "category": "Utilities",
    "choco": "carnac",
    "content": "Carnac",
    "description": "Carnac is a keystroke visualizer for Windows. It displays keystrokes in an overlay, making it useful for presentations, tutorials, and live demonstrations.",
    "link": "https://carnackeys.com/",
    "winget": "code52.Carnac",
    "foss": true
  },
  "WPFInstallcemu": {
    "category": "Games",
    "choco": "cemu",
    "content": "Cemu",
    "description": "Cemu is a highly experimental software to emulate Wii U applications on PC.",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu",
    "foss": true
  },
  "WPFInstallchatterino": {
    "category": "Communications",
    "choco": "chatterino",
    "content": "Chatterino",
    "description": "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "Browsers",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome"
  },
  "WPFInstallchromium": {
    "category": "Browsers",
    "choco": "chromium",
    "content": "Chromium",
    "description": "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
    "link": "https://github.com/Hibbiki/chromium-win64",
    "winget": "Hibbiki.Chromium",
    "foss": true
  },
  "WPFInstallclementine": {
    "category": "Multimedia Tools",
    "choco": "clementine",
    "content": "Clementine",
    "description": "Clementine is a modern music player and library organizer, supporting various audio formats and online radio services.",
    "link": "https://www.clementine-player.org/",
    "winget": "Clementine.Clementine",
    "foss": true
  },
  "WPFInstallclink": {
    "category": "Development",
    "choco": "clink",
    "content": "Clink",
    "description": "Clink is a powerful Bash-compatible command-line interface (CLIenhancement for Windows, adding features like syntax highlighting and improved history).",
    "link": "https://mridgers.github.io/clink/",
    "winget": "chrisant996.Clink",
    "foss": true
  },
  "WPFInstallclonehero": {
    "category": "Games",
    "choco": "na",
    "content": "Clone Hero",
    "description": "Clone Hero is a free rhythm game, which can be played with any 5 or 6 button guitar controller.",
    "link": "https://clonehero.net/",
    "winget": "CloneHeroTeam.CloneHero"
  },
  "WPFInstallcmake": {
    "category": "Development",
    "choco": "cmake",
    "content": "CMake",
    "description": "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake",
    "foss": true
  },
  "WPFInstallcopyq": {
    "category": "Utilities",
    "choco": "copyq",
    "content": "CopyQ (Clipboard Manager)",
    "description": "CopyQ is a clipboard manager with advanced features, allowing you to store, edit, and retrieve clipboard history.",
    "link": "https://copyq.readthedocs.io/",
    "winget": "hluk.CopyQ",
    "foss": true
  },
  "WPFInstallcpuz": {
    "category": "Utilities",
    "choco": "cpu-z",
    "content": "CPU-Z",
    "description": "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer's hardware components, including the CPU, memory, and motherboard.",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z"
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "Utilities",
    "choco": "crystaldiskinfo",
    "content": "Crystal Disk Info",
    "description": "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo",
    "foss": true
  },
  "WPFInstallcapframex": {
    "category": "Utilities",
    "choco": "na",
    "content": "CapFrameX",
    "description": "Frametimes capture and analysis tool based on Intel's PresentMon. Overlay provided by Rivatuner Statistics Server.",
    "link": "https://www.capframex.com/",
    "winget": "CXWorld.CapFrameX",
    "foss": true
  },
  "WPFInstallcrystaldiskmark": {
    "category": "Utilities",
    "choco": "crystaldiskmark",
    "content": "Crystal Disk Mark",
    "description": "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark",
    "foss": true
  },
  "WPFInstalldarktable": {
    "category": "Multimedia Tools",
    "choco": "darktable",
    "content": "darktable",
    "description": "Open-source photo editing tool, offering an intuitive interface, advanced editing capabilities, and a non-destructive workflow for seamless image enhancement.",
    "link": "https://www.darktable.org/install/",
    "winget": "darktable.darktable",
    "foss": true
  },
  "WPFInstallDaxStudio": {
    "category": "Development",
    "choco": "daxstudio",
    "content": "DaxStudio",
    "description": "DAX (Data Analysis eXpressions) Studio is the ultimate tool for executing and analyzing DAX queries against Microsoft Tabular models.",
    "link": "https://daxstudio.org/",
    "winget": "DaxStudio.DaxStudio",
    "foss": true
  },
  "WPFInstallddu": {
    "category": "Utilities",
    "choco": "ddu",
    "content": "Display Driver Uninstaller",
    "description": "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "Wagnardsoft.DisplayDriverUninstaller"
  },
  "WPFInstalldeluge": {
    "category": "Utilities",
    "choco": "deluge",
    "content": "Deluge",
    "description": "Deluge is a free and open-source BitTorrent client. It features a user-friendly interface, support for plugins, and the ability to manage torrents remotely.",
    "link": "https://deluge-torrent.org/",
    "winget": "DelugeTeam.Deluge",
    "foss": true
  },
  "WPFInstalldevtoys": {
    "category": "Utilities",
    "choco": "devtoys",
    "content": "DevToys",
    "description": "DevToys is a collection of development-related utilities and tools for Windows. It includes tools for file management, code formatting, and productivity enhancements for developers.",
    "link": "https://devtoys.app/",
    "winget": "DevToys-app.DevToys",
    "foss": true
  },
  "WPFInstalldigikam": {
    "category": "Multimedia Tools",
    "choco": "digikam",
    "content": "digiKam",
    "description": "digiKam is an advanced open-source photo management software with features for organizing, editing, and sharing photos.",
    "link": "https://www.digikam.org/",
    "winget": "KDE.digikam",
    "foss": true
  },
  "WPFInstalldiscord": {
    "category": "Communications",
    "choco": "discord",
    "content": "Discord",
    "description": "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
    "link": "https://discord.com/",
    "winget": "Discord.Discord"
  },
  "WPFInstalldismtools": {
    "category": "Microsoft Tools",
    "choco": "na",
    "content": "DISMTools",
    "description": "DISMTools is a fast, customizable GUI for the DISM utility, supporting Windows images from Windows 7 onward. It handles installations on any drive, offers project support, and lets users tweak settings like color modes, language, and DISM versions; powered by both native DISM and a managed DISM API.",
    "link": "https://github.com/CodingWonders/DISMTools",
    "winget": "CodingWondersSoftware.DISMTools.Stable",
    "foss": true
  },
  "WPFInstallntlite": {
    "category": "Microsoft Tools",
    "choco": "ntlite-free",
    "content": "NTLite",
    "description": "Integrate updates, drivers, automate Windows and application setup, speedup Windows deployment process and have it all set for the next time.",
    "link": "https://ntlite.com",
    "winget": "Nlitesoft.NTLite"
  },
  "WPFInstallditto": {
    "category": "Utilities",
    "choco": "ditto",
    "content": "Ditto",
    "description": "Ditto is an extension to the standard windows clipboard.",
    "link": "https://github.com/sabrogden/Ditto",
    "winget": "Ditto.Ditto",
    "foss": true
  },
  "WPFInstalldockerdesktop": {
    "category": "Development",
    "choco": "docker-desktop",
    "content": "Docker Desktop",
    "description": "Docker Desktop is a powerful tool for containerized application development and deployment.",
    "link": "https://www.docker.com/products/docker-desktop",
    "winget": "Docker.DockerDesktop"
  },
  "WPFInstalldotnet3": {
    "category": "Microsoft Tools",
    "choco": "dotnetcore3-desktop-runtime",
    "content": ".NET Desktop Runtime 3.1",
    "description": ".NET Desktop Runtime 3.1 is a runtime environment required for running applications developed with .NET Core 3.1.",
    "link": "https://dotnet.microsoft.com/download/dotnet/3.1",
    "winget": "Microsoft.DotNet.DesktopRuntime.3_1"
  },
  "WPFInstalldotnet5": {
    "category": "Microsoft Tools",
    "choco": "dotnet-5.0-runtime",
    "content": ".NET Desktop Runtime 5",
    "description": ".NET Desktop Runtime 5 is a runtime environment required for running applications developed with .NET 5.",
    "link": "https://dotnet.microsoft.com/download/dotnet/5.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.5"
  },
  "WPFInstalldotnet6": {
    "category": "Microsoft Tools",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET Desktop Runtime 6",
    "description": ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6"
  },
  "WPFInstalldotnet7": {
    "category": "Microsoft Tools",
    "choco": "dotnet-7.0-runtime",
    "content": ".NET Desktop Runtime 7",
    "description": ".NET Desktop Runtime 7 is a runtime environment required for running applications developed with .NET 7.",
    "link": "https://dotnet.microsoft.com/download/dotnet/7.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.7"
  },
  "WPFInstalldotnet8": {
    "category": "Microsoft Tools",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET Desktop Runtime 8",
    "description": ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8"
  },
  "WPFInstalldotnet9": {
    "category": "Microsoft Tools",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET Desktop Runtime 9",
    "description": ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9"
  },
  "WPFInstalldmt": {
    "winget": "GNE.DualMonitorTools",
    "choco": "dual-monitor-tools",
    "category": "Utilities",
    "content": "Dual Monitor Tools",
    "link": "https://dualmonitortool.sourceforge.net/",
    "description": "Dual Monitor Tools (DMT) is a FOSS app that allows you to customize the handling of multiple monitors. Useful for fullscreen games and apps that handle a second monitor poorly and can improve your workflow.",
    "foss": true
  },
  "WPFInstallduplicati": {
    "category": "Utilities",
    "choco": "duplicati",
    "content": "Duplicati",
    "description": "Duplicati is an open-source backup solution that supports encrypted, compressed, and incremental backups. It is designed to securely store data on cloud storage services.",
    "link": "https://www.duplicati.com/",
    "winget": "Duplicati.Duplicati",
    "foss": true
  },
  "WPFInstalleaapp": {
    "category": "Games",
    "choco": "ea-app",
    "content": "EA App",
    "description": "EA App is a platform for accessing and playing Electronic Arts games.",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop"
  },
  "WPFInstalleartrumpet": {
    "category": "Multimedia Tools",
    "choco": "eartrumpet",
    "content": "EarTrumpet (Audio)",
    "description": "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet",
    "foss": true
  },
  "WPFInstalledge": {
    "category": "Browsers",
    "choco": "microsoft-edge",
    "content": "Edge",
    "description": "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge"
  },
  "WPFInstallefibooteditor": {
    "category": "Pro Tools",
    "choco": "na",
    "content": "EFI Boot Editor",
    "description": "EFI Boot Editor is a tool for managing the EFI/UEFI boot entries on your system. It allows you to customize the boot configuration of your computer.",
    "link": "https://www.easyuefi.com/",
    "winget": "EFIBootEditor.EFIBootEditor"
  },
  "WPFInstallemulationstation": {
    "category": "Games",
    "choco": "emulationstation",
    "content": "Emulation Station",
    "description": "Emulation Station is a graphical and themeable emulator front-end that allows you to access all your favorite games in one place.",
    "link": "https://emulationstation.org/",
    "winget": "Emulationstation.Emulationstation",
    "foss": true
  },
  "WPFInstallenteauth": {
    "category": "Utilities",
    "choco": "ente-auth",
    "content": "Ente Auth",
    "description": "Ente Auth is a free, cross-platform, end-to-end encrypted authenticator app.",
    "link": "https://ente.io/auth/",
    "winget": "ente-io.auth-desktop",
    "foss": true
  },
  "WPFInstallepicgames": {
    "category": "Games",
    "choco": "epicgameslauncher",
    "content": "Epic Games Launcher",
    "description": "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher"
  },
  "WPFInstallesearch": {
    "category": "Utilities",
    "choco": "everything",
    "content": "Everything Search",
    "description": "Everything Search is a fast and efficient file search utility for Windows.",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything"
  },
  "WPFInstallespanso": {
    "category": "Utilities",
    "choco": "espanso",
    "content": "Espanso",
    "description": "Cross-platform and open-source Text Expander written in Rust",
    "link": "https://espanso.org/",
    "winget": "Espanso.Espanso",
    "foss": true
  },
  "WPFInstallffmpeg": {
    "category": "Utilities",
    "choco": "na",
    "content": "FFmpeg Batch AV Converter",
    "description": "FFmpeg Batch AV Converter is a universal audio and video encoder, that allows to use the full potential of ffmpeg command line with a few mouse clicks in a convenient GUI with drag and drop, progress information.",
    "link": "https://ffmpeg-batch.sourceforge.io/",
    "winget": "eibol.FFmpegBatchAVConverter",
    "foss": true
  },
  "WPFInstallfalkon": {
    "category": "Browsers",
    "choco": "falkon",
    "content": "Falkon",
    "description": "Falkon is a lightweight and fast web browser with a focus on user privacy and efficiency.",
    "link": "https://www.falkon.org/",
    "winget": "KDE.Falkon",
    "foss": true
  },
  "WPFInstallfastfetch": {
    "category": "Utilities",
    "choco": "na",
    "content": "Fastfetch",
    "description": "Fastfetch is a neofetch-like tool for fetching system information and displaying them in a pretty way",
    "link": "https://github.com/fastfetch-cli/fastfetch/",
    "winget": "Fastfetch-cli.Fastfetch",
    "foss": true
  },
  "WPFInstallferdium": {
    "category": "Communications",
    "choco": "ferdium",
    "content": "Ferdium",
    "description": "Ferdium is a messaging application that combines multiple messaging services into a single app for easy management.",
    "link": "https://ferdium.org/",
    "winget": "Ferdium.Ferdium",
    "foss": true
  },
  "WPFInstallffmpeg-full": {
    "category": "Multimedia Tools",
    "choco": "ffmpeg-full",
    "content": "FFmpeg (full)",
    "description": "FFmpeg is a powerful multimedia processing tool that enables users to convert, edit, and stream audio and video files with a vast range of codecs and formats. | Note: FFmpeg can not be uninstalled using winget.",
    "link": "https://ffmpeg.org/",
    "winget": "Gyan.FFmpeg"
  },
  "WPFInstallfileconverter": {
    "category": "Utilities",
    "choco": "file-converter",
    "content": "File-Converter",
    "description": "File Converter is a very simple tool which allows you to convert and compress one or several file(s) using the context menu in windows explorer.",
    "link": "https://file-converter.io/",
    "winget": "AdrienAllard.FileConverter",
    "foss": true
  },
  "WPFInstallfiles": {
    "category": "Utilities",
    "choco": "files",
    "content": "Files",
    "description": "Alternative file explorer.",
    "link": "https://github.com/files-community/Files",
    "winget": "na",
    "foss": true
  },
  "WPFInstallfirealpaca": {
    "category": "Multimedia Tools",
    "choco": "firealpaca",
    "content": "Fire Alpaca",
    "description": "Fire Alpaca is a free digital painting software that provides a wide range of drawing tools and a user-friendly interface.",
    "link": "https://firealpaca.com/",
    "winget": "FireAlpaca.FireAlpaca"
  },
  "WPFInstallfirefox": {
    "category": "Browsers",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallfirefoxesr": {
    "category": "Browsers",
    "choco": "FirefoxESR",
    "content": "Firefox ESR",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR",
    "foss": true
  },
  "WPFInstallflameshot": {
    "category": "Multimedia Tools",
    "choco": "flameshot",
    "content": "Flameshot (Screenshots)",
    "description": "Flameshot is a powerful yet simple to use screenshot software, offering annotation and editing features.",
    "link": "https://flameshot.org/",
    "winget": "Flameshot.Flameshot",
    "foss": true
  },
  "WPFInstalllightshot": {
    "category": "Multimedia Tools",
    "choco": "lightshot",
    "content": "Lightshot (Screenshots)",
    "description": "Ligthshot is an Easy-to-use, light-weight screenshot software tool, where you can optionally edit your screenshots using different tools, share them via Internet and/or save to disk, and customize the available options.",
    "link": "https://app.prntscr.com/",
    "winget": "Skillbrains.Lightshot"
  },
  "WPFInstallfloorp": {
    "category": "Browsers",
    "choco": "na",
    "content": "Floorp",
    "description": "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp",
    "foss": true
  },
  "WPFInstallflow": {
    "category": "Utilities",
    "choco": "flow-launcher",
    "content": "Flow launcher",
    "description": "Keystroke launcher for Windows to search, manage and launch files, folders bookmarks, websites and more.",
    "link": "https://www.flowlauncher.com/",
    "winget": "Flow-Launcher.Flow-Launcher",
    "foss": true
  },
  "WPFInstallflux": {
    "category": "Utilities",
    "choco": "flux",
    "content": "F.lux",
    "description": "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux"
  },
  "WPFInstallfoobar": {
    "category": "Multimedia Tools",
    "choco": "foobar2000",
    "content": "foobar2000 (Music Player)",
    "description": "foobar2000 is a highly customizable and extensible music player for Windows, known for its modular design and advanced features.",
    "link": "https://www.foobar2000.org/",
    "winget": "PeterPawlowski.foobar2000"
  },
  "WPFInstallfoxpdfeditor": {
    "category": "Document",
    "choco": "na",
    "content": "Foxit PDF Editor",
    "description": "Foxit PDF Editor is a feature-rich PDF editor and viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-editor/",
    "winget": "Foxit.PhantomPDF"
  },
  "WPFInstallfoxpdfreader": {
    "category": "Document",
    "choco": "foxitreader",
    "content": "Foxit PDF Reader",
    "description": "Foxit PDF Reader is a free PDF viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-reader/",
    "winget": "Foxit.FoxitReader"
  },
  "WPFInstallfreecad": {
    "category": "Multimedia Tools",
    "choco": "freecad",
    "content": "FreeCAD",
    "description": "FreeCAD is a parametric 3D CAD modeler, designed for product design and engineering tasks, with a focus on flexibility and extensibility.",
    "link": "https://www.freecadweb.org/",
    "winget": "FreeCAD.FreeCAD",
    "foss": true
  },
  "WPFInstallfxsound": {
    "category": "Multimedia Tools",
    "choco": "fxsound",
    "content": "FxSound",
    "description": "FxSound is free open-source software to boost sound quality, volume, and bass. Including an equalizer, effects, and presets for customized audio.",
    "link": "https://www.fxsound.com/",
    "winget": "FxSound.FxSound",
    "foss": true
  },
  "WPFInstallfzf": {
    "category": "Utilities",
    "choco": "fzf",
    "content": "Fzf",
    "description": "A command-line fuzzy finder",
    "link": "https://github.com/junegunn/fzf/",
    "winget": "junegunn.fzf",
    "foss": true
  },
  "WPFInstallgeforcenow": {
    "category": "Games",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW",
    "description": "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow"
  },
  "WPFInstallgimp": {
    "category": "Multimedia Tools",
    "choco": "gimp",
    "content": "GIMP (Image Editor)",
    "description": "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP.3",
    "foss": true
  },
  "WPFInstallgit": {
    "category": "Development",
    "choco": "git",
    "content": "Git",
    "description": "Git is a distributed version control system widely used for tracking changes in source code during software development.",
    "link": "https://git-scm.com/",
    "winget": "Git.Git",
    "foss": true
  },
  "WPFInstallgitbutler": {
    "category": "Development",
    "choco": "na",
    "content": "Git Butler",
    "description": "A Git client for simultaneous branches on top of your existing workflow.",
    "link": "https://gitbutler.com/",
    "winget": "GitButler.GitButler"
  },
  "WPFInstallgitextensions": {
    "category": "Development",
    "choco": "git;gitextensions",
    "content": "Git Extensions",
    "description": "Git Extensions is a graphical user interface for Git, providing additional features for easier source code management.",
    "link": "https://gitextensions.github.io/",
    "winget": "GitExtensionsTeam.GitExtensions"
  },
  "WPFInstallgithubcli": {
    "category": "Development",
    "choco": "git;gh",
    "content": "GitHub CLI",
    "description": "GitHub CLI is a command-line tool that simplifies working with GitHub directly from the terminal.",
    "link": "https://cli.github.com/",
    "winget": "GitHub.cli",
    "foss": true
  },
  "WPFInstallgithubdesktop": {
    "category": "Development",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop",
    "description": "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop",
    "foss": true
  },
  "WPFInstallgitkrakenclient": {
    "category": "Development",
    "choco": "gitkraken",
    "content": "GitKraken Client",
    "description": "GitKraken Client is a powerful visual Git client from Axosoft that works with ALL git repositories on any hosting environment.",
    "link": "https://www.gitkraken.com/git-client",
    "winget": "Axosoft.GitKraken"
  },
  "WPFInstallglaryutilities": {
    "category": "Utilities",
    "choco": "glaryutilities-free",
    "content": "Glary Utilities",
    "description": "Glary Utilities is a comprehensive system optimization and maintenance tool for Windows.",
    "link": "https://www.glarysoft.com/glary-utilities/",
    "winget": "Glarysoft.GlaryUtilities"
  },
  "WPFInstallgodotengine": {
    "category": "Development",
    "choco": "godot",
    "content": "Godot Engine",
    "description": "Godot Engine is a free, open-source 2D and 3D game engine with a focus on usability and flexibility.",
    "link": "https://godotengine.org/",
    "winget": "GodotEngine.GodotEngine",
    "foss": true
  },
  "WPFInstallgog": {
    "category": "Games",
    "choco": "goggalaxy",
    "content": "GOG Galaxy",
    "description": "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy"
  },
  "WPFInstallgitify": {
    "category": "Development",
    "choco": "na",
    "content": "Gitify",
    "description": "GitHub notifications on your menu bar.",
    "link": "https://www.gitify.io/",
    "winget": "Gitify.Gitify",
    "foss": true
  },
  "WPFInstallgolang": {
    "category": "Development",
    "choco": "golang",
    "content": "Go",
    "description": "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
    "link": "https://go.dev/",
    "winget": "GoLang.Go",
    "foss": true
  },
  "WPFInstallgoogledrive": {
    "category": "Utilities",
    "choco": "googledrive",
    "content": "Google Drive",
    "description": "File syncing across devices all tied to your google account",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive"
  },
  "WPFInstallgpuz": {
    "category": "Utilities",
    "choco": "gpu-z",
    "content": "GPU-Z",
    "description": "GPU-Z provides detailed information about your graphics card and GPU.",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z"
  },
  "WPFInstallgreenshot": {
    "category": "Multimedia Tools",
    "choco": "greenshot",
    "content": "Greenshot (Screenshots)",
    "description": "Greenshot is a light-weight screenshot software tool with built-in image editor and customizable capture options.",
    "link": "https://getgreenshot.org/",
    "winget": "Greenshot.Greenshot",
    "foss": true
  },
  "WPFInstallgsudo": {
    "category": "Utilities",
    "choco": "gsudo",
    "content": "Gsudo",
    "description": "Gsudo is a sudo implementation for Windows, allowing elevated privilege execution.",
    "link": "https://gerardog.github.io/gsudo/",
    "winget": "gerardog.gsudo"
  },
  "WPFInstallhandbrake": {
    "category": "Multimedia Tools",
    "choco": "handbrake",
    "content": "HandBrake",
    "description": "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake",
    "foss": true
  },
  "WPFInstallharmonoid": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Harmonoid",
    "description": "Plays and manages your music library. Looks beautiful and juicy. Playlists, visuals, synced lyrics, pitch shift, volume boost and more.",
    "link": "https://harmonoid.com/",
    "winget": "Harmonoid.Harmonoid",
    "foss": true
  },
  "WPFInstallheidisql": {
    "category": "Pro Tools",
    "choco": "heidisql",
    "content": "HeidiSQL",
    "description": "HeidiSQL is a powerful and easy-to-use client for MySQL, MariaDB, Microsoft SQL Server, and PostgreSQL databases. It provides tools for database management and development.",
    "link": "https://www.heidisql.com/",
    "winget": "HeidiSQL.HeidiSQL",
    "foss": true
  },
  "WPFInstallhelix": {
    "category": "Development",
    "choco": "helix",
    "content": "Helix",
    "description": "Helix is a neovim alternative built in rust.",
    "link": "https://helix-editor.com/",
    "winget": "Helix.Helix",
    "foss": true
  },
  "WPFInstallheroiclauncher": {
    "category": "Games",
    "choco": "na",
    "content": "Heroic Games Launcher",
    "description": "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher",
    "foss": true
  },
  "WPFInstallhexchat": {
    "category": "Communications",
    "choco": "hexchat",
    "content": "Hexchat",
    "description": "HexChat is a free, open-source IRC (Internet Relay Chat) client with a graphical interface for easy communication.",
    "link": "https://hexchat.github.io/",
    "winget": "HexChat.HexChat",
    "foss": true
  },
  "WPFInstallhwinfo": {
    "category": "Utilities",
    "choco": "hwinfo",
    "content": "HWiNFO",
    "description": "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO"
  },
  "WPFInstallhwmonitor": {
    "category": "Utilities",
    "choco": "hwmonitor",
    "content": "HWMonitor",
    "description": "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor"
  },
  "WPFInstallimhex": {
    "category": "Development",
    "choco": "na",
    "content": "ImHex (Hex Editor)",
    "description": "A modern, featureful Hex Editor for Reverse Engineers and Developers.",
    "link": "https://imhex.werwolv.net/",
    "winget": "WerWolv.ImHex",
    "foss": true
  },
  "WPFInstallimageglass": {
    "category": "Multimedia Tools",
    "choco": "imageglass",
    "content": "ImageGlass (Image Viewer)",
    "description": "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass",
    "foss": true
  },
  "WPFInstallimgburn": {
    "category": "Multimedia Tools",
    "choco": "imgburn",
    "content": "ImgBurn",
    "description": "ImgBurn is a lightweight CD, DVD, HD-DVD, and Blu-ray burning application with advanced features for creating and burning disc images.",
    "link": "https://www.imgburn.com/",
    "winget": "LIGHTNINGUK.ImgBurn"
  },
  "WPFInstallinkscape": {
    "category": "Multimedia Tools",
    "choco": "inkscape",
    "content": "Inkscape",
    "description": "Inkscape is a powerful open-source vector graphics editor, suitable for tasks such as illustrations, icons, logos, and more.",
    "link": "https://inkscape.org/",
    "winget": "Inkscape.Inkscape",
    "foss": true
  },
  "WPFInstallitch": {
    "category": "Games",
    "choco": "itch",
    "content": "Itch.io",
    "description": "Itch.io is a digital distribution platform for indie games and creative projects.",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch",
    "foss": true
  },
  "WPFInstallitunes": {
    "category": "Multimedia Tools",
    "choco": "itunes",
    "content": "iTunes",
    "description": "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes"
  },
  "WPFInstalljami": {
    "category": "Communications",
    "choco": "jami",
    "content": "Jami",
    "description": "Jami is a secure and privacy-focused communication platform that offers audio and video calls, messaging, and file sharing.",
    "link": "https://jami.net/",
    "winget": "SFLinux.Jami",
    "foss": true
  },
  "WPFInstalljava8": {
    "category": "Development",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK",
    "foss": true
  },
  "WPFInstalljava11": {
    "category": "Development",
    "choco": "corretto11jdk",
    "content": "Amazon Corretto 11 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.11.JDK",
    "foss": true
  },
  "WPFInstalljava17": {
    "category": "Development",
    "choco": "corretto17jdk",
    "content": "Amazon Corretto 17 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.17.JDK",
    "foss": true
  },
  "WPFInstalljava21": {
    "category": "Development",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK",
    "foss": true
  },
  "WPFInstalljava25": {
    "category": "Development",
    "choco": "corretto25jdk",
    "content": "Amazon Corretto 25 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.25.JDK",
    "foss": true
  },
  "WPFInstalljdownloader": {
    "category": "Utilities",
    "choco": "jdownloader",
    "content": "JDownloader",
    "description": "JDownloader is a feature-rich download manager with support for various file hosting services.",
    "link": "https://jdownloader.org/",
    "winget": "AppWork.JDownloader"
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "Multimedia Tools",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin Media Player",
    "description": "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
    "link": "https://github.com/jellyfin/jellyfin-media-player",
    "winget": "Jellyfin.JellyfinMediaPlayer",
    "foss": true
  },
  "WPFInstalljellyfinserver": {
    "category": "Multimedia Tools",
    "choco": "jellyfin",
    "content": "Jellyfin Server",
    "description": "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server",
    "foss": true
  },
  "WPFInstalljetbrains": {
    "category": "Development",
    "choco": "jetbrainstoolbox",
    "content": "Jetbrains Toolbox",
    "description": "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox"
  },
  "WPFInstalljoplin": {
    "category": "Document",
    "choco": "joplin",
    "content": "Joplin (FOSS Notes)",
    "description": "Joplin is an open-source note-taking and to-do application with synchronization capabilities.",
    "link": "https://joplinapp.org/",
    "winget": "Joplin.Joplin",
    "foss": true
  },
  "WPFInstalljpegview": {
    "category": "Utilities",
    "choco": "jpegview",
    "content": "JPEG View",
    "description": "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF and TIFF images with a minimal GUI",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView",
    "foss": true
  },
  "WPFInstallkdeconnect": {
    "category": "Utilities",
    "choco": "kdeconnect-kde",
    "content": "KDE Connect",
    "description": "KDE Connect allows seamless integration between your KDE desktop and mobile devices.",
    "link": "https://community.kde.org/KDEConnect",
    "winget": "KDE.KDEConnect",
    "foss": true
  },
  "WPFInstallkdenlive": {
    "category": "Multimedia Tools",
    "choco": "kdenlive",
    "content": "Kdenlive (Video Editor)",
    "description": "Kdenlive is an open-source video editing software with powerful features for creating and editing professional-quality videos.",
    "link": "https://kdenlive.org/",
    "winget": "KDE.Kdenlive",
    "foss": true
  },
  "WPFInstallkeepass": {
    "category": "Utilities",
    "choco": "keepassxc",
    "content": "KeePassXC",
    "description": "KeePassXC is a cross-platform, open-source password manager with strong encryption features.",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC",
    "foss": true
  },
  "WPFInstallklite": {
    "category": "Multimedia Tools",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite Codec Standard",
    "description": "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard"
  },
  "WPFInstallkodi": {
    "category": "Multimedia Tools",
    "choco": "kodi",
    "content": "Kodi Media Center",
    "description": "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi",
    "foss": true
  },
  "WPFInstallkrita": {
    "category": "Multimedia Tools",
    "choco": "krita",
    "content": "Krita (Image Editor)",
    "description": "Krita is a powerful open-source painting application. It is designed for concept artists, illustrators, matte and texture artists, and the VFX industry.",
    "link": "https://krita.org/en/features/",
    "winget": "KDE.Krita",
    "foss": true
  },
  "WPFInstalllazygit": {
    "category": "Development",
    "choco": "lazygit",
    "content": "Lazygit",
    "description": "Simple terminal UI for git commands",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit",
    "foss": true
  },
  "WPFInstalllibreoffice": {
    "category": "Document",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice",
    "description": "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice",
    "foss": true
  },
  "WPFInstalllibrewolf": {
    "category": "Browsers",
    "choco": "librewolf",
    "content": "LibreWolf",
    "description": "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
    "link": "https://librewolf-community.gitlab.io/",
    "winget": "LibreWolf.LibreWolf",
    "foss": true
  },
  "WPFInstalllinkshellextension": {
    "category": "Utilities",
    "choco": "linkshellextension",
    "content": "Link Shell extension",
    "description": "Link Shell Extension (LSE) provides for the creation of Hardlinks, Junctions, Volume Mountpoints, Symbolic Links, a folder cloning process that utilises Hardlinks or Symbolic Links and a copy process taking care of Junctions, Symbolic Links, and Hardlinks. LSE, as its name implies is implemented as a Shell extension and is accessed from Windows Explorer, or similar file/folder managers.",
    "link": "https://schinagl.priv.at/nt/hardlinkshellext/hardlinkshellext.html",
    "winget": "HermannSchinagl.LinkShellExtension"
  },
  "WPFInstalllinphone": {
    "category": "Communications",
    "choco": "linphone",
    "content": "Linphone",
    "description": "Linphone is an open-source voice over IP (VoIPservice that allows for audio and video calls, messaging, and more.",
    "link": "https://www.linphone.org/",
    "winget": "BelledonneCommunications.Linphone",
    "foss": true
  },
  "WPFInstalllivelywallpaper": {
    "category": "Utilities",
    "choco": "lively",
    "content": "Lively Wallpaper",
    "description": "Free and open-source software that allows users to set animated desktop wallpapers and screensavers.",
    "link": "https://www.rocksdanister.com/lively/",
    "winget": "rocksdanister.LivelyWallpaper",
    "foss": true
  },
  "WPFInstalllocalsend": {
    "category": "Utilities",
    "choco": "localsend.install",
    "content": "LocalSend",
    "description": "An open source cross-platform alternative to AirDrop.",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend",
    "foss": true
  },
  "WPFInstalllockhunter": {
    "category": "Utilities",
    "choco": "lockhunter",
    "content": "LockHunter",
    "description": "LockHunter is a free tool to delete files blocked by something you do not know.",
    "link": "https://lockhunter.com/",
    "winget": "CrystalRich.LockHunter"
  },
  "WPFInstalllogseq": {
    "category": "Document",
    "choco": "logseq",
    "content": "Logseq",
    "description": "Logseq is a versatile knowledge management and note-taking application designed for the digital thinker. With a focus on the interconnectedness of ideas, Logseq allows users to seamlessly organize their thoughts through a combination of hierarchical outlines and bi-directional linking. It supports both structured and unstructured content, enabling users to create a personalized knowledge graph that adapts to their evolving ideas and insights.",
    "link": "https://logseq.com/",
    "winget": "Logseq.Logseq",
    "foss": true
  },
  "WPFInstallmalwarebytes": {
    "category": "Utilities",
    "choco": "malwarebytes",
    "content": "Malwarebytes",
    "description": "Malwarebytes is an anti-malware software that provides real-time protection against threats.",
    "link": "https://www.malwarebytes.com/",
    "winget": "Malwarebytes.Malwarebytes"
  },
  "WPFInstallmasscode": {
    "category": "Document",
    "choco": "na",
    "content": "massCode (Snippet Manager)",
    "description": "massCode is a fast and efficient open-source code snippet manager for developers.",
    "link": "https://masscode.io/",
    "winget": "antonreshetov.massCode",
    "foss": true
  },
  "WPFInstallmatrix": {
    "category": "Communications",
    "choco": "element-desktop",
    "content": "Element",
    "description": "Element is a client for Matrix; an open network for secure, decentralized communication.",
    "link": "https://element.io/",
    "winget": "Element.Element",
    "foss": true
  },
  "WPFInstallmeld": {
    "category": "Utilities",
    "choco": "meld",
    "content": "Meld",
    "description": "Meld is a visual diff and merge tool for files and directories.",
    "link": "https://meldmerge.org/",
    "winget": "Meld.Meld",
    "foss": true
  },
  "WPFInstallModernFlyouts": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Modern Flyouts",
    "description": "An open source, modern, Fluent Design-based set of flyouts for Windows.",
    "link": "https://github.com/ModernFlyouts-Community/ModernFlyouts/",
    "winget": "ModernFlyouts.ModernFlyouts",
    "foss": true
  },
  "WPFInstallmonitorian": {
    "category": "Utilities",
    "choco": "monitorian",
    "content": "Monitorian",
    "description": "Monitorian is a utility for adjusting monitor brightness and contrast on Windows.",
    "link": "https://github.com/emoacht/Monitorian",
    "winget": "emoacht.Monitorian",
    "foss": true
  },
  "WPFInstallmoonlight": {
    "category": "Games",
    "choco": "moonlight-qt",
    "content": "Moonlight/GameStream Client",
    "description": "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight",
    "foss": true
  },
  "WPFInstallMotrix": {
    "category": "Utilities",
    "choco": "motrix",
    "content": "Motrix Download Manager",
    "description": "A full-featured download manager.",
    "link": "https://motrix.app/",
    "winget": "agalwood.Motrix",
    "foss": true
  },
  "WPFInstallmpchc": {
    "category": "Multimedia Tools",
    "choco": "mpc-hc-clsid2",
    "content": "Media Player Classic - Home Cinema",
    "description": "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
    "link": "https://github.com/clsid2/mpc-hc/",
    "winget": "clsid2.mpc-hc",
    "foss": true
  },
  "WPFInstallmremoteng": {
    "category": "Pro Tools",
    "choco": "mremoteng",
    "content": "mRemoteNG",
    "description": "mRemoteNG is a free and open-source remote connections manager. It allows you to view and manage multiple remote sessions in a single interface.",
    "link": "https://mremoteng.org/",
    "winget": "mRemoteNG.mRemoteNG",
    "foss": true
  },
  "WPFInstallmsedgeredirect": {
    "category": "Utilities",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect",
    "description": "A Tool to Redirect News, Search, Widgets, Weather, and More to Your Default Browser.",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect",
    "foss": true
  },
  "WPFInstallmsiafterburner": {
    "category": "Utilities",
    "choco": "msiafterburner",
    "content": "MSI Afterburner",
    "description": "MSI Afterburner is a graphics card overclocking utility with advanced features.",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner"
  },
  "WPFInstallmullvadvpn": {
    "category": "Pro Tools",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "This is the VPN client software for the Mullvad VPN service.",
    "link": "https://github.com/mullvad/mullvadvpn-app",
    "winget": "MullvadVPN.MullvadVPN",
    "foss": true
  },
  "WPFInstallBorderlessGaming": {
    "category": "Utilities",
    "choco": "borderlessgaming",
    "content": "Borderless Gaming",
    "description": "Play your favorite games in a borderless window; no more time consuming alt-tabs.",
    "link": "https://github.com/Codeusa/Borderless-Gaming",
    "winget": "Codeusa.BorderlessGaming",
    "foss": true
  },
  "WPFInstallEqualizerAPO": {
    "category": "Multimedia Tools",
    "choco": "equalizerapo",
    "content": "Equalizer APO",
    "description": "Equalizer APO is a parametric / graphic equalizer for Windows.",
    "link": "https://sourceforge.net/projects/equalizerapo",
    "winget": "na",
    "foss": true
  },
  "WPFInstallCompactGUI": {
    "category": "Utilities",
    "choco": "compactgui",
    "content": "Compact GUI",
    "description": "Transparently compress active games and programs using Windows 10/11 APIs",
    "link": "https://github.com/IridiumIO/CompactGUI",
    "winget": "IridiumIO.CompactGUI",
    "foss": true
  },
  "WPFInstallExifCleaner": {
    "category": "Utilities",
    "choco": "na",
    "content": "ExifCleaner",
    "description": "Desktop app to clean metadata from images, videos, PDFs, and other files.",
    "link": "https://github.com/szTheory/exifcleaner",
    "winget": "szTheory.exifcleaner",
    "foss": true
  },
  "WPFInstallmullvadbrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Mullvad Browser",
    "description": "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser",
    "foss": true
  },
  "WPFInstallmusescore": {
    "category": "Multimedia Tools",
    "choco": "musescore",
    "content": "MuseScore",
    "description": "Create, play back and print beautiful sheet music with free and easy to use music notation software MuseScore.",
    "link": "https://musescore.org/en",
    "winget": "Musescore.Musescore",
    "foss": true
  },
  "WPFInstallmusicbee": {
    "category": "Multimedia Tools",
    "choco": "musicbee",
    "content": "MusicBee (Music Player)",
    "description": "MusicBee is a customizable music player with support for various audio formats. It includes features like an integrated search function, tag editing, and more.",
    "link": "https://getmusicbee.com/",
    "winget": "MusicBee.MusicBee"
  },
  "WPFInstallmp3tag": {
    "category": "Multimedia Tools",
    "choco": "mp3tag",
    "content": "Mp3tag (Metadata Audio Editor)",
    "description": "Mp3tag is a powerful and yet easy-to-use tool to edit metadata of common audio formats.",
    "link": "https://www.mp3tag.de/en/",
    "winget": "Mp3tag.Mp3tag"
  },
  "WPFInstalltagscanner": {
    "category": "Multimedia Tools",
    "choco": "tagscanner",
    "content": "TagScanner (Tag Scanner)",
    "description": "TagScanner is a powerful tool for organizing and managing your music collection",
    "link": "https://www.xdlab.ru/en/",
    "winget": "SergeySerkov.TagScanner"
  },
  "WPFInstallnanazip": {
    "category": "Utilities",
    "choco": "nanazip",
    "content": "NanaZip",
    "description": "NanaZip is a fast and efficient file compression and decompression tool.",
    "link": "https://github.com/M2Team/NanaZip",
    "winget": "M2Team.NanaZip",
    "foss": true
  },
  "WPFInstallnetbird": {
    "category": "Pro Tools",
    "choco": "netbird",
    "content": "NetBird",
    "description": "NetBird is a Open Source alternative comparable to TailScale that can be connected to a selfhosted Server.",
    "link": "https://netbird.io/",
    "winget": "netbird",
    "foss": true
  },
  "WPFInstallnaps2": {
    "category": "Document",
    "choco": "naps2",
    "content": "NAPS2 (Document Scanner)",
    "description": "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2",
    "foss": true
  },
  "WPFInstallneofetchwin": {
    "category": "Utilities",
    "choco": "na",
    "content": "Neofetch",
    "description": "Neofetch is a command-line utility for displaying system information in a visually appealing way.",
    "link": "https://github.com/nepnep39/neofetch-win",
    "winget": "nepnep.neofetch-win",
    "foss": true
  },
  "WPFInstallneovim": {
    "category": "Development",
    "choco": "neovim",
    "content": "Neovim",
    "description": "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim"
  },
  "WPFInstallnextclouddesktop": {
    "category": "Utilities",
    "choco": "nextcloud-client",
    "content": "Nextcloud Desktop",
    "description": "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop",
    "foss": true
  },
  "WPFInstallnglide": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "nGlide (3dfx compatibility)",
    "description": "nGlide is a 3Dfx Voodoo Glide wrapper. It allows you to play games that use Glide API on modern graphics cards without the need for a 3Dfx Voodoo graphics card.",
    "link": "https://www.zeus-software.com/downloads/nglide",
    "winget": "ZeusSoftware.nGlide"
  },
  "WPFInstallnmap": {
    "category": "Pro Tools",
    "choco": "nmap",
    "content": "Nmap",
    "description": "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap",
    "foss": true
  },
  "WPFInstallnodejs": {
    "category": "Development",
    "choco": "nodejs",
    "content": "NodeJS",
    "description": "NodeJS is a JavaScript runtime built on Chrome's V8 JavaScript engine for building server-side and networking applications.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallnodejslts": {
    "category": "Development",
    "choco": "nodejs-lts",
    "content": "NodeJS LTS",
    "description": "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS"
  },
  "WPFInstallnomacs": {
    "category": "Multimedia Tools",
    "choco": "nomacs",
    "content": "Nomacs (Image viewer)",
    "description": "Nomacs is a free, open-source image viewer that supports multiple platforms. It features basic image editing capabilities and supports a variety of image formats.",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs",
    "foss": true
  },
  "WPFInstallnotepadplus": {
    "category": "Document",
    "choco": "notepadplusplus",
    "content": "Notepad++",
    "description": "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++",
    "foss": true
  },
  "WPFInstallnuget": {
    "category": "Microsoft Tools",
    "choco": "nuget.commandline",
    "content": "NuGet",
    "description": "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet",
    "foss": true
  },
  "WPFInstallnushell": {
    "category": "Utilities",
    "choco": "nushell",
    "content": "Nushell",
    "description": "Nushell is a new shell that takes advantage of modern hardware and systems to provide a powerful, expressive, and fast experience.",
    "link": "https://www.nushell.sh/",
    "winget": "Nushell.Nushell",
    "foss": true
  },
  "WPFInstallnvclean": {
    "category": "Utilities",
    "choco": "na",
    "content": "NVCleanstall",
    "description": "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall"
  },
  "WPFInstallnvm": {
    "category": "Development",
    "choco": "nvm",
    "content": "Node Version Manager",
    "description": "Node Version Manager (NVM) for Windows allows you to easily switch between multiple Node.js versions.",
    "link": "https://github.com/coreybutler/nvm-windows",
    "winget": "CoreyButler.NVMforWindows",
    "foss": true
  },
  "WPFInstallobs": {
    "category": "Multimedia Tools",
    "choco": "obs-studio",
    "content": "OBS Studio",
    "description": "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio",
    "foss": true
  },
  "WPFInstallobsidian": {
    "category": "Document",
    "choco": "obsidian",
    "content": "Obsidian",
    "description": "Obsidian is a powerful note-taking and knowledge management application.",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian"
  },
  "WPFInstallokular": {
    "category": "Document",
    "choco": "okular",
    "content": "Okular",
    "description": "Okular is a versatile document viewer with advanced features.",
    "link": "https://okular.kde.org/",
    "winget": "KDE.Okular",
    "foss": true
  },
  "WPFInstallonedrive": {
    "category": "Microsoft Tools",
    "choco": "onedrive",
    "content": "OneDrive",
    "description": "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive"
  },
  "WPFInstallonlyoffice": {
    "category": "Document",
    "choco": "onlyoffice",
    "content": "ONLYOffice Desktop",
    "description": "ONLYOffice Desktop is a comprehensive office suite for document editing and collaboration.",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors",
    "foss": true
  },
  "WPFInstallOPAutoClicker": {
    "category": "Utilities",
    "choco": "autoclicker",
    "content": "OPAutoClicker",
    "description": "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker"
  },
  "WPFInstallopenhashtab": {
    "category": "Utilities",
    "choco": "openhashtab",
    "content": "OpenHashTab",
    "description": "OpenHashTab is a shell extension for conveniently calculating and checking file hashes from file properties.",
    "link": "https://github.com/namazso/OpenHashTab/",
    "winget": "namazso.OpenHashTab",
    "foss": true
  },
  "WPFInstallopenrgb": {
    "category": "Utilities",
    "choco": "openrgb",
    "content": "OpenRGB",
    "description": "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
    "link": "https://openrgb.org/",
    "winget": "OpenRGB.OpenRGB",
    "foss": true
  },
  "WPFInstallopenscad": {
    "category": "Multimedia Tools",
    "choco": "openscad",
    "content": "OpenSCAD",
    "description": "OpenSCAD is a free and open-source script-based 3D CAD modeler. It is especially useful for creating parametric designs for 3D printing.",
    "link": "https://www.openscad.org/",
    "winget": "OpenSCAD.OpenSCAD",
    "foss": true
  },
  "WPFInstallopenshell": {
    "category": "Utilities",
    "choco": "open-shell",
    "content": "Open Shell (Start Menu)",
    "description": "Open Shell is a Windows Start Menu replacement with enhanced functionality and customization options.",
    "link": "https://github.com/Open-Shell/Open-Shell-Menu",
    "winget": "Open-Shell.Open-Shell-Menu",
    "foss": true
  },
  "WPFInstallOpenVPN": {
    "category": "Pro Tools",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect",
    "description": "OpenVPN Connect is an open-source VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect",
    "foss": true
  },
  "WPFInstallOVirtualBox": {
    "category": "Utilities",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox",
    "description": "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox",
    "foss": true
  },
  "WPFInstallownclouddesktop": {
    "category": "Utilities",
    "choco": "owncloud-client",
    "content": "ownCloud Desktop",
    "description": "ownCloud Desktop is the official desktop client for the ownCloud file synchronization and sharing platform.",
    "link": "https://owncloud.com/desktop-app/",
    "winget": "ownCloud.ownCloudDesktop",
    "foss": true
  },
  "WPFInstallpolicyplus": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Policy Plus",
    "description": "Local Group Policy Editor plus more, for all Windows editions.",
    "link": "https://github.com/Fleex255/PolicyPlus",
    "winget": "Fleex255.PolicyPlus",
    "foss": true
  },
  "WPFInstallpotplayer": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "PotPlayer",
    "description": "PotPlayer is a free Windows media player with wide format support, high performance, built-in codecs, and extensive customization options.",
    "link": "https://potplayer.tv/",
    "winget": "Daum.PotPlayer"
  },
  "WPFInstallprocessexplorer": {
    "category": "Microsoft Tools",
    "choco": "na",
    "content": "Process Explorer",
    "description": "Process Explorer is a task manager and system monitor.",
    "link": "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
    "winget": "Microsoft.Sysinternals.ProcessExplorer"
  },
  "WPFInstallPaintdotnet": {
    "category": "Multimedia Tools",
    "choco": "paint.net",
    "content": "Paint.NET",
    "description": "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet"
  },
  "WPFInstallparsec": {
    "category": "Utilities",
    "choco": "parsec",
    "content": "Parsec",
    "description": "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec"
  },
  "WPFInstallpdf24creator": {
    "category": "Document",
    "choco": "pdf24",
    "content": "PDF24 creator",
    "description": "Free and easy-to-use online/desktop PDF tools that make you more productive",
    "link": "https://tools.pdf24.org/en/",
    "winget": "geeksoftwareGmbH.PDF24Creator"
  },
  "WPFInstallpdfsam": {
    "category": "Document",
    "choco": "pdfsam",
    "content": "PDFsam Basic",
    "description": "PDFsam Basic is a free and open-source tool for splitting, merging, and rotating PDF files.",
    "link": "https://pdfsam.org/",
    "winget": "PDFsam.PDFsam",
    "foss": true
  },
  "WPFInstallpeazip": {
    "category": "Utilities",
    "choco": "peazip",
    "content": "PeaZip",
    "description": "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip",
    "foss": true
  },
  "WPFInstallpiimager": {
    "category": "Utilities",
    "choco": "rpi-imager",
    "content": "Raspberry Pi Imager",
    "description": "Raspberry Pi Imager is a utility for writing operating system images to SD cards for Raspberry Pi devices.",
    "link": "https://www.raspberrypi.com/software/",
    "winget": "RaspberryPiFoundation.RaspberryPiImager"
  },
  "WPFInstallplaynite": {
    "category": "Games",
    "choco": "playnite",
    "content": "Playnite",
    "description": "Playnite is an open-source video game library manager with one simple goal: To provide a unified interface for all of your games.",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite",
    "foss": true
  },
  "WPFInstallplex": {
    "category": "Multimedia Tools",
    "choco": "plexmediaserver",
    "content": "Plex Media Server",
    "description": "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer"
  },
  "WPFInstallplexdesktop": {
    "category": "Multimedia Tools",
    "choco": "plex",
    "content": "Plex Desktop",
    "description": "Plex Desktop for Windows is the front end for Plex Media Server.",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex"
  },
  "WPFInstallPortmaster": {
    "category": "Pro Tools",
    "choco": "portmaster",
    "content": "Portmaster",
    "description": "Portmaster is a free and open-source application that puts you back in charge over all your computers network connections.",
    "link": "https://safing.io/",
    "winget": "Safing.Portmaster",
    "foss": true
  },
  "WPFInstallposh": {
    "category": "Development",
    "choco": "oh-my-posh",
    "content": "Oh My Posh (Prompt)",
    "description": "Oh My Posh is a cross-platform prompt theme engine for any shell.",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh",
    "foss": true
  },
  "WPFInstallpostman": {
    "category": "Development",
    "choco": "postman",
    "content": "Postman",
    "description": "Postman is a collaboration platform for API development that simplifies the process of developing APIs.",
    "link": "https://www.postman.com/",
    "winget": "Postman.Postman"
  },
  "WPFInstallpowerautomate": {
    "category": "Microsoft Tools",
    "choco": "powerautomatedesktop",
    "content": "Power Automate",
    "description": "Using Power Automate Desktop you can automate tasks on the desktop as well as the Web.",
    "link": "https://www.microsoft.com/en-us/power-platform/products/power-automate",
    "winget": "Microsoft.PowerAutomateDesktop"
  },
  "WPFInstallpowerbi": {
    "category": "Microsoft Tools",
    "choco": "powerbi",
    "content": "Power BI",
    "description": "Create stunning reports and visualizations with Power BI Desktop. It puts visual analytics at your fingertips with intuitive report authoring. Drag-and-drop to place content exactly where you want it on the flexible and fluid canvas. Quickly discover patterns as you explore a single unified view of linked, interactive visualizations.",
    "link": "https://www.microsoft.com/en-us/power-platform/products/power-bi/",
    "winget": "Microsoft.PowerBI"
  },
  "WPFInstallpowershell": {
    "category": "Microsoft Tools",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallpowertoys": {
    "category": "Microsoft Tools",
    "choco": "powertoys",
    "content": "PowerToys",
    "description": "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys",
    "foss": true
  },
  "WPFInstallprismlauncher": {
    "category": "Games",
    "choco": "prismlauncher",
    "content": "Prism Launcher",
    "description": "Prism Launcher is an Open Source Minecraft launcher with the ability to manage multiple instances, accounts and mods.",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher",
    "foss": true
  },
  "WPFInstallprocesslasso": {
    "category": "Utilities",
    "choco": "plasso",
    "content": "Process Lasso",
    "description": "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso"
  },
  "WPFInstallprotonauth": {
    "category": "Utilities",
    "choco": "protonauth",
    "content": "Proton Authenticator",
    "description": "2FA app from Proton to securely sync and backup 2FA codes.",
    "link": "https://proton.me/authenticator",
    "winget": "Proton.ProtonAuthenticator",
    "foss": true
  },
  "WPFInstallprocessmonitor": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "SysInternals Process Monitor",
    "description": "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor"
  },
  "WPFInstallorcaslicer": {
    "category": "Utilities",
    "choco": "orcaslicer",
    "content": "OrcaSlicer",
    "description": "G-code generator for 3D printers (Bambu, Prusa, Voron, VzBot, RatRig, Creality, etc.)",
    "link": "https://github.com/SoftFever/OrcaSlicer",
    "winget": "SoftFever.OrcaSlicer",
    "foss": true
  },
  "WPFInstallprucaslicer": {
    "category": "Utilities",
    "choco": "prusaslicer",
    "content": "PrusaSlicer",
    "description": "PrusaSlicer is a powerful and easy-to-use slicing software for 3D printing with Prusa 3D printers.",
    "link": "https://www.prusa3d.com/prusaslicer/",
    "winget": "Prusa3d.PrusaSlicer",
    "foss": true
  },
  "WPFInstallpsremoteplay": {
    "category": "Games",
    "choco": "ps-remote-play",
    "content": "PS Remote Play",
    "description": "PS Remote Play is a free application that allows you to stream games from your PlayStation console to a PC or mobile device.",
    "link": "https://remoteplay.dl.playstation.net/remoteplay/lang/gb/",
    "winget": "PlayStation.PSRemotePlay"
  },
  "WPFInstallputty": {
    "category": "Pro Tools",
    "choco": "putty",
    "content": "PuTTY",
    "description": "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY",
    "foss": true
  },
  "WPFInstallpython3": {
    "category": "Development",
    "choco": "python",
    "content": "Python3",
    "description": "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.14",
    "foss": true
  },
  "WPFInstallqbittorrent": {
    "category": "Utilities",
    "choco": "qbittorrent",
    "content": "qBittorrent",
    "description": "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent",
    "foss": true
  },
  "WPFInstalltransmission": {
    "category": "Utilities",
    "choco": "transmission",
    "content": "Transmission",
    "description": "Transmission is a cross-platform BitTorrent client that is open source, easy, powerful, and lean.",
    "link": "https://transmissionbt.com/",
    "winget": "Transmission.Transmission",
    "foss": true
  },
  "WPFInstalltixati": {
    "category": "Utilities",
    "choco": "tixati.portable",
    "content": "Tixati",
    "description": "Tixati is a cross-platform BitTorrent client written in C++ that has been designed to be light on system resources.",
    "link": "https://www.tixati.com/",
    "winget": "Tixati.Tixati.Portable"
  },
  "WPFInstallqtox": {
    "category": "Communications",
    "choco": "qtox",
    "content": "QTox",
    "description": "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox",
    "foss": true
  },
  "WPFInstallquicklook": {
    "category": "Utilities",
    "choco": "quicklook",
    "content": "Quicklook",
    "description": "Bring macOS ?Quick Look? feature to Windows",
    "link": "https://github.com/QL-Win/QuickLook",
    "winget": "QL-Win.QuickLook",
    "foss": true
  },
  "WPFInstallrainmeter": {
    "category": "Utilities",
    "choco": "na",
    "content": "Rainmeter",
    "description": "Rainmeter is a desktop customization tool that allows you to create and share customizable skins for your desktop.",
    "link": "https://www.rainmeter.net/",
    "winget": "Rainmeter.Rainmeter",
    "foss": true
  },
  "WPFInstallrevo": {
    "category": "Utilities",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller",
    "description": "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller"
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "Utilities",
    "choco": "na",
    "content": "Wise Program Uninstaller (WiseCleaner)",
    "description": "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller"
  },
  "WPFInstallrevolt": {
    "category": "Communications",
    "choco": "na",
    "content": "Revolt",
    "description": "Find your community, connect with the world. Revolt is one of the best ways to stay connected with your friends and community without sacrificing any usability.",
    "link": "https://revolt.chat/",
    "winget": "Revolt.RevoltDesktop",
    "foss": true
  },
  "WPFInstallripgrep": {
    "category": "Utilities",
    "choco": "ripgrep",
    "content": "Ripgrep",
    "description": "Fast and powerful commandline search tool",
    "link": "https://github.com/BurntSushi/ripgrep/",
    "winget": "BurntSushi.ripgrep.MSVC",
    "foss": true
  },
  "WPFInstallrufus": {
    "category": "Utilities",
    "choco": "rufus",
    "content": "Rufus Imager",
    "description": "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus",
    "foss": true
  },
  "WPFInstallrustdesk": {
    "category": "Pro Tools",
    "choco": "rustdesk.portable",
    "content": "RustDesk",
    "description": "RustDesk is a free and open-source remote desktop application. It provides a secure way to connect to remote machines and access desktop environments.",
    "link": "https://rustdesk.com/",
    "winget": "RustDesk.RustDesk",
    "foss": true
  },
  "WPFInstallrustlang": {
    "category": "Development",
    "choco": "rust",
    "content": "Rust",
    "description": "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC",
    "foss": true
  },
  "WPFInstallsagethumbs": {
    "category": "Utilities",
    "choco": "sagethumbs",
    "content": "SageThumbs",
    "description": "Provides support for thumbnails in Explorer with more formats.",
    "link": "https://sagethumbs.en.lo4d.com/windows",
    "winget": "CherubicSoftware.SageThumbs",
    "foss": true
  },
  "WPFInstallsandboxie": {
    "category": "Utilities",
    "choco": "sandboxie",
    "content": "Sandboxie Plus",
    "description": "Sandboxie Plus is a sandbox-based isolation program that provides enhanced security by running applications in an isolated environment.",
    "link": "https://github.com/sandboxie-plus/Sandboxie",
    "winget": "Sandboxie.Plus",
    "foss": true
  },
  "WPFInstallsdio": {
    "category": "Utilities",
    "choco": "sdio",
    "content": "Snappy Driver Installer Origin",
    "description": "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin",
    "foss": true
  },
  "WPFInstallsession": {
    "category": "Communications",
    "choco": "session",
    "content": "Session",
    "description": "Session is a private and secure messaging app built on a decentralized network for user privacy and data protection.",
    "link": "https://getsession.org/",
    "winget": "Session.Session",
    "foss": true
  },
  "WPFInstallsharex": {
    "category": "Multimedia Tools",
    "choco": "sharex",
    "content": "ShareX (Screenshots)",
    "description": "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX",
    "foss": true
  },
  "WPFInstallnilesoftShell": {
    "category": "Utilities",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell",
    "description": "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell"
  },
  "WPFInstallsysteminformer": {
    "category": "Development",
    "choco": "na",
    "content": "System Informer",
    "description": "A free, powerful, multi-purpose tool that helps you monitor system resources, debug software and detect malware.",
    "link": "https://systeminformer.com/",
    "winget": "WinsiderSS.SystemInformer",
    "foss": true
  },
  "WPFInstallsidequest": {
    "category": "Games",
    "choco": "sidequest",
    "content": "SideQuestVR",
    "description": "SideQuestVR is a community-driven platform that enables users to discover, install, and manage virtual reality content on Oculus Quest devices.",
    "link": "https://sidequestvr.com/",
    "winget": "SideQuestVR.SideQuest"
  },
  "WPFInstallsignal": {
    "category": "Communications",
    "choco": "signal",
    "content": "Signal",
    "description": "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal",
    "foss": true
  },
  "WPFInstallsignalrgb": {
    "category": "Utilities",
    "choco": "na",
    "content": "SignalRGB",
    "description": "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb"
  },
  "WPFInstallsimplenote": {
    "category": "Document",
    "choco": "simplenote",
    "content": "simplenote",
    "description": "Simplenote is an easy way to keep notes, lists, ideas and more.",
    "link": "https://simplenote.com/",
    "winget": "Automattic.Simplenote",
    "foss": true
  },
  "WPFInstallsimplewall": {
    "category": "Pro Tools",
    "choco": "simplewall",
    "content": "Simplewall",
    "description": "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall",
    "foss": true
  },
  "WPFInstallslack": {
    "category": "Communications",
    "choco": "slack",
    "content": "Slack",
    "description": "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack"
  },
  "WPFInstallspacedrive": {
    "category": "Utilities",
    "choco": "na",
    "content": "Spacedrive File Manager",
    "description": "Spacedrive is a file manager that offers cloud storage integration and file synchronization across devices.",
    "link": "https://www.spacedrive.com/",
    "winget": "spacedrive.Spacedrive",
    "foss": true
  },
  "WPFInstallspacesniffer": {
    "category": "Utilities",
    "choco": "spacesniffer",
    "content": "SpaceSniffer",
    "description": "A tool application that lets you understand how folders and files are structured on your disks",
    "link": "http://www.uderzo.it/main_products/space_sniffer/",
    "winget": "UderzoSoftware.SpaceSniffer"
  },
  "WPFInstallstarship": {
    "category": "Development",
    "choco": "starship",
    "content": "Starship (Shell Prompt)",
    "description": "Starship is a minimal, fast, and customizable prompt for any shell.",
    "link": "https://starship.rs/",
    "winget": "starship",
    "foss": true
  },
  "WPFInstallsteam": {
    "category": "Games",
    "choco": "steam-client",
    "content": "Steam",
    "description": "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam"
  },
  "WPFInstallstrawberry": {
    "category": "Multimedia Tools",
    "choco": "strawberrymusicplayer",
    "content": "Strawberry (Music Player)",
    "description": "Strawberry is an open-source music player that focuses on music collection management and audio quality. It supports various audio formats and features a clean user interface.",
    "link": "https://www.strawberrymusicplayer.org/",
    "winget": "StrawberryMusicPlayer.Strawberry",
    "foss": true
  },
  "WPFInstallstremio": {
    "winget": "Stremio.Stremio",
    "choco": "stremio",
    "category": "Multimedia Tools",
    "content": "Stremio",
    "link": "https://www.stremio.com/",
    "description": "Stremio is a media center application that allows users to organize and stream their favorite movies, TV shows, and video content.",
    "foss": true
  },
  "WPFInstallsublimemerge": {
    "category": "Development",
    "choco": "sublimemerge",
    "content": "Sublime Merge",
    "description": "Sublime Merge is a Git client with advanced features and a beautiful interface.",
    "link": "https://www.sublimemerge.com/",
    "winget": "SublimeHQ.SublimeMerge"
  },
  "WPFInstallsublimetext": {
    "category": "Development",
    "choco": "sublimetext4",
    "content": "Sublime Text",
    "description": "Sublime Text is a sophisticated text editor for code, markup, and prose.",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4"
  },
  "WPFInstallsumatra": {
    "category": "Document",
    "choco": "sumatrapdf",
    "content": "Sumatra PDF",
    "description": "Sumatra PDF is a lightweight and fast PDF viewer with minimalistic design.",
    "link": "https://www.sumatrapdfreader.org/free-pdf-reader.html",
    "winget": "SumatraPDF.SumatraPDF",
    "foss": true
  },
  "WPFInstallpdfgear": {
    "category": "Document",
    "choco": "na",
    "content": "PDFgear",
    "description": "PDFgear is a piece of full-featured PDF management software for Windows, Mac, and mobile, and it's completely free to use.",
    "link": "https://www.pdfgear.com/",
    "winget": "PDFgear.PDFgear"
  },
  "WPFInstallsunshine": {
    "category": "Games",
    "choco": "sunshine",
    "content": "Sunshine/GameStream Server",
    "description": "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
    "link": "https://github.com/LizardByte/Sunshine",
    "winget": "LizardByte.Sunshine",
    "foss": true
  },
  "WPFInstallsuperf4": {
    "category": "Utilities",
    "choco": "superf4",
    "content": "SuperF4",
    "description": "SuperF4 is a utility that allows you to terminate programs instantly by pressing a customizable hotkey.",
    "link": "https://stefansundin.github.io/superf4/",
    "winget": "StefanSundin.Superf4",
    "foss": true
  },
  "WPFInstallswift": {
    "category": "Development",
    "choco": "na",
    "content": "Swift toolchain",
    "description": "Swift is a general-purpose programming language that's approachable for newcomers and powerful for experts.",
    "link": "https://www.swift.org/",
    "winget": "Swift.Toolchain",
    "foss": true
  },
  "WPFInstallsynctrayzor": {
    "category": "Utilities",
    "choco": "synctrayzor",
    "content": "SyncTrayzor",
    "description": "Windows tray utility / filesystem watcher / launcher for Syncthing",
    "link": "https://github.com/GermanCoding/SyncTrayzor",
    "winget": "GermanCoding.SyncTrayzor",
    "foss": true
  },
  "WPFInstallsqlmanagementstudio": {
    "category": "Microsoft Tools",
    "choco": "sql-server-management-studio",
    "content": "Microsoft SQL Server Management Studio",
    "description": "SQL Server Management Studio (SSMS) is an integrated environment for managing any SQL infrastructure, from SQL Server to Azure SQL Database. SSMS provides tools to configure, monitor, and administer instances of SQL Server and databases.",
    "link": "https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms?view=sql-server-ver16",
    "winget": "Microsoft.SQLServerManagementStudio"
  },
  "WPFInstalltabby": {
    "category": "Utilities",
    "choco": "tabby",
    "content": "Tabby.sh",
    "description": "Tabby is a highly configurable terminal emulator, SSH and serial client for Windows, macOS and Linux",
    "link": "https://tabby.sh/",
    "winget": "Eugeny.Tabby",
    "foss": true
  },
  "WPFInstalltailscale": {
    "category": "Utilities",
    "choco": "tailscale",
    "content": "Tailscale",
    "description": "Tailscale is a secure and easy-to-use VPN solution for connecting your devices and networks.",
    "link": "https://tailscale.com/",
    "winget": "tailscale.tailscale",
    "foss": true
  },
  "WPFInstallTcNoAccSwitcher": {
    "category": "Games",
    "choco": "tcno-acc-switcher",
    "content": "TCNO Account Switcher",
    "description": "A Super-fast account switcher for Steam, Battle.net, Epic Games, Origin, Riot, Ubisoft and many others!",
    "link": "https://github.com/TCNOco/TcNo-Acc-Switcher",
    "winget": "TechNobo.TcNoAccountSwitcher",
    "foss": true
  },
  "WPFInstalltcpview": {
    "category": "Microsoft Tools",
    "choco": "tcpview",
    "content": "SysInternals TCPView",
    "description": "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView"
  },
  "WPFInstallteams": {
    "category": "Communications",
    "choco": "microsoft-teams",
    "content": "Teams",
    "description": "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams"
  },
  "WPFInstallteamviewer": {
    "category": "Utilities",
    "choco": "teamviewer9",
    "content": "TeamViewer",
    "description": "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer"
  },
  "WPFInstalltelegram": {
    "category": "Communications",
    "choco": "telegram",
    "content": "Telegram",
    "description": "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop",
    "foss": true
  },
  "WPFInstallunigram": {
    "category": "Communications",
    "choco": "na",
    "content": "Unigram",
    "description": "Unigram - Telegram for Windows",
    "link": "https://unigramdev.github.io/",
    "winget": "Telegram.Unigram",
    "foss": true
  },
  "WPFInstallterminal": {
    "category": "Microsoft Tools",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstallThonny": {
    "category": "Development",
    "choco": "thonny",
    "content": "Thonny Python IDE",
    "description": "Python IDE for beginners.",
    "link": "https://github.com/thonny/thonny",
    "winget": "AivarAnnamaa.Thonny",
    "foss": true
  },
  "WPFInstallMuEditor": {
    "category": "Development",
    "choco": "na",
    "content": "Code With Mu (Mu Editor)",
    "description": "Mu is a Python code editor for beginner programmers",
    "link": "https://codewith.mu/",
    "winget": "Mu.Mu",
    "foss": true
  },
  "WPFInstallthorium": {
    "category": "Browsers",
    "choco": "thorium",
    "content": "Thorium Browser AVX2",
    "description": "Browser built for speed over vanilla chromium. It is built with AVX2 optimizations and is the fastest browser on the market.",
    "link": "https://thorium.rocks/",
    "winget": "Alex313031.Thorium.AVX2",
    "foss": true
  },
  "WPFInstallthunderbird": {
    "category": "Communications",
    "choco": "thunderbird",
    "content": "Thunderbird",
    "description": "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird",
    "foss": true
  },
  "WPFInstallbetterbird": {
    "category": "Communications",
    "choco": "betterbird",
    "content": "Betterbird",
    "description": "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird",
    "foss": true
  },
  "WPFInstalltidal": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Tidal",
    "description": "Tidal is a music streaming service known for its high-fidelity audio quality and exclusive content. It offers a vast library of songs and curated playlists.",
    "link": "https://tidal.com/",
    "winget": "9NNCB5BS59PH"
  },
  "WPFInstalltor": {
    "category": "Browsers",
    "choco": "tor-browser",
    "content": "Tor Browser",
    "description": "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser",
    "foss": true
  },
  "WPFInstalltotalcommander": {
    "category": "Utilities",
    "choco": "TotalCommander",
    "content": "Total Commander",
    "description": "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander"
  },
  "WPFInstalltreesize": {
    "category": "Utilities",
    "choco": "treesizefree",
    "content": "TreeSize Free",
    "description": "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free"
  },
  "WPFInstallttaskbar": {
    "category": "Utilities",
    "choco": "translucenttb",
    "content": "TranslucentTB",
    "description": "TranslucentTB is a tool that allows you to customize the transparency of the Windows taskbar.",
    "link": "https://github.com/TranslucentTB/TranslucentTB",
    "winget": "9PF4KZ2VN4W9",
    "foss": true
  },
  "WPFInstalltwinkletray": {
    "category": "Utilities",
    "choco": "twinkle-tray",
    "content": "Twinkle Tray",
    "description": "Twinkle Tray lets you easily manage the brightness levels of multiple monitors.",
    "link": "https://twinkletray.com/",
    "winget": "xanderfrangos.twinkletray",
    "foss": true
  },
  "WPFInstallubisoft": {
    "category": "Games",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect",
    "description": "Ubisoft Connect is Ubisoft's digital distribution and online gaming service, providing access to Ubisoft's games and services.",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect"
  },
  "WPFInstallungoogled": {
    "category": "Browsers",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled",
    "description": "Ungoogled Chromium is a version of Chromium without Google's integration for enhanced privacy and control.",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium",
    "foss": true
  },
  "WPFInstallunity": {
    "category": "Development",
    "choco": "unityhub",
    "content": "Unity Game Engine",
    "description": "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub"
  },
  "WPFInstallvagrant": {
    "category": "Development",
    "choco": "vagrant",
    "content": "Vagrant",
    "description": "Vagrant is an open-source tool for building and managing virtualized development environments.",
    "link": "https://www.vagrantup.com/",
    "winget": "Hashicorp.Vagrant",
    "foss": true
  },
  "WPFInstallvc2015_32": {
    "category": "Microsoft Tools",
    "choco": "na",
    "content": "Visual C++ 2015-2022 32-bit",
    "description": "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86"
  },
  "WPFInstallvc2015_64": {
    "category": "Microsoft Tools",
    "choco": "na",
    "content": "Visual C++ 2015-2022 64-bit",
    "description": "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64"
  },
  "WPFInstallventoy": {
    "category": "Pro Tools",
    "choco": "ventoy",
    "content": "Ventoy",
    "description": "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy",
    "foss": true
  },
  "WPFInstallvesktop": {
    "category": "Communications",
    "choco": "na",
    "content": "Vesktop",
    "description": "A cross platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
    "link": "https://github.com/Vencord/Vesktop",
    "winget": "Vencord.Vesktop",
    "foss": true
  },
  "WPFInstallviber": {
    "category": "Communications",
    "choco": "viber",
    "content": "Viber",
    "description": "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
    "link": "https://www.viber.com/",
    "winget": "Rakuten.Viber"
  },
  "WPFInstallvideomass": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Videomass",
    "description": "Videomass by GianlucaPernigotto is a cross-platform GUI for FFmpeg, streamlining multimedia file processing with batch conversions and user-friendly features.",
    "link": "https://jeanslack.github.io/Videomass/",
    "winget": "GianlucaPernigotto.Videomass",
    "foss": true
  },
  "WPFInstallvisualstudio": {
    "category": "Development",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community"
  },
  "WPFInstallvivaldi": {
    "category": "Browsers",
    "choco": "vivaldi",
    "content": "Vivaldi",
    "description": "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi"
  },
  "WPFInstallvlc": {
    "category": "Multimedia Tools",
    "choco": "vlc",
    "content": "VLC (Video Player)",
    "description": "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallvoicemeeter": {
    "category": "Multimedia Tools",
    "choco": "voicemeeter",
    "content": "Voicemeeter (Audio)",
    "description": "Voicemeeter is a virtual audio mixer that allows you to manage and enhance audio streams on your computer. It is commonly used for audio recording and streaming purposes.",
    "link": "https://voicemeeter.com/",
    "winget": "VB-Audio.Voicemeeter"
  },
  "WPFInstallVoicemeeterPotato": {
    "category": "Multimedia Tools",
    "choco": "voicemeeter-potato",
    "content": "Voicemeeter Potato",
    "description": "Voicemeeter Potato is the ultimate version of the Voicemeeter Audio Mixer Application endowed with Virtual Audio Device to mix and manage any audio sources from or to any audio devices or applications.",
    "link": "https://voicemeeter.com/",
    "winget": "VB-Audio.Voicemeeter.Potato"
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "Games",
    "choco": "na",
    "content": "Virtual Desktop Streamer",
    "description": "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer"
  },
  "WPFInstallvscode": {
    "category": "Development",
    "choco": "vscode",
    "content": "VS Code",
    "description": "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode",
    "foss": true
  },
  "WPFInstallvscodium": {
    "category": "Development",
    "choco": "vscodium",
    "content": "VS Codium",
    "description": "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft's VS Code.",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium",
    "foss": true
  },
  "WPFInstallwaterfox": {
    "category": "Browsers",
    "choco": "waterfox",
    "content": "Waterfox",
    "description": "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox",
    "foss": true
  },
  "WPFInstallwazuh": {
    "category": "Utilities",
    "choco": "wazuh-agent",
    "content": "Wazuh.",
    "description": "Wazuh is an open-source security monitoring platform that offers intrusion detection, compliance checks, and log analysis.",
    "link": "https://wazuh.com/",
    "winget": "Wazuh.WazuhAgent",
    "foss": true
  },
  "WPFInstallwezterm": {
    "category": "Development",
    "choco": "wezterm",
    "content": "Wezterm",
    "description": "WezTerm is a powerful cross-platform terminal emulator and multiplexer",
    "link": "https://wezfurlong.org/wezterm/index.html",
    "winget": "wez.wezterm",
    "foss": true
  },
  "WPFInstallwindowspchealth": {
    "category": "Utilities",
    "choco": "na",
    "content": "Windows PC Health Check",
    "description": "Windows PC Health Check is a tool that helps you check if your PC meets the system requirements for Windows 11.",
    "link": "https://support.microsoft.com/en-us/windows/how-to-use-the-pc-health-check-app-9c8abd9b-03ba-4e67-81ef-36f37caa7844",
    "winget": "Microsoft.WindowsPCHealthCheck"
  },
  "WPFInstallWindowGrid": {
    "category": "Utilities",
    "choco": "windowgrid",
    "content": "WindowGrid",
    "description": "WindowGrid is a modern window management program for Windows that allows the user to quickly and easily layout their windows on a dynamic grid using just the mouse.",
    "link": "http://windowgrid.net/",
    "winget": "na"
  },
  "WPFInstallwingetui": {
    "category": "Utilities",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "UniGetUI is a GUI for Winget, Chocolatey, and other Windows CLI package managers.",
    "link": "https://www.marticliment.com/wingetui/",
    "winget": "MartiCliment.UniGetUI",
    "foss": true
  },
  "WPFInstallwinmerge": {
    "category": "Document",
    "choco": "winmerge",
    "content": "WinMerge",
    "description": "WinMerge is a visual text file and directory comparison tool for Windows.",
    "link": "https://winmerge.org/",
    "winget": "WinMerge.WinMerge",
    "foss": true
  },
  "WPFInstallwinpaletter": {
    "category": "Utilities",
    "choco": "WinPaletter",
    "content": "WinPaletter",
    "description": "WinPaletter is a tool for adjusting the color palette of Windows 10, providing customization options for window colors.",
    "link": "https://github.com/Abdelrhman-AK/WinPaletter",
    "winget": "Abdelrhman-AK.WinPaletter",
    "foss": true
  },
  "WPFInstallwinrar": {
    "category": "Utilities",
    "choco": "winrar",
    "content": "WinRAR",
    "description": "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR"
  },
  "WPFInstallwinscp": {
    "category": "Pro Tools",
    "choco": "winscp",
    "content": "WinSCP",
    "description": "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP",
    "foss": true
  },
  "WPFInstallwireguard": {
    "category": "Pro Tools",
    "choco": "wireguard",
    "content": "WireGuard",
    "description": "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard",
    "foss": true
  },
  "WPFInstallwireshark": {
    "category": "Pro Tools",
    "choco": "wireshark",
    "content": "Wireshark",
    "description": "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark",
    "foss": true
  },
  "WPFInstallwisetoys": {
    "category": "Utilities",
    "choco": "na",
    "content": "WiseToys",
    "description": "WiseToys is a set of utilities and tools designed to enhance and optimize your Windows experience.",
    "link": "https://toys.wisecleaner.com/",
    "winget": "WiseCleaner.WiseToys"
  },
  "WPFInstallTeraCopy": {
    "category": "Utilities",
    "choco": "TeraCopy",
    "content": "TeraCopy",
    "description": "Copy your files faster and more securely",
    "link": "https://codesector.com/teracopy",
    "winget": "CodeSector.TeraCopy"
  },
  "WPFInstallwizfile": {
    "category": "Utilities",
    "choco": "na",
    "content": "WizFile",
    "description": "Find files by name on your hard drives almost instantly.",
    "link": "https://antibody-software.com/wizfile/",
    "winget": "AntibodySoftware.WizFile"
  },
  "WPFInstallwiztree": {
    "category": "Utilities",
    "choco": "wiztree",
    "content": "WizTree",
    "description": "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree"
  },
  "WPFInstallxdm": {
    "category": "Utilities",
    "choco": "xdm",
    "content": "Xtreme Download Manager",
    "description": "Xtreme Download Manager is an advanced download manager with support for various protocols and browsers.*Browser integration deprecated by google store. No official release.*",
    "link": "https://xtremedownloadmanager.com/",
    "winget": "subhra74.XtremeDownloadManager",
    "foss": true
  },
  "WPFInstallxeheditor": {
    "category": "Utilities",
    "choco": "HxD",
    "content": "HxD Hex Editor",
    "description": "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD"
  },
  "WPFInstallxemu": {
    "category": "Games",
    "choco": "na",
    "content": "XEMU",
    "description": "XEMU is an open-source Xbox emulator that allows you to play Xbox games on your PC, aiming for accuracy and compatibility.",
    "link": "https://xemu.app/",
    "winget": "xemu-project.xemu",
    "foss": true
  },
  "WPFInstallxnview": {
    "category": "Utilities",
    "choco": "xnview",
    "content": "XnView classic",
    "description": "XnView is an efficient image viewer, browser and converter for Windows.",
    "link": "https://www.xnview.com/en/xnview/",
    "winget": "XnSoft.XnView.Classic"
  },
  "WPFInstallxournal": {
    "category": "Document",
    "choco": "xournalplusplus",
    "content": "Xournal++",
    "description": "Xournal++ is an open-source handwriting notetaking software with PDF annotation capabilities.",
    "link": "https://xournalpp.github.io/",
    "winget": "Xournal++.Xournal++",
    "foss": true
  },
  "WPFInstallxpipe": {
    "category": "Pro Tools",
    "choco": "xpipe",
    "content": "XPipe",
    "description": "XPipe is an open-source tool for orchestrating containerized applications. It simplifies the deployment and management of containerized services in a distributed environment.",
    "link": "https://xpipe.io/",
    "winget": "xpipe-io.xpipe",
    "foss": true
  },
  "WPFInstallyarn": {
    "category": "Development",
    "choco": "yarn",
    "content": "Yarn",
    "description": "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn",
    "foss": true
  },
  "WPFInstallytdlp": {
    "category": "Multimedia Tools",
    "choco": "yt-dlp",
    "content": "Yt-dlp",
    "description": "Command-line tool that allows you to download videos from YouTube and other supported sites. It is an improved version of the popular youtube-dl.",
    "link": "https://github.com/yt-dlp/yt-dlp",
    "winget": "yt-dlp.yt-dlp",
    "foss": true
  },
  "WPFInstallzerotierone": {
    "category": "Utilities",
    "choco": "zerotier-one",
    "content": "ZeroTier One",
    "description": "ZeroTier One is a software-defined networking tool that allows you to create secure and scalable networks.",
    "link": "https://zerotier.com/",
    "winget": "ZeroTier.ZeroTierOne"
  },
  "WPFInstallzim": {
    "category": "Document",
    "choco": "zim",
    "content": "Zim Desktop Wiki",
    "description": "Zim Desktop Wiki is a graphical text editor used to maintain a collection of wiki pages.",
    "link": "https://zim-wiki.org/",
    "winget": "Zimwiki.Zim",
    "foss": true
  },
  "WPFInstallznote": {
    "category": "Document",
    "choco": "na",
    "content": "Znote",
    "description": "Znote is a note-taking application.",
    "link": "https://znote.io/",
    "winget": "alagrede.znote",
    "foss": true
  },
  "WPFInstallzoom": {
    "category": "Communications",
    "choco": "zoom",
    "content": "Zoom",
    "description": "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom"
  },
  "WPFInstallzoomit": {
    "category": "Utilities",
    "choco": "na",
    "content": "ZoomIt",
    "description": "A screen zoom, annotation, and recording tool for technical presentations and demos",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/zoomit",
    "winget": "Microsoft.Sysinternals.ZoomIt"
  },
  "WPFInstallzotero": {
    "category": "Document",
    "choco": "zotero",
    "content": "Zotero",
    "description": "Zotero is a free, easy-to-use tool to help you collect, organize, cite, and share your research materials.",
    "link": "https://www.zotero.org/",
    "winget": "DigitalScholar.Zotero",
    "foss": true
  },
  "WPFInstallzoxide": {
    "category": "Utilities",
    "choco": "zoxide",
    "content": "Zoxide",
    "description": "Zoxide is a fast and efficient directory changer (cd) that helps you navigate your file system with ease.",
    "link": "https://github.com/ajeetdsouza/zoxide",
    "winget": "ajeetdsouza.zoxide",
    "foss": true
  },
  "WPFInstallzulip": {
    "category": "Communications",
    "choco": "zulip",
    "content": "Zulip",
    "description": "Zulip is an open-source team collaboration tool with chat streams for productive and organized communication.",
    "link": "https://zulipchat.com/",
    "winget": "Zulip.Zulip",
    "foss": true
  },
  "WPFInstallsyncthingtray": {
    "category": "Utilities",
    "choco": "syncthingtray",
    "content": "Syncthingtray",
    "description": "Might be the alternative for Synctrayzor. Windows tray utility / filesystem watcher / launcher for Syncthing",
    "link": "https://github.com/Martchus/syncthingtray",
    "winget": "Martchus.syncthingtray",
    "foss": true
  },
  "WPFInstallminiconda": {
    "category": "Development",
    "choco": "miniconda3",
    "content": "Miniconda",
    "description": "Miniconda is a free minimal installer for conda. It is a small bootstrap version of Anaconda that includes only conda, Python, the packages they both depend on, and a small number of other useful packages (like pip, zlib, and a few others).",
    "link": "https://docs.conda.io/projects/miniconda",
    "winget": "Anaconda.Miniconda3",
    "foss": true
  },
  "WPFInstallpixi": {
    "category": "Development",
    "choco": "pixi",
    "content": "Pixi",
    "description": "Pixi is a fast software package manager built on top of the existing conda ecosystem. Spins up development environments quickly on Windows, macOS and Linux. Pixi supports Python, R, C/C++, Rust, Ruby, and many other languages.",
    "link": "https://pixi.sh",
    "winget": "prefix-dev.pixi",
    "foss": true
  },
  "WPFInstalltemurin": {
    "category": "Development",
    "choco": "temurin",
    "content": "Eclipse Temurin",
    "description": "Eclipse Temurin is the open source Java SE build based upon OpenJDK.",
    "link": "https://adoptium.net/temurin/",
    "winget": "EclipseAdoptium.Temurin.21.JDK",
    "foss": true
  },
  "WPFInstallintelpresentmon": {
    "category": "Utilities",
    "choco": "na",
    "content": "Intel-PresentMon",
    "description": "A new gaming performance overlay and telemetry application to monitor and measure your gaming experience.",
    "link": "https://game.intel.com/us/stories/intel-presentmon/",
    "winget": "Intel.PresentMon.Beta",
    "foss": true
  },
  "WPFInstallpyenvwin": {
    "category": "Development",
    "choco": "pyenv-win",
    "content": "Python Version Manager (pyenv-win)",
    "description": "pyenv for Windows is a simple python version management tool. It lets you easily switch between multiple versions of Python.",
    "link": "https://pyenv-win.github.io/pyenv-win/",
    "winget": "na",
    "foss": true
  },
  "WPFInstalltightvnc": {
    "category": "Utilities",
    "choco": "TightVNC",
    "content": "TightVNC",
    "description": "TightVNC is a free and Open Source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC",
    "foss": true
  },
  "WPFInstallultravnc": {
    "category": "Utilities",
    "choco": "ultravnc",
    "content": "UltraVNC",
    "description": "UltraVNC is a powerful, easy to use and free - remote pc access software - that can display the screen of another computer (via internet or network) on your own screen. The program allows you to use your mouse and keyboard to control the other PC remotely. It means that you can work on a remote computer, as if you were sitting in front of it, right from your current location.",
    "link": "https://uvnc.com/",
    "winget": "uvncbvba.UltraVnc",
    "foss": true
  },
  "WPFInstallwindowsfirewallcontrol": {
    "category": "Utilities",
    "choco": "windowsfirewallcontrol",
    "content": "Windows Firewall Control",
    "description": "Windows Firewall Control is a powerful tool which extends the functionality of Windows Firewall and provides new extra features which makes Windows Firewall better.",
    "link": "https://www.binisoft.org/wfc",
    "winget": "BiniSoft.WindowsFirewallControl"
  },
  "WPFInstallvistaswitcher": {
    "category": "Utilities",
    "choco": "na",
    "content": "VistaSwitcher",
    "description": "VistaSwitcher makes it easier for you to locate windows and switch focus, even on multi-monitor systems. The switcher window consists of an easy-to-read list of all tasks running with clearly shown titles and a full-sized preview of the selected task.",
    "link": "https://www.ntwind.com/freeware/vistaswitcher.html",
    "winget": "ntwind.VistaSwitcher"
  },
  "WPFInstallautodarkmode": {
    "category": "Utilities",
    "choco": "auto-dark-mode",
    "content": "Windows Auto Dark Mode",
    "description": "Automatically switches between the dark and light theme of Windows 10 and Windows 11",
    "link": "https://github.com/AutoDarkMode/Windows-Auto-Night-Mode",
    "winget": "Armin2208.WindowsAutoNightMode",
    "foss": true
  },
  "WPFInstallAmbieWhiteNoise": {
    "category": "Utilities",
    "choco": "na",
    "content": "Ambie White Noise",
    "description": "Ambie is the ultimate app to help you focus, study, or relax. We use white noise and nature sounds combined with an innovative focus timer to keep you concentrated on doing your best work.",
    "link": "https://ambieapp.com/",
    "winget": "9P07XNM5CHP0",
    "foss": true
  },
  "WPFInstallmagicwormhole": {
    "category": "Utilities",
    "choco": "magic-wormhole",
    "content": "Magic Wormhole",
    "description": "get things from one computer to another, safely",
    "link": "https://github.com/magic-wormhole/magic-wormhole",
    "winget": "magic-wormhole.magic-wormhole",
    "foss": true
  },
  "WPFInstallcroc": {
    "category": "Utilities",
    "choco": "croc",
    "content": "croc",
    "description": "Easily and securely send things from one computer to another.",
    "link": "https://github.com/schollz/croc",
    "winget": "schollz.croc",
    "foss": true
  },
  "WPFInstallqgis": {
    "category": "Multimedia Tools",
    "choco": "qgis",
    "content": "QGIS",
    "description": "QGIS (Quantum GIS) is an open-source Geographic Information System (GIS) software that enables users to create, edit, visualize, analyze, and publish geospatial information on Windows, Mac, and Linux platforms.",
    "link": "https://qgis.org/en/site/",
    "winget": "OSGeo.QGIS",
    "foss": true
  },
  "WPFInstallsmplayer": {
    "category": "Multimedia Tools",
    "choco": "smplayer",
    "content": "SMPlayer",
    "description": "SMPlayer is a free media player for Windows and Linux with built-in codecs that can play virtually all video and audio formats.",
    "link": "https://www.smplayer.info",
    "winget": "SMPlayer.SMPlayer",
    "foss": true
  },
  "WPFInstallglazewm": {
    "category": "Utilities",
    "choco": "na",
    "content": "GlazeWM",
    "description": "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm",
    "foss": true
  },
  "WPFInstallfancontrol": {
    "category": "Utilities",
    "choco": "na",
    "content": "FanControl",
    "description": "Fan Control is a free and open-source software that allows the user to control his CPU, GPU and case fans using temperatures.",
    "link": "https://getfancontrol.com/",
    "winget": "Rem0o.FanControl",
    "foss": true
  },
  "WPFInstallfnm": {
    "category": "Development",
    "choco": "fnm",
    "content": "Fast Node Manager",
    "description": "Fast Node Manager (fnm) allows you to switch your Node version by using the Terminal",
    "link": "https://github.com/Schniz/fnm",
    "winget": "Schniz.fnm",
    "foss": true
  },
  "WPFInstallWindhawk": {
    "category": "Utilities",
    "choco": "windhawk",
    "content": "Windhawk",
    "description": "The customization marketplace for Windows programs",
    "link": "https://windhawk.net",
    "winget": "RamenSoftware.Windhawk"
  },
  "WPFInstallForceAutoHDR": {
    "category": "Utilities",
    "choco": "na",
    "content": "ForceAutoHDR",
    "description": "ForceAutoHDR simplifies the process of adding games to the AutoHDR list in the Windows Registry",
    "link": "https://github.com/7gxycn08/ForceAutoHDR",
    "winget": "ForceAutoHDR.7gxycn08",
    "foss": true
  },
  "WPFInstallJoyToKey": {
    "category": "Utilities",
    "choco": "joytokey",
    "content": "JoyToKey",
    "description": "enables PC game controllers to emulate the keyboard and mouse input",
    "link": "https://joytokey.net/en/",
    "winget": "JTKsoftware.JoyToKey"
  },
  "WPFInstallnditools": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "NDI Tools",
    "description": "NDI, or Network Device Interface, is a video connectivity standard that enables multimedia systems to identify and communicate with one another over IP and to encode, transmit, and receive high-quality, low latency, frame-accurate video and audio, and exchange metadata in real-time.",
    "link": "https://ndi.video/",
    "winget": "NDI.NDITools"
  },
  "WPFInstallkicad": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Kicad",
    "description": "Kicad is an open-source EDA tool. It's a good starting point for those who want to do electrical design and is even used by professionals in the industry.",
    "link": "https://www.kicad.org/",
    "winget": "KiCad.KiCad",
    "foss": true
  },
  "WPFInstalldropox": {
    "category": "Utilities",
    "choco": "na",
    "content": "Dropbox",
    "description": "The Dropbox desktop app! Save hard drive space, share and edit files and send for signature ? all without the distraction of countless browser tabs.",
    "link": "https://www.dropbox.com/en_GB/desktop",
    "winget": "Dropbox.Dropbox"
  },
  "WPFInstallOFGB": {
    "category": "Utilities",
    "choco": "ofgb",
    "content": "OFGB (Oh Frick Go Back)",
    "description": "GUI Tool to remove ads from various places around Windows 11",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB",
    "foss": true
  },
  "WPFInstallPaleMoon": {
    "category": "Browsers",
    "choco": "paleMoon",
    "content": "PaleMoon",
    "description": "Pale Moon is an Open Source, Goanna-based web browser available for Microsoft Windows and Linux (with other operating systems in development), focusing on efficiency and ease of use.",
    "link": "https://www.palemoon.org/download.shtml",
    "winget": "MoonchildProductions.PaleMoon",
    "foss": true
  },
  "WPFInstallShotcut": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Shotcut",
    "description": "Shotcut is a free, open source, cross-platform video editor.",
    "link": "https://shotcut.org/",
    "winget": "Meltytech.Shotcut",
    "foss": true
  },
  "WPFInstallLenovoLegionToolkit": {
    "category": "Utilities",
    "choco": "na",
    "content": "Lenovo Legion Toolkit",
    "description": "Lenovo Legion Toolkit (LLT) is a open-source utility created for Lenovo Legion (and similar) series laptops, that allows changing a couple of features that are only available in Lenovo Vantage or Legion Zone. It runs no background services, uses less memory, uses virtually no CPU, and contains no telemetry. Just like Lenovo Vantage, this application is Windows only.",
    "link": "https://github.com/BartoszCichecki/LenovoLegionToolkit",
    "winget": "BartoszCichecki.LenovoLegionToolkit",
    "foss": true
  },
  "WPFInstallPulsarEdit": {
    "category": "Development",
    "choco": "pulsar",
    "content": "Pulsar",
    "description": "A Community-led Hyper-Hackable Text Editor",
    "link": "https://pulsar-edit.dev/",
    "winget": "Pulsar-Edit.Pulsar",
    "foss": true
  },
  "WPFInstallAegisub": {
    "category": "Development",
    "choco": "aegisub",
    "content": "Aegisub",
    "description": "Aegisub is a free, cross-platform open source tool for creating and modifying subtitles. Aegisub makes it quick and easy to time subtitles to audio, and features many powerful tools for styling them, including a built-in real-time video preview.",
    "link": "https://github.com/Aegisub/Aegisub",
    "winget": "Aegisub.Aegisub",
    "foss": true
  },
  "WPFInstallSubtitleEdit": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Subtitle Edit",
    "description": "Subtitle Edit is a free and open source editor for video subtitles.",
    "link": "https://github.com/SubtitleEdit/subtitleedit",
    "winget": "Nikse.SubtitleEdit",
    "foss": true
  },
  "WPFInstallFork": {
    "category": "Development",
    "choco": "git-fork",
    "content": "Fork",
    "description": "Fork - a fast and friendly git client.",
    "link": "https://git-fork.com/",
    "winget": "Fork.Fork"
  },
  "WPFInstallZenBrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Zen Browser",
    "description": "The modern, privacy-focused, performance-driven browser built on Firefox",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser",
    "foss": true
  },
  "WPFInstallZed": {
    "category": "Development",
    "choco": "na",
    "content": "Zed",
    "description": "Zed is a modern, high-performance code editor designed from the ground up for speed and collaboration.",
    "link": "https://zed.dev/",
    "winget": "ZedIndustries.Zed",
    "foss": true
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "Install/Upgrade Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "1",
    "Description": "Install or upgrade the selected applications"
  },
  "WPFUninstall": {
    "Content": "Uninstall Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "2",
    "Description": "Uninstall the selected applications"
  },
  "WPFInstallUpgrade": {
    "Content": "Upgrade all Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "3",
    "Description": "Upgrade all applications to the latest version"
  },
  "WingetRadioButton": {
    "Content": "Winget",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "Use Winget for package management"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "Use Chocolatey for package management"
  },
  "WPFCollapseAllCategories": {
    "Content": "Collapse All Categories",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "1",
    "Description": "Collapse all application categories"
  },
  "WPFExpandAllCategories": {
    "Content": "Expand All Categories",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "2",
    "Description": "Expand all application categories"
  },
  "WPFClearInstallSelection": {
    "Content": "Clear Selection",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "3",
    "Description": "Clear the selection of applications"
  },
  "WPFGetInstalled": {
    "Content": "Show Installed Apps",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "4",
    "Description": "Show installed applications"
  },
  "WPFselectedAppsButton": {
    "Content": "Selected Apps: 0",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "5",
    "Description": "Show the selected applications"
  },
  "WPFToggleFOSSHighlight": {
    "Content": "Highlight FOSS",
    "Category": "__Selection",
    "Type": "Toggle",
    "Checked": true,
    "Order": "6",
    "Description": "Toggle the green highlight for FOSS applications"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": "All .Net Framework (2,3,4)",
    "Description": ".NET and .NET Framework is a developer platform made up of tools, programming languages, and libraries for building many different types of applications.",
    "category": "Features",
    "panel": "1",
    "Order": "a010_",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/dotnet"
  },
  "WPFFeatureshyperv": {
    "Content": "HyperV Virtualization",
    "Description": "Hyper-V is a hardware virtualization product developed by Microsoft that allows users to create and manage virtual machines.",
    "category": "Features",
    "panel": "1",
    "Order": "a011_",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "InvokeScript": [
      "bcdedit /set hypervisorschedulertype classic"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "Legacy Media (WMP, DirectPlay)",
    "Description": "Enables legacy programs from previous versions of windows",
    "category": "Features",
    "panel": "1",
    "Order": "a012_",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "Windows Subsystem for Linux",
    "Description": "Windows Subsystem for Linux is an optional feature of Windows that allows Linux programs to run natively on Windows without the need for a separate virtual machine or dual booting.",
    "category": "Features",
    "panel": "1",
    "Order": "a020_",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "NFS - Network File System",
    "Description": "Network File System (NFS) is a mechanism for storing files on a network.",
    "category": "Features",
    "panel": "1",
    "Order": "a014_",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/nfs"
  },
  "WPFFeatureRegBackup": {
    "Content": "Enable Daily Registry Backup Task 12.30am",
    "Description": "Enables daily registry backup, previously disabled by Microsoft in Windows 10 1803.",
    "category": "Features",
    "panel": "1",
    "Order": "a017_",
    "feature": [],
    "InvokeScript": [
      "\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/features/features/regbackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "Enable Legacy F8 Boot Recovery",
    "Description": "Enables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "Order": "a018_",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/enablelegacyrecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "Disable Legacy F8 Boot Recovery",
    "Description": "Disables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "Order": "a019_",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/disablelegacyrecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "Windows Sandbox",
    "Description": "Windows Sandbox is a lightweight virtual machine that provides a temporary desktop environment to safely run applications and programs in isolation.",
    "category": "Features",
    "panel": "1",
    "Order": "a021_",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "Install Features",
    "category": "Features",
    "panel": "1",
    "Order": "a060_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/features/install"
  },
  "WPFPanelAutologin": {
    "Content": "Set Up Autologin",
    "category": "Fixes",
    "Order": "a040_",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/fixes/autologin"
  },
  "WPFFixesUpdate": {
    "Content": "Reset Windows Update",
    "category": "Fixes",
    "panel": "1",
    "Order": "a041_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/fixes/update"
  },
  "WPFFixesNetwork": {
    "Content": "Reset Network",
    "category": "Fixes",
    "Order": "a042_",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/fixes/network"
  },
  "WPFPanelDISM": {
    "Content": "System Corruption Scan",
    "category": "Fixes",
    "panel": "1",
    "Order": "a043_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/fixes/dism"
  },
  "WPFFixesWinget": {
    "Content": "WinGet Reinstall",
    "category": "Fixes",
    "panel": "1",
    "Order": "a044_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/fixes/winget"
  },
  "WPFPanelControl": {
    "Content": "Control Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/control"
  },
  "WPFPanelComputer": {
    "Content": "Computer Management",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/computer"
  },
  "WPFPanelNetwork": {
    "Content": "Network Connections",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/network"
  },
  "WPFPanelPower": {
    "Content": "Power Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/power"
  },
  "WPFPanelPrinter": {
    "Content": "Printer Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/printer"
  },
  "WPFPanelRegion": {
    "Content": "Region",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/region"
  },
  "WPFPanelRestore": {
    "Content": "Windows Restore",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/restore"
  },
  "WPFPanelSound": {
    "Content": "Sound Settings",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/sound"
  },
  "WPFPanelSystem": {
    "Content": "System Properties",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/system"
  },
  "WPFPanelTimedate": {
    "Content": "Time and Date",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/timedate"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "Install CTT PowerShell Profile",
    "category": "Powershell Profile Powershell 7+ Only",
    "panel": "2",
    "Order": "a083_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/powershell-profile-powershell-7--only/installpsprofile"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "Uninstall CTT PowerShell Profile",
    "category": "Powershell Profile Powershell 7+ Only",
    "panel": "2",
    "Order": "a084_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/powershell-profile-powershell-7--only/uninstallpsprofile"
  },
  "WPFWinUtilSSHServer": {
    "Content": "Enable OpenSSH Server",
    "category": "Remote Access",
    "panel": "2",
    "Order": "a084_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/features/remote-access/sshserver"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksDVR",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint",
    "WPFTweaksPowershell7Tele"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "200",
    "AppEntryFontSize": "11",
    "AppEntryMargin": "1,0,1,0",
    "AppEntryBorderThickness": "0",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "18",
    "GroupBorderBackgroundColor": "#232629",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F7F7F7",
    "AppInstallHighlightedColor": "#CFCFCF",
    "AppInstallSelectedColor": "#C2C2C2",
    "AppInstallOverlayBackgroundColor": "#6A6D72",
    "ComboBoxForegroundColor": "#232629",
    "ComboBoxBackgroundColor": "#F7F7F7",
    "LabelboxForegroundColor": "#232629",
    "MainForegroundColor": "#232629",
    "MainBackgroundColor": "#F7F7F7",
    "LabelBackgroundColor": "#F7F7F7",
    "LinkForegroundColor": "#484848",
    "LinkHoverForegroundColor": "#232629",
    "ScrollBarBackgroundColor": "#4A4D52",
    "ScrollBarHoverColor": "#5A5D62",
    "ScrollBarDraggingColor": "#6A6D72",
    "ProgressBarForegroundColor": "#2e77ff",
    "ProgressBarBackgroundColor": "Transparent",
    "ProgressBarTextColor": "#232629",
    "ButtonInstallBackgroundColor": "#F7F7F7",
    "ButtonTweaksBackgroundColor": "#F7F7F7",
    "ButtonConfigBackgroundColor": "#F7F7F7",
    "ButtonUpdatesBackgroundColor": "#F7F7F7",
    "ButtonInstallForegroundColor": "#232629",
    "ButtonTweaksForegroundColor": "#232629",
    "ButtonConfigForegroundColor": "#232629",
    "ButtonUpdatesForegroundColor": "#232629",
    "ButtonBackgroundColor": "#F5F5F5",
    "ButtonBackgroundPressedColor": "#1A1A1A",
    "ButtonBackgroundMouseoverColor": "#C2C2C2",
    "ButtonBackgroundSelectedColor": "#F0F0F0",
    "ButtonForegroundColor": "#232629",
    "ToggleButtonOnColor": "#2e77ff",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#F7F7F7",
    "BorderColor": "#232629",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#232629",
    "AppInstallHighlightedColor": "#3C3C3C",
    "AppInstallSelectedColor": "#4C4C4C",
    "AppInstallOverlayBackgroundColor": "#2E3135",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#1E3747",
    "LabelboxForegroundColor": "#5bdcff",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#232629",
    "LabelBackgroundColor": "#232629",
    "LinkForegroundColor": "#add8e6",
    "LinkHoverForegroundColor": "#F7F7F7",
    "ScrollBarBackgroundColor": "#2E3135",
    "ScrollBarHoverColor": "#3B4252",
    "ScrollBarDraggingColor": "#5E81AC",
    "ProgressBarForegroundColor": "#222222",
    "ProgressBarBackgroundColor": "Transparent",
    "ProgressBarTextColor": "#232629",
    "ButtonInstallBackgroundColor": "#222222",
    "ButtonTweaksBackgroundColor": "#333333",
    "ButtonConfigBackgroundColor": "#444444",
    "ButtonUpdatesBackgroundColor": "#555555",
    "ButtonInstallForegroundColor": "#F7F7F7",
    "ButtonTweaksForegroundColor": "#F7F7F7",
    "ButtonConfigForegroundColor": "#F7F7F7",
    "ButtonUpdatesForegroundColor": "#F7F7F7",
    "ButtonBackgroundColor": "#1E3747",
    "ButtonBackgroundPressedColor": "#F7F7F7",
    "ButtonBackgroundMouseoverColor": "#3B4252",
    "ButtonBackgroundSelectedColor": "#5E81AC",
    "ButtonForegroundColor": "#F7F7F7",
    "ToggleButtonOnColor": "#2e77ff",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#2F373D",
    "BorderColor": "#2F373D",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "Disable Activity History",
    "Description": "This erases recent docs, clipboard, and run history.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/activity"
  },
  "WPFTweaksHiber": {
    "Content": "Disable Hibernation",
    "Description": "Hibernation is really meant for laptops as it saves what's in memory before turning the pc off. It really should never be used",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/hiber"
  },
  "WPFTweaksWidget": {
    "Content": "Remove Widgets",
    "Description": "Removes the annoying widgets in the bottom left of the taskbar",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Stop-Process -Name Widgets\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Restoring widgets AppxPackages\"\r\n\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\Microsoft.WidgetsPlatformRuntime*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\MicrosoftWindows.Client.WebExperience*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/widget"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "Revert the new start menu",
    "Description": "Uses vivetool to revert the the original start menu from 24h2",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process 'ViVeTool\\ViVeTool.exe' -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host 'Old start menu reverted please restart your computer to take effect'\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process 'ViVeTool\\ViVeTool.exe' -ArgumentList '/enable /id:47205210' -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host 'New start menu reverted please restart your computer to take effect'\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/revertstartmenu"
  },
  "WPFTweaksLocation": {
    "Content": "Disable Location Tracking",
    "Description": "Disables Location Tracking...DUH!",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\lfsvc\\Service\\Configuration",
        "Name": "Status",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/location"
  },
  "WPFTweaksServices": {
    "Content": "Set Services to Manual",
    "Description": "Turns a bunch of system services to manual that don't need to be running all the time. This is pretty harmless as if the service is needed, it will simply start on demand.",
    "category": "Essential Tweaks",
    "panel": "1",
    "service": [
      {
        "Name": "ALG",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppMgmt",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppReadiness",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppVClient",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "Appinfo",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AssignedAccessManagerSvc",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "AudioEndpointBuilder",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AudioSrv",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Audiosrv",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AxInstSV",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BDESVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BITS",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "BTAGService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BthAvctpSvc",
        "StartupType": "Automatic",
        "OriginalType": "Manual"
      },
      {
        "Name": "CDPSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "COMSysApp",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "CertPropSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "CryptSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CscService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DPS",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DevQueryBroker",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DeviceAssociationService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DeviceInstall",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Dhcp",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DialogBlockingService",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "DispBrokerDesktopSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DisplayEnhancementService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "EFS",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "EapHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "EventLog",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "EventSystem",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "FDResPub",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "FontCache",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "FrameServer",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "FrameServerMonitor",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "GraphicsPerfSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "HvHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "IKEEXT",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "InstallService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "InventorySvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "IpxlatCfgSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "KeyIso",
        "StartupType": "Automatic",
        "OriginalType": "Manual"
      },
      {
        "Name": "KtmRm",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "LanmanServer",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "LanmanWorkstation",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "LicenseManager",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "LxpSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MSDTC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MSiSCSI",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "McpManagementService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MicrosoftEdgeElevationService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NaturalAuthentication",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NcaSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NcbService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NcdAutoSetup",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NetSetupSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NetTcpPortSharing",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "Netman",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NlaSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PcaSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "PeerDistSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PerfHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PhoneSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PlugPlay",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PolicyAgent",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Power",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "PrintNotify",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ProfSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "PushToInstall",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "QWAVE",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RasAuto",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RasMan",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RemoteAccess",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "RemoteRegistry",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "RetailDemo",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RmSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RpcLocator",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SCPolicySvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SCardSvr",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SDRSVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SEMgrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SENS",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SNMPTRAP",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SNMPTrap",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SSDPSRV",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SamSs",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "ScDeviceEnum",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SensorDataService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SensorService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SensrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SessionEnv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ShellHWDetection",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SmsRouter",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Spooler",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SstpSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "StiSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SysMain",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "TapiSrv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TermService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Themes",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "TieringEngineService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TokenBroker",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TrkWks",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "TroubleshootingSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TrustedInstaller",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UevAgentService",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "UmRdpService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UserManager",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "UsoSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "VSS",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "VaultSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "W32Time",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WEPHOSTSVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WFDSConMgrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WMPNetworkSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WManSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WPDBusEnum",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WSAIFabricSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WSearch",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WalletService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WarpJITSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WbioSrvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Wcmsvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WdiServiceHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WdiSystemHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WebClient",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Wecsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WerSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WiaRpc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WinRM",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Winmgmt",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WpcMonSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WpnService",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "XblAuthManager",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "XblGameSave",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "XboxGipSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "XboxNetApiSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "autotimesvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "bthserv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "camsvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "cloudidsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "dcsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "defragsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "diagsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "dmwappushservice",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "dot3svc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "edgeupdate",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "edgeupdatem",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "fdPHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "fhsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "hidserv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "icssvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "iphlpsvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "lfsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "lltdsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "lmhosts",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "netprofm",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "nsi",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "perceptionsimulation",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "pla",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "seclogon",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "shpamsvc",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "smphost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ssh-agent",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "svsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "swprv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "tzautoupdate",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "upnphost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vds",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicguestinterface",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicheartbeat",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmickvpexchange",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicrdv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicshutdown",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmictimesync",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicvmsession",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicvss",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wbengine",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wcncsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "webthreatdefsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wercplsupport",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wisvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wlidsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wlpasvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wmiApSrv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "workfolderssvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wuauserv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/services"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Brave Debloat",
    "Description": "Disables various annoyances like Brave Rewards,Leo AI,Crypto Wallet and VPN",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/bravedebloat"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Edge Debloat",
    "Description": "Disables various telemetry options, popups, and other annoyances in Edge.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/edgedebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "Disable ConsumerFeatures",
    "Description": "Windows will not automatically install any games, third-party apps, or application links from the Windows Store for the signed-in user. Some default Apps will be inaccessible (eg. Phone Link)",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/consumerfeatures"
  },
  "WPFTweaksTelemetry": {
    "Content": "Disable Telemetry",
    "Description": "Disables Microsoft Telemetry...Duh",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/telemetry"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Remove Microsoft Edge",
    "Description": "Unblocks Microsoft Edge uninstaller restrictions than uses that uninstaller to remove Microsoft Edge",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "Invoke-WinUtilRemoveEdge"
    ],
    "UndoScript": [
      "\r\n      Write-Host 'Installing Microsoft Edge...'\r\n      winget install Microsoft.Edge --source winget\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removeedge"
  },
  "WPFTweaksUTC": {
    "Content": "Set Time to UTC (Dual Boot)",
    "Description": "Essential for computers that are dual booting. Fixes the time sync with Linux Systems.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/utc"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "Remove OneDrive",
    "Description": "Denys permission to remove onedrive user files than uses its own uninstaller to remove it than brings back permissions",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process 'C:\\Windows\\System32\\OneDriveSetup.exe' -ArgumentList '/uninstall' -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"C:\\ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to accses OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Enabled\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removeonedrive"
  },
  "WPFTweaksRemoveHome": {
    "Content": "Remove Home from Explorer",
    "Description": "Removes the Home from Explorer and sets This PC as default",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Remove-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\"\r\n      Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" -Name LaunchTo -Value 1\r\n      "
    ],
    "UndoScript": [
      "\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\"\r\n      Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" -Name LaunchTo -Value 0\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removehome"
  },
  "WPFTweaksRemoveGallery": {
    "Content": "Remove Gallery from explorer",
    "Description": "Removes the Gallery from Explorer and sets This PC as default",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Remove-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removegallery"
  },
  "WPFTweaksDisplay": {
    "Content": "Set Display for Performance",
    "Description": "Sets the system preferences to performance. You can do this manually with sysdm.cpl as well.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/display"
  },
  "WPFTweaksXboxRemoval": {
    "Content": "Remove Xbox & Gaming Components",
    "Description": "Removes Xbox services, the Xbox app, Game Bar, and related authentication components.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "appx": [
      "Microsoft.XboxIdentityProvider",
      "Microsoft.XboxSpeechToTextOverlay",
      "Microsoft.GamingApp",
      "Microsoft.Xbox.TCUI",
      "Microsoft.XboxGamingOverlay"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/xboxremoval"
  },
  "WPFTweaksDeBloat": {
    "Content": "Remove ALL MS Store Apps - NOT RECOMMENDED",
    "Description": "USE WITH CAUTION!!! This will remove ALL Microsoft store apps.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "appx": [
      "Microsoft.Microsoft3DViewer",
      "Microsoft.AppConnector",
      "Microsoft.BingFinance",
      "Microsoft.BingNews",
      "Microsoft.BingSports",
      "Microsoft.BingTranslator",
      "Microsoft.BingWeather",
      "Microsoft.BingFoodAndDrink",
      "Microsoft.BingHealthAndFitness",
      "Microsoft.BingTravel",
      "Clipchamp.Clipchamp",
      "Microsoft.Todos",
      "MicrosoftCorporationII.QuickAssist",
      "Microsoft.MicrosoftStickyNotes",
      "Microsoft.GetHelp",
      "Microsoft.GetStarted",
      "Microsoft.Messaging",
      "Microsoft.MicrosoftSolitaireCollection",
      "Microsoft.NetworkSpeedTest",
      "Microsoft.News",
      "Microsoft.Office.Lens",
      "Microsoft.Office.Sway",
      "Microsoft.Office.OneNote",
      "Microsoft.OneConnect",
      "Microsoft.People",
      "Microsoft.Print3D",
      "Microsoft.SkypeApp",
      "Microsoft.Wallet",
      "Microsoft.Whiteboard",
      "Microsoft.WindowsAlarms",
      "Microsoft.WindowsCommunicationsApps",
      "Microsoft.WindowsFeedbackHub",
      "Microsoft.WindowsMaps",
      "Microsoft.WindowsSoundRecorder",
      "Microsoft.ConnectivityStore",
      "Microsoft.ScreenSketch",
      "Microsoft.MixedReality.Portal",
      "Microsoft.ZuneMusic",
      "Microsoft.ZuneVideo",
      "Microsoft.MicrosoftOfficeHub",
      "MsTeams",
      "*EclipseManager*",
      "*ActiproSoftwareLLC*",
      "*AdobeSystemsIncorporated.AdobePhotoshopExpress*",
      "*Duolingo-LearnLanguagesforFree*",
      "*PandoraMediaInc*",
      "*CandyCrush*",
      "*BubbleWitch3Saga*",
      "*Wunderlist*",
      "*Flipboard*",
      "*Twitter*",
      "*Facebook*",
      "*Royal Revolt*",
      "*Sway*",
      "*Speed Test*",
      "*Dolby*",
      "*Viber*",
      "*ACGMediaPlayer*",
      "*Netflix*",
      "*OneCalendar*",
      "*LinkedInForWindows*",
      "*HiddenCityMysteryofShadows*",
      "*Hulu*",
      "*HiddenCity*",
      "*AdobePhotoshopExpress*",
      "*HotspotShieldFreeVPN*",
      "*Microsoft.Advertising.Xaml*"
    ],
    "InvokeScript": [
      "\r\n      $TeamsPath = \"$Env:LocalAppData\\Microsoft\\Teams\\Update.exe\"\r\n\r\n      if (Test-Path $TeamsPath) {\r\n        Write-Host \"Uninstalling Teams\"\r\n        Start-Process $TeamsPath -ArgumentList -uninstall -wait\r\n\r\n        Write-Host \"Deleting Teams directory\"\r\n        Remove-Item $TeamsPath -Recurse -Force\r\n      }\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/debloat"
  },
  "WPFTweaksRestorePoint": {
    "Content": "Create Restore Point",
    "Description": "Creates a restore point at runtime in case a revert is needed from WinUtil modifications",
    "category": "Essential Tweaks",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/restorepoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "Enable End Task With Right Click",
    "Description": "Enables option to end task when right clicking a program in the taskbar",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/endtaskontaskbar"
  },
  "WPFTweaksPowershell7Tele": {
    "Content": "Disable Powershell 7 Telemetry",
    "Description": "This will create an Environment Variable called 'POWERSHELL_TELEMETRY_OPTOUT' with a value of '1' which will tell Powershell 7 to not send Telemetry Data.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "[Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')"
    ],
    "UndoScript": [
      "[Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/powershell7tele"
  },
  "WPFTweaksStorage": {
    "Content": "Disable Storage Sense",
    "Description": "Storage Sense deletes temp files automatically.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/storage"
  },
  "WPFTweaksRemoveCopilot": {
    "Content": "Disable Microsoft Copilot",
    "Description": "Disables MS Copilot AI built into Windows since 23H2.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot",
        "Name": "TurnOffWindowsCopilot",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot",
        "Name": "TurnOffWindowsCopilot",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowCopilotButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Shell\\Copilot",
        "Name": "IsCopilotAvailable",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Shell\\Copilot",
        "Name": "CopilotDisabledReason",
        "Value": "IsEnabledForGeographicRegionFailed",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsCopilot",
        "Name": "AllowCopilotRuntime",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Shell Extensions\\Blocked",
        "Name": "{CB3B0003-8088-4EDE-8769-8B354AB2FF8C}",
        "Value": "",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Shell\\Copilot\\BingChat",
        "Name": "IsUserEligible",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      Write-Host \"Remove Copilot\"\r\n      Get-AppxPackage -AllUsers *Copilot* | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n      Remove-AppxPackage $Appx\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Install Copilot\"\r\n      winget install --name Copilot --source msstore --accept-package-agreements --accept-source-agreements --silent\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removecopilot"
  },
  "WPFTweaksWPBT": {
    "Content": "Disable Windows Platform Binary Table (WPBT)",
    "Description": "If enabled then allows your computer vendor to execute a program each time it boots. It enables computer vendors to force install anti-theft software, software drivers, or a software program conveniently. This could also be a security risk.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/wpbt"
  },
  "WPFTweaksRazerBlock": {
    "Content": "Block Razer Software Installs",
    "Description": "Blocks ALL Razer Software installations. The hardware works fine without any software. WARNING: this will also block all Windows third-party driver installations.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "\r\n      $RazerPath = \"C:\\Windows\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      }\r\n      else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      icacls \"C:\\Windows\\Installer\\Razer\" /remove:d Everyone\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/razerblock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "Disable Notification Tray/Calendar",
    "Description": "Disables all Notifications INCLUDING Calendar",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablenotifications"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Adobe Network Block",
    "Description": "Reduce user interruptions by selectively blocking connections to Adobe's activation and telemetry servers. Credit: Ruddernation-Designs",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $hostsUrl = \"https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\"\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Move-Item $hosts \"$hosts.bak\"\r\n      Invoke-WebRequest $hostsUrl -OutFile $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Added Adobe url block list from host file\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Remove-Item $hosts\r\n      Move-Item \"$hosts.bak\" $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Removed Adobe url block list from host file\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/blockadobenet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "Set Classic Right-Click Menu ",
    "Description": "Great Windows 11 tweak to bring back good context menus when right clicking things in explorer.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name \"InprocServer32\" -force -value \"\"\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
    ],
    "UndoScript": [
      "\r\n      Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse -Confirm:$false -Force\r\n      # Restarting Explorer in the Undo Script might not be necessary, as the Registry change without restarting Explorer does work, but just to make sure.\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/rightclickmenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "Run Disk Cleanup",
    "Description": "Runs Disk Cleanup on Drive C: and removes old Windows Updates.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/diskcleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "Delete Temporary Files",
    "Description": "Erases TEMP Folders",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/deletetempfiles"
  },
  "WPFTweaksIPv46": {
    "Content": "Prefer IPv4 over IPv6",
    "Description": "To set the IPv4 preference can have latency and security benefits on private networks where IPv6 is not configured.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/ipv46"
  },
  "WPFTweaksTeredo": {
    "Content": "Disable Teredo",
    "Description": "Teredo network tunneling is a ipv6 feature that can cause additional latency, but may cause problems with some games",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/teredo"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "Disable IPv6",
    "Description": "Disables IPv6.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disableipv6"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "Disable Background Apps",
    "Description": "Disables all Microsoft Store apps from running in the background, which has to be done individually since Win11",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablebgapps"
  },
  "WPFTweaksDisableFSO": {
    "Content": "Disable Fullscreen Optimizations",
    "Description": "Disables FSO in all applications. NOTE: This will disable Color Management in Exclusive Fullscreen",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_DXGIHonorFSEWindowsCompatible",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablefso"
  },
  "WPFToggleDarkMode": {
    "Content": "Dark Theme for Windows",
    "Description": "Enable/Disable Dark Mode.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/darkmode"
  },
  "WPFToggleBingSearch": {
    "Content": "Bing Search in Start Menu",
    "Description": "If enable then includes web search results from Bing in your Start Menu search.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/bingsearch"
  },
  "WPFToggleNumLock": {
    "Content": "NumLock on Startup",
    "Description": "Toggle the Num Lock key state when your computer starts.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/numlock"
  },
  "WPFToggleVerboseLogon": {
    "Content": "Verbose Messages During Logon",
    "Description": "Show detailed messages during the login process for troubleshooting and diagnostics.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/verboselogon"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "Recommendations in Start Menu",
    "Description": "If disabled then you will not see recommendations in the Start Menu.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/startmenurecommendations"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "Remove Settings Home Page",
    "Description": "Removes the Home page in the Windows Settings app.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:home",
        "Type": "String",
        "OriginalValue": "show:home",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/hidesettingshome"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "Mouse Acceleration",
    "Description": "If Enabled then Cursor movement is affected by the speed of your physical mouse movements.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/mouseacceleration"
  },
  "WPFToggleStickyKeys": {
    "Content": "Sticky Keys",
    "Description": "If Enabled then Sticky Keys is activated - Sticky keys is an accessibility feature of some graphical user interfaces which assists users who have physical disabilities or help users reduce repetitive strain injury.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/stickykeys"
  },
  "WPFToggleNewOutlook": {
    "Content": "New Outlook",
    "Description": "If disabled it removes the toggle for new Outlook, disables the new Outlook migration and makes sure the Outlook Application actually uses the old Outlook.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/newoutlook"
  },
  "WPFToggleMultiplaneOverlay": {
    "Content": "Disable Multiplane Overlay",
    "Description": "Disable the Multiplane Overlay which can sometimes cause issues with Graphics Cards.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Value": "5",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/multiplaneoverlay"
  },
  "WPFToggleHiddenFiles": {
    "Content": "Show Hidden Files",
    "Description": "If Enabled then Hidden Files will be shown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/hiddenfiles"
  },
  "WPFToggleShowExt": {
    "Content": "Show File Extensions",
    "Description": "If enabled then File extensions (e.g., .txt, .jpg) are visible.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/showext"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "Search Button in Taskbar",
    "Description": "If Enabled Search Button will be on the taskbar.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskbarsearch"
  },
  "WPFToggleTaskView": {
    "Content": "Task View Button in Taskbar",
    "Description": "If Enabled then Task View Button in Taskbar will be shown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskview"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "Center Taskbar Items",
    "Description": "[Windows 11] If Enabled then the Taskbar Items will be shown on the Center, otherwise the Taskbar Items will be shown on the Left.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskbaralignment"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "Detailed BSoD",
    "Description": "If Enabled then you will see a detailed Blue Screen of Death (BSOD) with more information.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/detailedbsod"
  },
  "WPFToggleS3Sleep": {
    "Content": "S3 Sleep",
    "Description": "Toggles between Modern Standby and S3 sleep.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/s3sleep"
  },
  "WPFOOSUbutton": {
    "Content": "Run OO Shutup 10",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Type": "Button",
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/oosubutton"
  },
  "WPFchangedns": {
    "Content": "DNS",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "Add and Activate Ultimate Performance Profile",
    "category": "Performance Plans",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/tweaks/performance-plans/addultperf"
  },
  "WPFRemoveUltPerf": {
    "Content": "Remove Ultimate Performance Profile",
    "category": "Performance Plans",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/tweaks/performance-plans/removeultperf"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "Disable Explorer Automatic Folder Discovery",
    "Description": "Windows Explorer automatically tries to guess the type of the folder based on its contents, slowing down the browsing experience.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disableexplorerautodiscovery"
  },
  "WPFToggleDisableCrossDeviceResume": {
    "Content": "Cross-Device Resume",
    "Description": "This tweak controls the Resume function in Windows 11 24H2 and later, which allows you to resume an activity from a mobile device and vice-versa.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\CrossDeviceResume\\Configuration",
        "Name": "IsResumeAllowed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/disablecrossdeviceresume"
  }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window x:Class="WinUtility.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        mc:Ignorable="d"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="None"
        Width="Auto"
        Height="Auto"
        MinWidth="800"
        MinHeight="600"
        Title="WinUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid x:Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border x:Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="2"/>
        <Setter Property="Padding" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <StackPanel Orientation="Horizontal">
                        <Grid Width="16" Height="16" Margin="0,0,8,0">
                            <Border x:Name="CheckBoxBorder"
                                    BorderBrush="{DynamicResource MainForegroundColor}"
                                    Background="{DynamicResource ButtonBackgroundColor}"
                                    BorderThickness="1"
                                    Width="12"
                                    Height="12"
                                    CornerRadius="2"/>
                            <Path x:Name="CheckMark"
                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                  StrokeThickness="2"
                                  Data="M 2 8 L 6 12 L 14 4"
                                  Visibility="Collapsed"/>
                        </Grid>
                        <ContentPresenter Content="{TemplateBinding Content}"
                                        VerticalAlignment="Center"
                                        HorizontalAlignment="Left"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid x:Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track x:Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton"
                                          Background="{TemplateBinding Background}"
                                          BorderBrush="{TemplateBinding Background}"
                                          BorderThickness="0"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <TextBlock Text="{TemplateBinding SelectionBoxItem}"
                                           Foreground="{TemplateBinding Foreground}"
                                           Background="Transparent"
                                           HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2"
                                           />
                            </ToggleButton>
                            <Popup x:Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border x:Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding Foreground}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <!-- Toggle button template x:Key="TabToggleButton" -->
        <Style TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border x:Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse x:Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border x:Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox x:Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path x:Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse x:Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse x:Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid x:Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" x:Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse x:Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Cut"/>
                                                    <MenuItem Command="Copy" Header="Copy"/>
                                                    <MenuItem Command="Paste" Header="Paste"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Row="0" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/> <!-- Navigation buttons -->
                <ColumnDefinition Width="*"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                            <Underline>I</Underline>nstall
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab2BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                            <Underline>T</Underline>weaks
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonConfigBackgroundColor}" Foreground="{DynamicResource ButtonConfigForegroundColor}" FontWeight="Bold" Name="WPFTab3BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonConfigForegroundColor}">
                            <Underline>C</Underline>onfig
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab4BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                            <Underline>U</Underline>pdates
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,0,0" Width="{DynamicResource SearchBarWidth}" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Left">
                    <Grid>
                        <TextBox
                            Width="{DynamicResource SearchBarWidth}"
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Left"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="Press Ctrl-F and type app name to filter application list below. Press Esc to reset the filter">
                        </TextBox>
                        <TextBlock
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="213,0,0,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Change the Winutil UI Theme"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Follow the Windows Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Dark" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Dark Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Light" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Light Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="Adjust Font Scaling for Accessibility"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="Font Scaling"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="Small"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="Large"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="Reset"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="Apply"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Import" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Import Configuration from exported file."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Export" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Export Selected Elements and copy execution command to clipboard."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="About" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Sponsors" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                    Content="&#xD7;" BorderThickness="0"
                BorderBrush="Transparent"
                Background="{DynamicResource MainBackgroundColor}"
                Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                HorizontalAlignment="Right" VerticalAlignment="Top"
                Margin="0,0,0,0"
                FontFamily="{DynamicResource FontFamily}"
                Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="1" Grid.Column="0" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >

                    <Grid Grid.Row="0" Grid.Column="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="Recommended Selections:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" Standard " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" Minimal " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" Clear " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" Show Installed Apps " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Note: Hover over items to get a better description. Please be careful as many of these tweaks will heavily modify your system.
                                        <LineBreak/>Recommended selections are for normal users and if you are unsure do NOT check anything else!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Run Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="Undo Selected Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Config" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Updates" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ScrollViewer}}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>  <!-- Row for the 3 columns -->
                            <RowDefinition Height="Auto"/>  <!-- Row for Windows Version -->
                        </Grid.RowDefinitions>

                        <!-- Three columns container -->
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Default Settings -->
                            <Border Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Default Settings"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Default Windows Update Configuration</Run>
                                        <LineBreak/>
                                         - No modifications to Windows defaults
                                        <LineBreak/>
                                         - Removes any custom update settings
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Note: This resets your Windows Update settings to default out of the box settings. It removes ANY policy or customization that has been done to Windows Update.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Security Settings -->
                            <Border Grid.Column="1" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Security Settings"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Balanced Security Configuration</Run>
                                        <LineBreak/>
                                         - Feature updates delayed by 365 days
                                        <LineBreak/>
                                         - Security updates installed after 4 days
                                        <LineBreak/><LineBreak/>
                                        <Run FontWeight="SemiBold">Feature Updates:</Run> New features and potential bugs
                                        <LineBreak/>
                                        <Run FontWeight="SemiBold">Security Updates:</Run> Critical security patches
                                    <LineBreak/><LineBreak/>
                                    <Run FontStyle="Italic" FontSize="11">Note: This only applies to Pro systems that can use group policy.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Disable Updates -->
                            <Border Grid.Column="2" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Disable All Updates"
                                            Foreground="Red"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold" Foreground="Red">!! Not Recommended !!</Run>
                                        <LineBreak/>
                                         - Disables ALL Windows Updates
                                        <LineBreak/>
                                         - Increases security risks
                                        <LineBreak/>
                                         - Only use for isolated systems
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Warning: Your system will be vulnerable without security updates.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Future Implementation: Add Windows Version to updates panel -->
                        <Grid Name="updatespanel" Grid.Row="1" Background="Transparent">
                        </Grid>
                    </Grid>
                </ScrollViewer>
            </TabItem>
        </TabControl>
    </Grid>
</Window>

'@
# Create enums
Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@

# SPDX-License-Identifier: MIT
# Set the maximum number of threads for the RunspacePool to the number of threads on the machine
$maxthreads = [int]$env:NUMBER_OF_PROCESSORS

# Create a new session state for parsing variables into our runspace
$hashVars = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync',$sync,$Null
$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Add the variable to the session state
$InitialSessionState.Variables.Add($hashVars)

# Get every private function and add them to the session state
$functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
foreach ($function in $functions) {
    $functionDefinition = Get-Content function:\$($function.name)
    $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $($function.name), $functionDefinition

    $initialSessionState.Commands.Add($functionEntry)
}

# Create the runspace pool
$sync.runspace = [runspacefactory]::CreateRunspacePool(
    1,                      # Minimum thread count
    $maxthreads,            # Maximum thread count
    $InitialSessionState,   # Initial session state
    $Host                   # Machine to create runspaces on
)

# Open the RunspacePool instance
$sync.runspace.Open()

# Create classes for different exceptions

class WingetFailedInstall : Exception {
    [string]$additionalData
    WingetFailedInstall($Message) : base($Message) {}
}

class ChocoFailedInstall : Exception {
    [string]$additionalData
    ChocoFailedInstall($Message) : base($Message) {}
}

class GenericException : Exception {
    [string]$additionalData
    GenericException($Message) : base($Message) {}
}

$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting winutil..." -ForegroundColor Red
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -init $true
# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

# Now call the function with the final merged config
Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
Initialize-WPFUI -targetGridName "appscategory"

Initialize-WPFUI -targetGridName "appspanel"

Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2

Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2

# Future implementation: Add Windows Version to updates panel
#Invoke-WPFUIElements -configVariable $sync.configs.updates -targetGridName "updatespanel" -columncount 1

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

#Persist Package Manager preference across winutil restarts
$sync.ChocoRadioButton.Add_Checked({Set-PackageManagerPreference Choco})
$sync.WingetRadioButton.Add_Checked({Set-PackageManagerPreference Winget})
Set-PackageManagerPreference

switch ($sync["ManagerPreference"]) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if ($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "TextBlock") {
            if ($sync["$psitem"].Name.EndsWith("Link")) {
                $sync["$psitem"].Add_MouseUp({
                    [System.Object]$Sender = $args[0]
                    Start-Process $Sender.ToolTip -ErrorAction Stop
                    Write-Debug "Opening: $($Sender.ToolTip)"
                })
            }

        }
    }
}

#===========================================================================
# Setup background config
#===========================================================================

# Load computer information in the background
Invoke-WPFRunspace -ScriptBlock {
    try {
        $ProgressPreference = "SilentlyContinue"
        $sync.ConfigLoaded = $False
        $sync.ComputerInfo = Get-ComputerInfo
        $sync.ConfigLoaded = $True
    }
    finally{
        $ProgressPreference = $oldProgressPreference
    }

} | Out-Null

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Print the logo
Show-CTTLogo

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Write-Debug "WinUtil lost focus"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height

        # Print the screen size
        Write-Debug "Primary Monitor Width: $screenWidth pixels"
        Write-Debug "Primary Monitor Height: $screenHeight pixels"

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            Write-Debug "The specified width and/or height is greater than the primary monitor size."
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        } else {
            Write-Debug "The specified width and height are within the primary monitor size limits."
        }
    } else {
        Write-Debug "Unable to retrieve information about the primary monitor."
    }

    # Check internet connectivity and disable install tab if offline
    #$isOnline = Test-WinUtilInternetConnection
    $isOnline = $true # Temporarily force online mode until we can resolve false negatives

    if (-not $isOnline) {
        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications"

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled" -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab2BT"  # Switch to Tweaks tab instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()

    # maybe this is not the best place to load and execute config file?
    # maybe community can help?
    if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        if ($PARAM_RUN) {
            # Wait for any existing process to complete before starting
            while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 5
            }
            Start-Sleep -Seconds 5

            Write-Host "Applying tweaks..."
            if (-not $sync.ProcessRunning) {
                Invoke-WPFtweaksbutton
                while ($sync.ProcessRunning) {
                    Start-Sleep -Seconds 5
                }
            }
            Start-Sleep -Seconds 5

            Write-Host "Installing features..."
            if (-not $sync.ProcessRunning) {
                Invoke-WPFFeatureInstall
                while ($sync.ProcessRunning) {
                    Start-Sleep -Seconds 5
                }
            }
            Start-Sleep -Seconds 5

            Write-Host "Installing applications..."
            if (-not $sync.ProcessRunning) {
                Invoke-WPFInstall
                while ($sync.ProcessRunning) {
                    Start-Sleep -Seconds 1
                }
            }
            Start-Sleep -Seconds 5

            Write-Host "Done."
        }
    }

})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

$sync["Form"].Add_Loaded({
    param($e)
    $sync.Form.MinWidth = "1000"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null


if (Test-Path "$winutildir\logo.ico") {
    $sync["logorender"] = "$winutildir\logo.ico"
} else {
    $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
}
$sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
$sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Write-Debug "ThemeButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Write-Debug "Dark Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Write-Debug "Light Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Write-Debug "SettingsButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Write-Debug "Import clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Write-Debug "Export clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
Author   : <a href="https://github.com/SamNickGammer">@SamNickGammer (Om Prakash Bharati)</a>
GitHub   : <a href="https://github.com/SamNickGammer/winutil">SamNickGammer/winutil</a>
"@
    Show-CustomDialog -Title "About" -Message $authorInfo
})
$sync["SponsorMenuItem"].Add_Click({
    Write-Debug "Sponsors clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
<a href="https://github.com/sponsors/SamNickGammer">Current sponsors for SamNickGammer:</a>
"@
    $authorInfo += "`n"
    try {
        $sponsors = Invoke-WinUtilSponsors
        foreach ($sponsor in $sponsors) {
            $authorInfo += "<a href=`"https://github.com/sponsors/SamNickGammer`">$sponsor</a>`n"
        }
    } catch {
        $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
    }
    Show-CustomDialog -Title "Sponsors" -Message $authorInfo -EnableScroll $true
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Write-Debug "FontScalingButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    Write-Debug "FontScalingResetButton clicked"
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    Write-Debug "FontScalingApplyButton clicked"
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

$sync["Form"].ShowDialog() | out-null
Stop-Transcript
