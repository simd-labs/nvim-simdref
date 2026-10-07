# nvim-simdref

Show the brief of an assembly instruction as an inlay hint. Applies to `.s`/`.asm` files and to C/C++ `asm(...)` blocks. Uses the simdref language server.

![Neovim showing a vaddps inlay hint](https://raw.githubusercontent.com/simd-labs/nvim-simdref/screenshots/nvim-asm.png)

`K` on an instruction (vim.lsp.buf.hover) shows the full simdref page from the local catalog, no network. `gx` on a URL in it opens the link.

## Requirements

- Neovim 0.11 or newer
- One of: `uv`, or `python3` 3.10 or newer

## Install

Install the server from PyPI. Or let the plugin do it on the first run.

With `uv`:

```sh
uv tool install simdref
isa update
```

With a venv, when `uv` is not there:

```sh
python3 -m venv ~/.local/share/nvim/simdref/venv
~/.local/share/nvim/simdref/venv/bin/pip install simdref
~/.local/share/nvim/simdref/venv/bin/isa update
```

If the plugin finds no server, it installs the server in the background in `stdpath('data')/simdref` and starts the server when the install is complete. The plugin does not install into the plugin dir.

## Setup

With lazy.nvim:

```lua
{ 'simd-labs/nvim-simdref' }
```

With vim.pack (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/simd-labs/nvim-simdref' })
```

Or copy the repo directory into a directory on the `packpath` in `pack/*/start/`.

The plugin starts the server on `asm`, `nasm`, `c`, `cpp` and `cuda` buffers and activates inlay hints. Set `vim.g.simdref_disable = true` before the plugin loads to turn it off.

If the server is not on `PATH` and the install does not run, the plugin shows:

```
simdref-lsp not found. Run: uv tool install simdref && isa update
https://github.com/simd-labs/simdref
```

Neovim shows the full hint text, for example `vaddps` shows `Add Packed Single Precision Floating-Point Values`.

## Test

```sh
# hint test: needs simdref-lsp on PATH and a catalog (isa update)
SIMDREF_CATALOG=~/.local/share/simdref/catalog.db \
  nvim --headless -u NONE --cmd 'set rtp+=.' -l test/run.lua
# missing-binary test: no uv, no python3
nvim --headless -u NONE --cmd 'set rtp+=.' -l test/missing.lua
# container rig (rootless podman, debian sid + neovim 0.12)
podman build --build-arg WITH_UV=0 -t nvim-simdref-test:no-uv -f test/podman/Containerfile .
podman run --rm --userns=keep-id -v "$PWD:/src:ro,Z" --network host nvim-simdref-test:no-uv
```

## License

GPL-3.0-or-later. See LICENSE.
