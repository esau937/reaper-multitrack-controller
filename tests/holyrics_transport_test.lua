package.path = 'modules/?.lua;lib/?.lua;' .. package.path
local Transport = require('holyrics_transport')
local json = require('json')
local now, calls, files = 0, {}, {}
local old_open, old_remove = io.open, os.remove
io.open = function(path, mode)
  if mode == 'wb' then
    return { write = function(_, data) files[path] = data end, close = function() end }
  end
  if files[path] then return { read = function() return files[path] end, close = function() end } end
end
os.remove = function(path) files[path] = nil end
local api = {
  time_precise = function() return now end,
  GetResourcePath = function() return 'C:/test path' end,
  ExecProcess = function(command, timeout)
    assert(timeout == -1, 'must never wait for a network request')
    assert(not command:find('cmd.exe', 1, true) and not command:find('start ', 1, true))
    assert(command:find('wscript.exe" //B //NoLogo', 1, true))
    assert(command:find('holyrics_hidden.vbs', 1, true))
    calls[#calls + 1] = command
    return '0'
  end
}
local target = { url = 'http://127.0.0.1:8091', token = 'test_token' }
local transport = Transport.new(api)
assert(transport:enqueue(target, 'ShowQuickPresentation', { slides = {{ text = 'Título\nLinha' }} }))
transport:update()
assert(#calls == 1 and not target.status.ok)
for i = 1, 50 do transport:enqueue(target, 'ActionGoToIndex', { index = i }) end
local channel = next(transport.channels)
channel = transport.channels[channel]
assert(#channel.queue == 1 and json.decode(channel.queue[1].payload).index == 50)
now = 0.1
transport:update()
assert(#calls == 1, 'no concurrent requests to the same receiver')
files[channel.active.response] = '{"status":"ok"}'
now = 0.2
transport:update()
assert(#calls == 2 and target.status.ok, 'advance only after presentation response')
-- A hung receiver times out; no unbounded retry/process creation.
now = 4
transport:update()
assert(not channel.active and not target.status.ok and #calls == 2)
now = 10
transport:update()
assert(next(files) == nil, 'temporary request and response files are cleaned')
-- A rejected presentation must not advance slides in an unrelated presentation.
transport:enqueue(target, 'ShowQuickPresentation', {})
now = 10.1
transport:update()
transport:enqueue(target, 'ActionGoToIndex', { index = 5 })
files[channel.active.response] = '{"status":"error"}'
now = 11
transport:update()
assert(#channel.queue == 0 and not target.status.ok)
-- Launch errors are surfaced instead of claiming delivery.
api.ExecProcess = function() return nil end
now = 14
transport:enqueue(target, 'ShowQuickPresentation', {})
transport:update()
assert(not channel.active and not target.status.ok)
io.open, os.remove = old_open, old_remove
print('holyrics_transport_test: passed')
