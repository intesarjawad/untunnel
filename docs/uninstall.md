# What Untunnel writes to your system, and how `uninstall` removes it

Four paths. Models, Monitor recordings and preferences live inside the Application Support folder.
Monitor saves five-second before/after WAV pairs for each active path under
`~/Library/Application Support/Untunnel/recordings/`. Opening Monitor previews the selected
microphone even without the virtual driver; incoming audio appears while its restore path runs.

```sh
swift run untunnel uninstall --dry-run
```

```text
Untunnel uninstall (dry run)

Would remove:
  ~/Applications/Untunnel.app
  ~/Library/LaunchAgents/com.intesarjawad.untunnel.plist
  ~/Library/Application Support/Untunnel
  /Library/Audio/Plug-Ins/HAL/Untunnel.driver

Would run:
  launchctl bootout gui/501/com.intesarjawad.untunnel
  sudo rm -rf /Library/Audio/Plug-Ins/HAL/Untunnel.driver
  sudo killall coreaudiod

Nothing was changed.
```

(Home directory shortened to `~` here; the command prints the absolute path.) `untunnel uninstall`
does the same after asking. It leaves the app's user defaults;
`defaults delete com.intesarjawad.untunnel` removes them.
