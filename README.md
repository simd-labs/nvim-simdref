# nvim-simdref

Show the brief of an assembly instruction as an inlay hint.

![Neovim showing a vaddps inlay hint](https://raw.githubusercontent.com/simd-labs/nvim-simdref/screenshots/nvim-asm.png)

`K` on an instruction (vim.lsp.buf.hover) shows the full simdref page from the local catalog, no network. `gx` on a URL in it opens the link.

## Requirements

- Neovim 0.11 or newer
- `uv`, or `python3` 3.10 or newer

## Install

With `uv`:

```sh
uv tool install simdref
isa update
```

With a venv and no `uv`:

```sh
python3 -m venv ~/.local/share/nvim/simdref/venv
~/.local/share/nvim/simdref/venv/bin/pip install simdref
~/.local/share/nvim/simdref/venv/bin/isa update
```

Without a server on `PATH`, the plugin installs it in the background to `stdpath('data')/simdref`, then starts it.

## Setup

With lazy.nvim:

```lua
{ 'simd-labs/nvim-simdref' }
```

With vim.pack (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/simd-labs/nvim-simdref' })
```

Or copy the repo into `pack/*/start/` on the `packpath`.

The plugin starts the server on `asm`, `nasm`, `c`, `cpp` and `cuda` buffers. Set `vim.g.simdref_disable = true` before the plugin loads to turn it off.

If the server is not on `PATH` and the install does not run, the plugin shows:

```
simdref-lsp not found. Run: uv tool install simdref && isa update
https://github.com/simd-labs/simdref
```

## Test

```sh
SIMDREF_CATALOG=~/.local/share/simdref/catalog.db \
  nvim --headless -u NONE --cmd 'set rtp+=.' -l test/run.lua
nvim --headless -u NONE --cmd 'set rtp+=.' -l test/missing.lua
podman build --build-arg WITH_UV=0 -t nvim-simdref-test:no-uv -f test/podman/Containerfile .
podman run --rm --userns=keep-id -v "$PWD:/src:ro,Z" --network host nvim-simdref-test:no-uv
```

## License

GPL-3.0-or-later. See LICENSE.
