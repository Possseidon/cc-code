# cc-code

A code editor for ComputerCraft.

## Getting Started

### Install/Update

To install or update, run the following command:

```sh
wget run https://raw.githubusercontent.com/Possseidon/cc-code/main/code/update.lua
```

**WIP**: An `--update` flag for the main executable `code.lua` is planned.

### Start

To start `code` run:

```sh
code <filename>
```

### Shell Integration

To get autocompletion for files, add the following lines to your `startup.lua`:

```lua
local completion = require "cc.shell.completion"
shell.setCompletionFunction("code.lua", completion.build(completion.file))
```

To have the builtin `edit` use `code` instead, you can add the following line as well:

```lua
shell.run "alias edit /code"
```

**WIP**: These steps will get simplified soon.
