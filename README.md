nvim-image-extmarks
===================

A plugin for drawing sixel images from nvim. Uses extmarks to keep track of the locations in the buffer.

[Sixels](https://en.wikipedia.org/wiki/Sixel) are a blob of binary data which, when written to a
supported terminal, display an image. To see if your terminal is supoorted, a good resource to check is
[Are We Sixel Yet?](https://www.arewesixelyet.com/).

Note that this plugin is only meant to expose a convenient API. Images will not be displayed
automatically - for example, previews in a netrw buffer - without another plugin.

See also [fence-preview](https://github.com/queue-miscreant/fence-preview), a sister project to preview
markdown-formatted content like LaTeX.


Requirements
------------

- A terminal emulator that can display sixels
    - See [here](https://www.arewesixelyet.com/)
- ImageMagick with support for sixel blobs
    - Run `magick -list format | grep -i sixel` to check


Installation
------------

### Vundle

Place the following in `~/.config/nvim/init.vim`:
```vim
Plugin 'queue-miscreant/nvim_image_extmarks'
```
Make sure the file is sourced and run `:PluginInstall`.


Limitations
-----------

### Folding

The plugin tends to respect folds in two ways:

- If an extmark intersects with a fold, then the image will not be drawn
- If a fold is completely contained by an extmark, the image will be resized to the folded height

However, opening and closing folds will _not_ automatically trigger a redraw.
Unfortunately, this is a Neovim limitation -- folding commands and keybinds do not trigger any
autocmds (not even `WinScrolled`).


### Scrolling

Similarly, there is no way to detect when the terminal is scrolled with an Ex command, which
can cause phantom image artifacts to be remain.


### tmux

As of writing this documentation, tmux, the terminal multiplexer, newly supports sixel content.
However, if you experiment with this feature on your own, you may find that sixels are
"sticky" between panes and windows.

To get around this, when clearing the screen, the plugin will attempt to "refresh" the content
in the session by quickly detaching and attaching.
With enough delay, this produces visible artifacts, including:

    - boxes of "+" characters where the images would be displayed
    - sixel binary content, which appears as random ASCII characters


Commands
--------

### `:[range]CreateImage {filepath}`

Create an image extmark with the given filename at the range
specified. This wraps `sixel_extmarks.create` below.


Lua Functions
-------------

### sixel\_extmarks.create

`sixel_extmarks.create(
  start_row: integer,
  end_row: integer,
  path: string
) -> integer`

Create a new image extmark which stretches from (0-indexed) line
`start_row` to line `end_row` of the buffer and has content
from the file at `path`.


### sixel\_extmarks.create\_virtual

`sixel_extmarks.create_virtual(
  {start_row}: integer,
  {height}: integer,
  {path}: string
) -> integer`

Create a new "virtual" image extmark on (0-indexed) line `start_row`
of the buffer which is `height` rows tall and has content from the
file at `path`.


### sixel\_extmarks.get

`sixel_extmarks.get(
  start_row: integer,
  end_row: integer
) -> image_extmark[]`

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

`sixel_extmarks.get_by_id(id: integer) -> image_extmark|nil`

Retrieve an extmark in the current buffer with the given id.
Returns a table which is structured the same as the entries of the return type
of `sixel_extmarks.get`.


### sixel\_extmarks.remove

`sixel_extmarks.remove(id: integer)`

Delete the extmark in the current buffer identified by `id`. This does NOT free
from the cache any of the blobs generated from the file the extmark points to.


### sixel\_extmarks.remove\_all

`sixel_extmarks.remove_all()`

Delete all extmarks in the current buffer. The same caveat about the
cache applies here as well.


### sixel\_extmarks.move

`sixel_extmarks.move(id: integer, start_row: integer, end_row?: integer)`

Move the extmark identified by `id`.

If the extmark was created with `sixel_extmarks.create`, the image will
stretch from line `start_row` to line `end_row`.
Be aware that this can resize the image.

If the extmark was created with `sixel_extmarks.create_virtual`,
the image will be moved to the line `start_row` and `end_row`
can be omitted.
If given, `end_row` is the new height of the image in lines.


### sixel\_extmarks.change\_content

`sixel_extmarks.change_content(id: integer, path: string)`

Change the content of the extmark identified by `id` to the file at
`path`.


### sixel\_extmarks.clear\_cache

`sixel_extmarks.clear_cache()`
`sixel_extmarks.clear_cache(path: string)`
`sixel_extmarks.clear_cache(paths: string[])`

Clear the sixel blob cache. If no argument is supplied, then the entire
cache is cleared.

If `path`, a single string argument is supplied, then only the blobs
for that file are removed.

If `paths`, a list of strings are supplied, then all blobs for those
files in the list are removed.


### sixel\_extmarks.clear\_screen

`sixel_extmarks.clear_screen()`

Clear all content drawn to the screen. Unlike `:mode`, this has the
additional guarantee of working inside a tmux session.


### sixel\_extmarks.redraw

`sixel_extmarks.redraw()`
`sixel_extmarks.redraw(force: boolean)`

Clear the screen and redraw the currently displayed content.


### sixel\_extmarks.disable\_drawing

`sixel_extmarks.disable_drawing()`

Disable drawing blobs.

Blobs will still be generated in the background, but the contents will not
be pushed to the screen.


### sixel\_extmarks.set\_extmark\_error

`sixel_extmarks.set_extmark_error(id: integer|image_extmark, error_text: string|nil)`

Set error text on an extmark.

`id` can be either the id of the extmark or a value returned by `sixel_extmarks.get`
`error_text` is the error text to set on the extmark or nil if the error should be cleared.


### sixel\_extmarks.enable\_drawing

`sixel_extmarks.enable_drawing()`

Enable drawing blobs, after having disabled them with `disable_drawing`.


### sixel\_extmarks.dump\_blob\_cache

`sixel_extmarks.dump_blob_cache()`

Generate a snapshot of the blob cache.
Rather than the cache, the first two layers of keys are returned, i.e.,
a table with filenames as keys and buffer ranges as values.


Configuration
-------------

### g:image\_extmarks\_buffer\_ms

Controls the amount of delay, in milliseconds, between the screen being cleared
and extmarks being redrawn.
If multiple redraws occur in quick succession, then this can prevent
flashing due to the screen clearing and redrawing.


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

`User`-type `autocmd`s are fired under the `ImageExtmarks#pre_draw` immediately
before drawing sixel blobs.


TODOs
-----

- Configurable limit for maximum number of ImageMagick subprocesses
- Images crop to window width
- Crop thresholds
- Hide text behind extmark with highlight
    - This is more difficult than it seems. 256-color terminals use `gui` highlights, which don't support `start=`/`stop=`
