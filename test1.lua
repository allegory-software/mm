--go@ x:\sdk\bin\windows\luajit.exe -lscite "X:\mm\test1.lua" a b c
require'glue'.luapath(require'fs'.scriptdir())
require'test'
