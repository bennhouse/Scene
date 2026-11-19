# Changelog

## 1.1.0

- New option: close **apps not in the scene** before restoring. Scene first checks them for unsaved changes and asks what to do.
- Unsaved changes are checked before closing windows too.
- Press Esc three times to stop a restore, with a counter in the progress panel.
- Slow apps (DaVinci Resolve and others with a loading screen) are waited for, and DaVinci's Project Manager is placed like any window.
- Apps paused by macOS in the background are woken up instead of opening a second copy: no more documents opened twice (WordCraft).
- Firefox tabs on other desktops are read when saving a scene, and Firefox's launch window is reused instead of adding the tabs twice.
- Windows an app opens on the other display are moved to their place instead of being lost.
- Minimized windows are saved with their document and restored minimized.
- Untitled documents are never mistaken for a file with the same name.
- Safari private windows blocked by Screen Time fall back to normal windows.
- Open and Save panels are never taken for a scene's window.
- Apps that hide their window when closed (Claude, Music) count as closed and show it again when needed.
- The Scene window stays in front without flashing behind other apps.
- Short status messages that fit a small window; toolbar icons always lit, grey only when they can't be used, dimmed with the window.
- Fewer pointer jumps and window moves while restoring.

## 1.0.2

- Faster restores: desktops already in place are skipped, a desktop's apps open together, and Scene waits for them before moving on.
- Browsers: only the missing tabs are added; no more duplicate windows or tabs in Chrome; Firefox opens normally.
- Documents are found even when the window title is just the file name.
- A permissions screen on first launch.
- A pulsing outline and a status panel while Scene works.
- Duplicate a scene (⌘D).

## 1.0.1

- Private APIs are looked up at launch instead of linked, so Scene still opens if macOS removes one.

## 1.0

- First release: save and restore windows across displays and desktops.
