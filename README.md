# cc-code

A code editor for ComputerCraft.

⚠ **ComputerCraft uses `ctrl+S` for shutting down! Use `ctrl+D` to save instead!** ⚠

## Notable Features

- 📦 Easy Install/Update
- 📝 Common Editing Shortcuts
- 🌈 Lua Syntax Highlighting
- 📘 Text Selection
- 🔄 Full Undo/Redo History
- 💻 Multishell Integration
- ⚙ Configurable
- 🎨 Themable
- ⚡ *Blazingly Fast*

## Getting Started

### Install

To install, run the following command:

```sh
wget run https://raw.githubusercontent.com/Possseidon/cc-code/main/code/update.lua
```

### Start

To start cc-code run:

```sh
code <filename>
```

### Update

Once installed, cc-code will (by default) **automatically check for updates** in the background.

To manually trigger an update, run cc-code with the `--update` (or `-u`) flag:

```sh
code --update
```

Which does that same thing as simply running the install command again.

### Shell Integration

There will be some sort of `code --integrate` command for this soon™.

For now, to get basic autocompletion for files, add the following lines to your `startup.lua`:

```lua
local completion = require "cc.shell.completion"
shell.setCompletionFunction("code.lua", completion.build(completion.file))
```

And you can also alias `edit` to `/code` if you want:

```lua
shell.run "alias edit /code"
```
