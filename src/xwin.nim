## Window-system helpers that Windy does not expose (interactive move,
## always-on-top, aspect-ratio sizing, popup windows for menus, ...), one
## implementation per platform with the same interface.

when defined(windows):
  import xwin_win32
  export xwin_win32
else:
  import xwin_x11
  export xwin_x11
