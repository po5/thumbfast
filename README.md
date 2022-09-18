# thumbfast
High-performance on-the-fly thumbnailer for mpv.

**The script does not display thumbnails on its own,** it is meant to be used alongside a UI script that calls thumbfast.

## UI support
- [uosc](https://github.com/tomasklaen/uosc)

## Requirements
Windows: None, works out of the box

Linux: socat, already installed on most systems

Mac: None, works out of the box

## Installation
Place thumbfast.lua in your mpv `scripts` folder.  
Default settings are listed in thumbfast.conf, copy it to your mpv `script-opts` folder to customize.

## Usage
Once the lua file is in your scripts directory, and you are using a UI that supports thumbfast, you are done.  
Hover on the timeline for nice thumbnails.
