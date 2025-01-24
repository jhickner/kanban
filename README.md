# kanban

Very simple terminal kanban board backed by a toml file.
Cards can be moved between columns, all other editing happens in your editor.

```
arrows         move around between cards/columns
shift-arrows   change card order/column
e              edit the .toml file backing the board
ctrl-s         save
enter          if "link" is defined for the current card, open it
q              quit
space          toggle preview pane (shows desc field)
```
