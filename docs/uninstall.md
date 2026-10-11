# Uninstall

[Documentation index](README.md)

Uninstall only components you installed. The commands below are instructions for you to run; publishing this repository does not run them.

## 1. Finish focus and clear website rules

Finish active Pomodoro rounds, then use **Blocked Sites → Unblock All Sites…** and complete its review. Confirm the rules are gone before removing the privileged helper; otherwise the hosts entries can remain active.

If installed, remove the website expiry service and its files:

```sh
sudo launchctl bootout system/com.productivity-os.expire
sudo rm /Library/LaunchDaemons/com.productivity-os.expire.plist
sudo rm /etc/sudoers.d/productivity-os
sudo rm /Library/PrivilegedHelperTools/productivity-os/blocker.sh
sudo rm -f /Library/PrivilegedHelperTools/productivity-os/focus-probe /Library/PrivilegedHelperTools/productivity-os/owner-uid /Library/PrivilegedHelperTools/productivity-os/state.json
sudo rmdir /Library/PrivilegedHelperTools/productivity-os
```

If a file/service is absent, inspect what remains instead of deleting unrelated files. Do not replace the system hosts file.

## 2. Remove native apps

Clear clipboard history (including favorites) or shelves from their UI first if you want that data removed. Close active windows and unsaved work, quit the affected helper normally, then run its matching uninstaller:

```sh
bash assets/setup-screenshot-studio.sh uninstall
bash assets/setup-clipboard-history.sh uninstall
bash assets/setup-drop-shelf.sh uninstall
bash assets/setup-health-breaks.sh uninstall
```

These remove the installed helper/service but preserve user data/preferences. Clipboard history and its Keychain key remain unless you clear them separately. Screenshot exports and projects remain where you saved them.

## 3. Remove resource controls

If installed, disable/remove CPU Priority first so tracked priorities can be restored:

```sh
sudo /bin/bash assets/setup-resource-priority.sh uninstall
```

Let every queued/running guarded job finish. Then, outside a guarded command, run:

```sh
bash assets/setup-resource-guard.sh uninstall
```

This removes the user service, launcher, and marked instruction sections. It preserves unrelated instructions, backups, and diagnostic state. It refuses removal while work is active.

## 4. Remove desktop integration

End any keep-awake session in Amphetamine. Show menu bar icons, then quit the Productivity OS divider (the built helper accepts `quit`):

```sh
./assets/menubar-divider quit
```

Optionally clear its stored divider preference with `defaults delete menubar-divider`. Turn Color Filters off through System Settings if desired. Remove Productivity OS from Raycast. Amphetamine is a separate app and is not removed by this project.

## Retained data

See [local storage locations](privacy-and-permissions.md#stored-data). Delete only this project's data after backing up anything you want to keep. Uninstalling the extension alone does not clear helper storage or website rules.
