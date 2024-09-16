sixel-extmarks
==============

A plugin for drawing sixel images from nvim. Uses extmarks to keep track of the locations in the buffer.

[Sixels](https://en.wikipedia.org/wiki/Sixel) are a blob of binary data which, when written to a
supported terminal, display an image. To see if your terminal is supoorted, a good resource to check is
[Are We Sixel Yet?](https://www.arewesixelyet.com/).

Note that this plugin is only meant to expose a convenient API. Images will not be displayed
automatically - for example, previews in a netrw buffer - without another plugin.

See also [fence-preview](https://github.com/queue-miscreant/fence-preview), a sister project to preview
markdown-formatted content such as LaTeX.


Requirements
------------

- Neovim >= 0.7
  - Some features require >= 0.10
- A terminal emulator that can display sixels
  - See [here](https://www.arewesixelyet.com/)
- UNIX-like utilities
  - `tty` command, which outputs the path to the current terminal device
  - `fileno` and `ioctl` system calls
  - (Optional) Python installation with `termios`
  - (Optional) `ps`, `pstree`, and terminal devices located under `/dev`
- ImageMagick with support for sixel blobs
  - Run `magick -list format | grep -i sixel` to check
  - Command name might be `convert` instead


Installation
------------

### Vundle

Place the following in `~/.config/nvim/init.vim`:
```vim
Plugin 'queue-miscreant/nvim_image_extmarks'
```
Make sure the file is sourced and run `:PluginInstall`.


Limitations and Workarounds
---------------------------

### Folding

The plugin tends to respect folds in two ways:

- If an extmark intersects with a fold, then the image will not be drawn
- If a fold is completely contained by an extmark, the image will be resized to the folded height

However, opening and closing folds will _not_ automatically trigger a redraw.
Unfortunately, this is a Neovim limitation -- folding commands and keybinds do not trigger any
autocmds (not even `WinScrolled`).

To get around this, the default keymaps which interact with folding (those which start with z)
are locally remapped to perform their normal action AND call the redraw function.


### Scrolling

Similarly, there is no way (or it is very difficult) to detect the following display changes:

- Scrolling the terminal with an Ex command
- Adding things that change vertical window content, such as `nvim_buf_set_extmark` with `virt_lines`
- Scrolling a window above one with images in it

These may cause phantom image artifacts to appear in places they shouldn't.


### tmux

As of writing this documentation, tmux, the terminal multiplexer, newly supports sixel content.
However, if you experiment with this feature on your own, you may find that sixels are
"sticky" between panes and windows.

To get around this, when clearing the screen, the plugin will attempt to "refresh" the content
in the session by quickly detaching and attaching.
With enough delay, this produces visible artifacts, including:

    - boxes of "+" characters where the images would be displayed
    - sixel binary content, which appears as random ASCII characters


### Layered Terminals

Sometimes, a process may spawn a pseudoterminal. For example, the Python package
[pexpect](https://github.com/pexpect/pexpect) allows you to control a child terminal from
Python, while also forwarding resizes from the parent to the child.

However, _this package specifically_ does not forward the pixel
dimensions of the terminal, and instead report as 0.

To get around this, the plugin can attempt to query the terminals of
the parent processes in addition to the one on standard output.
It does this by running `pstree` and `ps`.

This behavior can be disabled by setting `g:image_extmarks_parent_tty_magic` to 0.


Similar Projects
----------------

I'd be remiss to not include links to projects that are doing similar things:

- [hologram.nvim](https://github.com/edluffy/hologram.nvim), which appears to be no longer updated and seems to have been superceded by...
- [image.nvim](https://github.com/3rd/image.nvim), which has similar features using Kitty graphics

Since these projects don't target Sixel, I'd like to think I'm still providing a utility here.


Documentation
=============

See also the included helpdoc.


Commands
--------

### `:[range]CreateImage {filepath}`

Create an image extmark with the given filename at the range
specified. This wraps `sixel_extmarks.create` below.


Lua Functions
-------------

### sixel\_extmarks.create

```
sixel_extmarks.create(
  start_row: integer,
  end_row: integer,
  path: string
) -> integer
```

Create a new image extmark which stretches from (0-indexed) line
`start_row` to line `end_row` of the buffer and has content
from the file at `path`.


### sixel\_extmarks.create\_virtual

```
sixel_extmarks.create_virtual(
  {start_row}: integer,
  {height}: integer,
  {path}: string
) -> integer
```

Create a new "virtual" image extmark on (0-indexed) line `start_row`
of the buffer which is `height` rows tall and has content from the
file at `path`.

Virtual extmarks are only supported on Neovim >=0.10.


### sixel\_extmarks.get

```
sixel_extmarks.get(
  start_row: integer,
  end_row: integer
) -> image_extmark[]
```

Retrieve a list of image extmarks in the current buffer between
(0-indexed) rows `start_row` and `end_row`.
To get all extmarks, set `start_row` to 0 and `end_row` to -1.

The return value is a list of tables with the following structure:

| Field       | Type    | Description                                                                                                   |
|-------------|---------|---------------------------------------------------------------------------------------------------------------|
| `id`        | integer | The id of the extmark                                                                                         |
| `start_row` | integer | The (0-indexed) line that the extmark starts on                                                               |
| `type`      | string  | "inline" if the extmark was created with `create`. "virtual" if the extmark was created with `create_virtual` |
| `end_row`   | integer | The (0-indexed) line that the extmark ends on. Unset unless `type` is "inline".                               |
| `height`    | integer | The height of the extmark, in rows. Unset unless `type` is "virtual".                                         |
| `path`      | string  | A path to the current content                                                                                 |


### sixel\_extmarks.get\_by\_id

```
sixel_extmarks.get_by_id(id: integer) -> image_extmark|nil
```

Retrieve an extmark in the current buffer with the given id.
Returns a table which is structured the same as the entries of the return type
of `sixel_extmarks.get`.


### sixel\_extmarks.remove

```
sixel_extmarks.remove(id: integer)
```

Delete the extmark in the current buffer identified by `id`. This does NOT free
from the cache any of the blobs generated from the file the extmark points to.


### sixel\_extmarks.remove\_all

```
sixel_extmarks.remove_all()
```

Delete all extmarks in the current buffer. The same caveat about the
cache applies here as well.


### sixel\_extmarks.move

```
sixel_extmarks.move(id: integer, start_row: integer, end_row?: integer)
```

Move the extmark identified by `id`.

If the extmark was created with `sixel_extmarks.create`, the image will
stretch from line `start_row` to line `end_row`.
Be aware that this can resize the image.

If the extmark was created with `sixel_extmarks.create_virtual`,
the image will be moved to the line `start_row` and `end_row`
can be omitted.
If given, `end_row` is the new height of the image in lines.


### sixel\_extmarks.change\_content

```
sixel_extmarks.change_content(id: integer, path: string)
```

Change the content of the extmark identified by `id` to the file at
`path`.


### sixel\_extmarks.clear\_cache

```
sixel_extmarks.clear_cache()
sixel_extmarks.clear_cache(path: string)
sixel_extmarks.clear_cache(paths: string[])
```

Clear the sixel blob cache. If no argument is supplied, then the entire
cache is cleared.

If `path`, a single string argument is supplied, then only the blobs
for that file are removed.

If `paths`, a list of strings are supplied, then all blobs for those
files in the list are removed.


### sixel\_extmarks.clear\_screen

```
sixel_extmarks.clear_screen()
```

Clear all content drawn to the screen. Unlike `:mode`, this has the
additional guarantee of working inside a tmux session.


### sixel\_extmarks.redraw

```
sixel_extmarks.redraw()
sixel_extmarks.redraw(force: boolean)
```

Clear the screen and redraw the currently displayed content.


### sixel\_extmarks.disable\_drawing

```
sixel_extmarks.disable_drawing()
```

Disable drawing blobs.

Blobs will still be generated in the background, but the contents will not
be pushed to the screen.


### sixel\_extmarks.set\_extmark\_error

```
sixel_extmarks.set_extmark_error(id: integer|image_extmark, error_text: string|nil)
```

Set error text on an extmark.

`id` can be either the id of the extmark or a value returned by `sixel_extmarks.get`
`error_text` is the error text to set on the extmark or nil if the error should be cleared.


### sixel\_extmarks.enable\_drawing

```
sixel_extmarks.enable_drawing()
```

Enable drawing blobs, after having disabled them with `disable_drawing`.


### sixel\_extmarks.dump\_blob\_cache

```
sixel_extmarks.dump_blob_cache()
```

Generate a snapshot of the blob cache.
Rather than the cache, the first two layers of keys are returned, i.e.,
a table with filenames as keys and buffer ranges as values.


Configuration
-------------

### g:image\_extmarks\_imagemagick\_command

Specifies the name of the command for invoking ImageMagick.

Defaults to `magick`, or to `convert` if that command doesn't exist.


### g:image\_extmarks\_buffer\_ms

Controls the amount of delay, in milliseconds, between the screen being cleared
and extmarks being redrawn.

If multiple redraws occur in quick succession, then this can prevent
flashing due to the screen clearing and redrawing.


### g:image\_extmarks\_min\_cropped\_height

Controls the minimum height (in lines) for which cropping images is
allowed. The value 0 means any amount of crop is allowed.

This can also be set to -1 to disable drawing cropped images entirely.


### g:image\_extmarks\_slow\_insert

Activates "slow" insert mode.

Instead of attempting to redraw images as-necessary in insert mode, drawing is
disabled when entering insert mode and a redraw is invoked upon exiting insert
mode.


### g:image\_extmarks\_disable\_fold\_remaps

Disables remapping keys which interact with folds to also force images to redraw.
This can be a boolean (i.e., 0 or 1) or a list.

If a truthy boolean, no remaps will take place.

If a list, then the entries will be interpreted as maps (such as "zf") to
_not_ remap.

### g:image\_extmarks\_parent\_tty\_magic

Enables fetching character sizes from terminals of parent processes.
Defaults to 1 (true).


### g:image\_extmarks\_ioctl\_magic

Enables fetching the ioctl for TIOCGWINSZ from Python. Defaults to 1
(true).

If disabled and `g:image_extmarks_TIOCGWINSZ` is not manually set,
TIOCGWINSZ will fall back to 0x5413, its value on Linux.


### g:image\_extmarks\_TIOCGWINSZ

The number corresponding to the TIOCGWINSZ ioctl.
If `g:image_extmarks_ioctl_magic` is 1, then this variable is set
automatically. Otherwise, it can be specified by the user.


Autocmds
--------

`autocmd`s which are used by the plugin live under the group `ImageExtmarks`.
These include:

- `CursorMoved`, `TabEnter`, `TabClosed`, `TextChanged`, `TextChangedI`, `WinScrolled`
    - Attempt to redraw, if necessary
- `WinResized`, `VimEnter`, `VimResized`
    - Force redraw
- `TabLeave`, `ExitPre`
    - Clear the screen of all sixel images
- `InsertEnter`, `InsertLeave`
    - See `g:image_extmarks_slow_insert`

These attempt to replicate the feel of normal text extmarks without extra
configuration. They can be overridden or unbound at your leisure using
`autocmd!`.


### Events

`User`-type `autocmd`s are fired under the `ImageExtmarks#pre_draw` group immediately
before drawing sixel blobs.


TODOs
=====

- Images crop to window width
- Reinstate hiding extmarks when cursor moves under them
- Scrolling redraw timeout separate from other redraw timeouts
  - "Cursor at the bottom/top" probably means the user is jumping around a lot
  - Alternatively, top line of window moved is different from "new extmark in window"
- Testing
- Configurable limit for maximum number of ImageMagick subprocesses
- Images can still get desynced from their position on screen
- Hide text behind extmark with highlight
    - This is more difficult than it seems. 256-color terminals use `gui` highlights, which don't support `start=`/`stop=`
