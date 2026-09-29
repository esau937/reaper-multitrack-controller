"""Run Lua 5.4 checks using the optional lupa package."""
import sys
from lupa.lua54 import LuaRuntime

runtime = LuaRuntime(unpack_returned_tuples=True)
runtime.execute('assert(loadfile("main.lua"))')
for filename in sys.argv[1:]:
    LuaRuntime().globals().dofile(filename)
