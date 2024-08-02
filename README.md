# thumbfast
High-performance on-the-fly thumbnailer for mpv.

**The script does not display thumbnails on its own,** it is meant to be used alongside a UI script that calls thumbfast.

[Preview of thumbfast on different UIs](https://user-images.githubusercontent.com/42466980/199102896-65f9e989-4189-4734-82a7-bda8ee63c7a6.webm)

## Installation
Place thumbfast.lua in your mpv `scripts` folder.  
Default settings are listed in thumbfast.conf, copy it to your mpv `script-opts` folder to customize.

For the vanilla UI, you also have to install [osc.lua](https://github.com/po5/thumbfast/blob/vanilla-osc/player/lua/osc.lua) (identical to the mpv default, with added thumbfast support) into your `scripts` folder.  
For third-party UIs, refer to their respective installation instructions. [See the list of supported UIs.](#ui-support)

## Features
No dependencies, no background thumbnail generation hogging your CPU.  
Customizable sizes, interval between thumbnails, cropping support, respects applied video filters.  
Supports web videos e.g. YouTube (disabled by default), mixed aspect ratio videos.

This script makes an effort to run on mpv versions as old as 0.29.0 (Windows, Linux) and 0.33.0 (Mac).  
Note that most custom UIs will not support vintage mpv builds, update before submitting an issue and mention if behavior is the same.  
Support for <0.33.0 on Linux requires socat.

## Usage
Once the lua file is in your scripts directory, and you are using a UI that supports thumbfast, you are done.  
Hover on the timeline for nice thumbnails.

## UI support
- [uosc](https://github.com/tomasklaen/uosc)
- [osc.lua](https://github.com/po5/thumbfast/blob/vanilla-osc/player/lua/osc.lua) (use this fork for vanilla UI)
- [progressbar](https://github.com/torque/mpv-progressbar)
- [tethys](https://github.com/Zren/mpv-osc-tethys) (PR pending, [lua](https://github.com/po5/mpv-osc-tethys/blob/thumbfast/osc_tethys.lua))
- [modern](https://github.com/maoiscat/mpv-osc-modern/tree/with.thumbfast) (separate branch)
- [ModernX](https://github.com/cyl0/ModernX)
- [oscc](https://github.com/longtermfree/oscc)
- [mfpbar](https://codeberg.org/NRK/mpv-toolbox/src/branch/master/mfpbar)

## mpv frontends
[ImPlay](https://tsl0922.github.io/ImPlay/) is auto-detected, but if you encounter issues set `mpv_path=ImPlay` in `script-opts/thumbfast.conf`.

[mpv.net](https://github.com/mpvnet-player/mpv.net) is directly supported since v7, no special configuration is required.

Other frontends and older versions of mpv.net will need [standalone mpv](https://mpv.io/installation/) accessible within [Path](https://learn.microsoft.com/en-us/previous-versions/office/developer/sharepoint-2010/ee537574(v=office.14)#to-add-a-path-to-the-path-environment-variable).  
The easiest way is to copy standalone mpv files inside of your frontend's installation folder.
It will be used in the background to generate thumbnails.

## MacOS
If your mpv install is an app bundle (e.g. stolendata builds), the script will work but you may notice the Dock shakes when generating the first thumbnail.  
To get rid of the shaking, make sure the app is in your Applications folder, then run: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`  
If you installed mpv via [Homebrew](https://brew.sh/), there are no issues.

## Configuration
`socket`: On Windows, a plain string. On Linux and Mac, a directory path for temporary files. Leave empty for auto.  
`thumbnail`: Path for the temporary thumbnail file (must not be a directory). Leave empty for auto.  
`max_height`, `max_width`: Maximum thumbnail generation size in pixels (scaled down to fit). Values are scaled when hidpi is enabled. Defaults to 200x200.  
`scale_factor`: Scale factor for thumbnail display size (requires mpv 0.38+). Lower quality than increasing max_height and max_width. Defaults to 1.  
`tone_mapping`: Apply tone-mapping, no to disable. Defaults to auto, which copies your mpv config.  
`overlay_id`: Overlay id for thumbnails. Leave blank unless you know what you're doing.  
`spawn_first`: Spawn thumbnailer on file load for faster initial thumbnails. Defaults to no.  
`quit_after_inactivity`: Close thumbnailer process after an inactivity period in seconds. Defaults to 0 (disabled).  
`network`: Enable on remote files. Defaults to no.  
`audio`: Enable on audio files. Defaults to no.  
`hwdec`: Enable hardware decoding. Defaults to no.  
`direct_io`: Windows only: write directly to pipe (requires LuaJIT). Should improve performance, ymmv.  
`mpv_path`: Custom path to the mpv executable. Defaults to mpv.

## For UI developers: How to add thumbfast support to your script
This API usage example code is [CC0 (public domain)](https://creativecommons.org/share-your-work/public-domain/cc0/).

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
