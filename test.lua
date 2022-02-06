--go@ x:\sdk\bin\windows\luajit.exe -lscite "X:\mm\test.lua" a b c
print(require'glue'.scriptname)
print('arg:', arg[0], arg[1])
print('...:', ...)
