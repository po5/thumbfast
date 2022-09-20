# thumbfast
High-performance on-the-fly thumbnailer for mpv.

**The script does not display thumbnails on its own,** it is meant to be used alongside a UI script that calls thumbfast.

## Installation
Place thumbfast.lua in your mpv `scripts` folder.  
Default settings are listed in thumbfast.conf, copy it to your mpv `script-opts` folder to customize.

## UI support
- [uosc](https://github.com/tomasklaen/uosc)
- [osc.lua](https://github.com/po5/thumbfast/blob/vanilla-osc/player/lua/osc.lua) (fork)
- [progressbar](https://github.com/po5/thumbfast/blob/mpv-progressbar/build/progressbar.lua) (fork)

## Features
No dependencies, no background thumbnail generation hogging your CPU.  
Customizable sizes, interval between thumbnails, cropping support, respects applied video filters.  
Supports web videos e.g. YouTube (disabled by default), mixed aspect ratio videos.

## Requirements
Windows: None, works out of the box

Linux: socat, already installed on most systems

Mac: None, works out of the box

## Usage
Once the lua file is in your scripts directory, and you are using a UI that supports thumbfast, you are done.  
Hover on the timeline for nice thumbnails.

## Configuration
`socket`: On Windows, a plain string. On Linux and Mac, a directory path for temporary files. Leave empty for auto.  
`thumbnail`: Path for the temporary thumbnail file (must not be a directory). Leave empty for auto.  
`max_height`, `max_width`: Maximum thumbnail size in pixels (scaled down to fit). Defaults to 200x200.  
`overlay_id`: Overlay id for thumbnails. Leave blank unless you know what you're doing.  
`interval`: Thumbnail interval in seconds, set to 0 to disable (warning: high cpu usage). Defaults to 10 seconds.  
`spawn_first`: Spawn thumbnailer on file load for faster initial thumbnails. Defaults to no.  
`network`: Enable on remote files. Defaults to no.  
`audio`: Enable on audio files. Defaults to no.
