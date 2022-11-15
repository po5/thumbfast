# thumbfast
High-performance on-the-fly thumbnailer for mpv.

**The script does not display thumbnails on its own,** it is meant to be used alongside a UI script that calls thumbfast.

[Preview of thumbfast on different UIs](https://user-images.githubusercontent.com/42466980/199102896-65f9e989-4189-4734-82a7-bda8ee63c7a6.webm)

## Installation
Place thumbfast.lua in your mpv `scripts` folder.  
Default settings are listed in thumbfast.conf, copy it to your mpv `script-opts` folder to customize.

For the vanilla UI, you have to install [osc.lua](https://github.com/po5/thumbfast/blob/vanilla-osc/player/lua/osc.lua) (which is identical to the vanilla UI) and add `osc=no` in your `mpv.conf`.

## UI support
- [uosc](https://github.com/tomasklaen/uosc)
- [osc.lua](https://github.com/po5/thumbfast/blob/vanilla-osc/player/lua/osc.lua) (use this fork for vanilla UI)
- [progressbar](https://github.com/torque/mpv-progressbar)
- [tethys](https://github.com/Zren/mpv-osc-tethys) (PR pending, [lua](https://github.com/Zren/mpv-osc-tethys/blob/a6a3f4295e9a68dbb0763f30cb2d9f73b2452445/osc_tethys.lua))
- [modern](https://github.com/maoiscat/mpv-osc-modern/tree/with.thumbfast) (separate branch)
- [MordenX](https://github.com/cyl0/MordenX)
- [oscc](https://github.com/longtermfree/oscc)
- [mfpbar](https://codeberg.org/NRK/mpv-toolbox/src/branch/master/mfpbar)

## Features
No dependencies, no background thumbnail generation hogging your CPU.  
Customizable sizes, interval between thumbnails, cropping support, respects applied video filters.  
Supports web videos e.g. YouTube (disabled by default), mixed aspect ratio videos.

## Requirements
Windows: None, works out of the box

Linux: None, works out of the box

Mac: None, works out of the box

This script makes an effort to run on mpv versions as old as 0.29.0.  
Note that most custom UIs will not support vintage mpv builds, consider updating if you're having issues.

## Usage
Once the lua file is in your scripts directory, and you are using a UI that supports thumbfast, you are done.  
Hover on the timeline for nice thumbnails.

## Configuration
`socket`: On Windows, a plain string. On Linux and Mac, a directory path for temporary files. Leave empty for auto.  
`thumbnail`: Path for the temporary thumbnail file (must not be a directory). Leave empty for auto.  
`max_height`, `max_width`: Maximum thumbnail size in pixels (scaled down to fit). Values are scaled when hidpi is enabled. Defaults to 200x200.  
`overlay_id`: Overlay id for thumbnails. Leave blank unless you know what you're doing.  
`spawn_first`: Spawn thumbnailer on file load for faster initial thumbnails. Defaults to no.  
`network`: Enable on remote files. Defaults to no.  
`audio`: Enable on audio files. Defaults to no.  
`hwdec`: Enable hardware decoding. Defaults to no.  
`direct_io`: Windows only: write directly to pipe (requires LuaJIT). Should improve performance, ymmv.

## For UI developers: How to add thumbfast support to your script
Declare the thumbfast state variable near the top of your script.  
*Do not manually modify those values, they are automatically updated by the script and changes will be overwritten.*
```lua
local thumbfast = {
    width = 0,
    height = 0,
    disabled = true,
    available = false
}
```
Register the state setter near the end of your script, or near where your other script messages are.  
You are expected to have required `mp.utils` (for this example, into a `utils` variable).
```lua
mp.register_script_message("thumbfast-info", function(json)
    local data = utils.parse_json(json)
    if type(data) ~= "table" or not data.width or not data.height then
        msg.error("thumbfast-info: received json didn't produce a table with thumbnail information")
    else
        thumbfast = data
    end
end)
```
Now for the actual functionality. You are in charge of supplying the time hovered (in seconds), and x/y coordinates for the top-left corner of the thumbnail.  
In this example, the thumbnail is horizontally centered on the cursor, respects a 10px margin on both sides, and displays 10px above the cursor.  
This code should be run when the user hovers on the seekbar. Don't worry even if this is called on every render, thumbfast won't be bogged down.
```lua
-- below are examples of what these values may look like
-- margin_left = 10
-- margin_right = 10
-- cursor_x, cursor_y = mp.get_mouse_pos()
-- display_width = mp.get_property_number("osd-width")
-- hovered_seconds = video_duration * cursor_x / display_width

if not thumbfast.disabled then
    mp.commandv("script-message-to", "thumbfast", "thumb",
        -- hovered time in seconds
        hovered_seconds,
        -- x
        math.min(display_width - thumbfast.width - margin_right, math.max(margin_left, cursor_x - thumbfast.width / 2)),
        -- y
        cursor_y - 10 - thumbfast.height
    )
end
```
This code should be run when the user leaves the seekbar.
```lua
if thumbfast.available then
    mp.commandv("script-message-to", "thumbfast", "clear")
end
```
If you did all that, your script can now display thumbnails!  
Look at existing integrations for more concrete examples.

If positioning isn't enough and you want complete control over rendering:  
Register a `thumbfast-render` script message.  
When requesting the thumbnail, set x and y to empty strings and supply your script's name as the 4th argument.  
You will recieve a json object with the keys `width`, `height`, `x`, `y`, `socket`, `thumbnail`, `overlay_id` when the thumbnail is ready.
