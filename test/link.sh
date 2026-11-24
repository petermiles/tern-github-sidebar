#!/bin/sh
# Prints TEXT as an OSC 8 hyperlink to URL, as a coding agent's Markdown link shows in a terminal.
# usage: link.sh URL TEXT
printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$1" "$2"
