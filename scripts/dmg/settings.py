# dmgbuild settings for DotStudio.dmg, used by scripts/make-dmg.sh (which passes the -D defines).
# dmgbuild writes the Finder window layout straight into the volume's .DS_Store, so no Finder
# window is ever opened while building (CI runners have no GUI session anyway).
#
# The background art (background.tiff, from background.html) is drawn for exactly this layout:
# keep WINDOW, ICON_SIZE and the positions below in step with the constants in background.html.
import os.path

app = defines["app"]                 # path to DotStudio.app
here = defines["dmgdir"]             # scripts/dmg
howto = defines["howto"]             # staged copy of "How to Install.txt"
app_name = os.path.basename(app)     # "DotStudio.app"

# Volume
format = defines.get("format", "ULFO")   # LZFSE: smaller than UDZO and mounts on every supported macOS (10.11+)
filesystem = "HFS+"
icon = defines["volume_icon"]            # the app's own AppIcon.icns, shown for the mounted volume

# Contents
files = [app, (howto, "How to Install.txt")]
symlinks = {"Applications": "/Applications"}
# Only the text file: Finder hides ".app" by itself, and setting the hide-extension flag on the
# bundle writes FinderInfo onto it, which `codesign --verify --strict` rejects as detritus.
hide_extensions = ["How to Install.txt"]

# Window: 660x480 pt content, no toolbar / sidebar / path bar / status bar.
WINDOW = (660, 480)
window_rect = ((200, 140), WINDOW)
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_pathbar = False
show_status_bar = False
show_tab_view = False
background = os.path.join(here, "background.tiff")   # 1x + 2x representations

# Icons (centres, in window points)
ICON_SIZE = 112
icon_size = ICON_SIZE
text_size = 13
label_pos = "bottom"
arrange_by = None
show_icon_preview = False
show_item_info = False
icon_locations = {
    app_name: (170, 184),               # drag pair: the hero, on the scene band
    "Applications": (490, 184),
    "How to Install.txt": (92, 360),    # bottom-left, beside the first-launch hint
}
