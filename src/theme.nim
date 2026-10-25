## Dark theme palette and metrics. Colors are premultiplied (ColorRGBX).

import chroma

proc c(hex: string, alpha = 1.0): ColorRGBX =
  var col = parseHtmlColor(hex)
  col.a = alpha
  col.rgbx

let
  colBackground* = c("#0f1013")
  colVideoBg* = c("#000000")
  colPanel* = c("#17181c")
  colPanelRaised* = c("#1f2126")
  colPopup* = c("#202228")
  colBorder* = c("#2d3038")
  colHover* = c("#2c2f37")
  colPressed* = c("#363a44")
  colText* = c("#e7e9ee")
  colTextDim* = c("#9aa0ab")
  colTextDisabled* = c("#5c616b")
  colAccent* = c("#9d8cff")
  colAccentHover* = c("#b5a8ff")
  colAccentDim* = c("#9d8cff", 0.35)
  colBuffered* = c("#342e54")   ## colAccent at 33% brightness: the seek bar's read-ahead
  colTrack* = c("#30333b")
  colMarker* = c("#ffc857")
  colBookmark* = c("#ff4d4d")
  colLoop* = c("#4dd2ff")
  colError* = c("#ff6b6b")
  colCardValue* = c("#9d8cff", 0.28)
  colCardRef* = c("#ffc857", 0.24)
  colCardRect* = c("#2ec4b6", 0.30)
  colCardPath* = c("#4ea8de", 0.30)
  colRect* = c("#2ec4b6")       ## rectangle drawn over the video
  colOutline* = c("#9aa0ab", 0.5)  ## compact mode's window edge
  colShadow* = c("#000000", 0.45)
  colScrim* = c("#000000", 0.55)
  colOverlayBg* = c("#121317", 0.92)
  colWhite* = c("#ffffff")
  colAxis* = [c("#eb5046"), c("#6ed25a"), c("#508cff")]  ## X/U/R, Y/V/G, Z/B: matches the viewports
  colOnAccent* = c("#121216")

const
  MenuBarHeight* = 28'f32
  SeekBarHeight* = 26'f32
  ControlsHeight* = 38'f32
  StatusHeight* = 24'f32
  PlaylistMinWidth* = 180'f32
  RunLogMinHeight* = 80'f32
  MenuRowHeight* = 26'f32
  MenuSeparatorHeight* = 9'f32
  FontMain* = "Default"
  FontSmall* = "Small"
  FontTitle* = "Title"
  FontMono* = "Mono"           ## the Scripts panel's hover help (its code is codeFont)
  LogoHeight* = 56'f32  ## the welcome screen's logo, at uiScale 1

proc codeFont*(px: int): string =
  ## The Scripts editor's code font at one of CodeFontSizes (appstate.nim).
  "Mono" & $px
