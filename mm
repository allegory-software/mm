#!/bin/sh
exec "${0%mm}../sdk/bin/linux/luajit" "${0%mm}mm.lua" "$@"
