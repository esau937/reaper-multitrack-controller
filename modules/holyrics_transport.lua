-- Bounded, ordered HTTP delivery. ExecProcess -1 starts curl without waiting.
local json = require('json')
local Transport = {}
Transport.__index = Transport

function Transport.new(api)
  return setmetatable({ api = api, channels = {}, sequence = 0, poll_at = 0 }, Transport)
end

function Transport:enqueue(target, action, payload)
  local url = (target.url or ''):match('^%s*(.-)%s*$'):gsub('/$', '')
  local token = (target.token or ''):match('^%s*(.-)%s*$')
  if not url:match('^https?://[%w%._%-]+:%d+$') or not token:match('^[%w_%-]+$') then
    return nil, 'Confira o endereço e o token do Holyrics.'
  end
  local key = url .. '?' .. token
  local channel = self.channels[key]
  if not channel then
    channel = { queue = {} }
    self.channels[key] = channel
  end
  local job = { target = target, action = action, payload = json.encode(payload),
    url = url .. '/api/' .. action .. '?token=' .. token }
  if action == 'ShowQuickPresentation' then
    channel.queue = { job }
  else
    -- Retain only the latest slide when a receiver is slow or unreachable.
    local last = channel.queue[#channel.queue]
    if last and last.action == action then channel.queue[#channel.queue] = job
    else channel.queue[#channel.queue + 1] = job end
  end
  target.status = { ok = false, message = 'Envio pendente.' }
  return true
end

function Transport:update()
  local now = self.api.time_precise()
  if now < self.poll_at then return end
  self.poll_at = now + 0.05
  for _, channel in pairs(self.channels) do
    local job = channel.active
    if job then
      local file = io.open(job.response, 'rb')
      local body = file and file:read('*a') or ''
      if file then file:close() end
      local result = json.decode(body)
      if result or now >= job.deadline then
        local accepted = type(result) == 'table' and result.status == 'ok'
        job.target.status = { ok = accepted, message = accepted and 'Recebido pelo Holyrics.'
          or 'Sem confirmação do Holyrics. Confira conexão e permissões.' }
        -- An unsuccessful presentation must not be followed by slide commands.
        if not accepted and job.action == 'ShowQuickPresentation' then channel.queue = {} end
        channel.active = nil
        channel.cooldown = accepted and now or now + 2
        -- curl has a 2-second lifetime; defer cleanup until it has closed files.
        self.cleanup = self.cleanup or {}
        self.cleanup[#self.cleanup + 1] = { at = job.deadline, job.request, job.response }
      end
    end
    if not channel.active and now >= (channel.cooldown or 0) and #channel.queue > 0 then
      job = table.remove(channel.queue, 1)
      self.sequence = self.sequence + 1
      local base = self.api.GetResourcePath() .. '/holyrics-async-' ..
        tostring(math.floor(now * 1000000)) .. '-' .. self.sequence
      job.request, job.response = base .. '.json', base .. '.response'
      local file = io.open(job.request, 'wb')
      if file then
        file:write(job.payload)
        file:close()
        local executable = (os.getenv('SystemRoot') or 'C:/Windows') .. '/System32/curl.exe'
        local command = '"' .. executable .. '" --silent --connect-timeout 1 --max-time 2' ..
          ' --request POST --header "Content-Type: application/json" --data-binary "@' ..
          job.request .. '" --output "' .. job.response .. '" "' .. job.url .. '"'
        local ok, output = pcall(self.api.ExecProcess, command, -1)
        if ok and output and output ~= '' then
          job.deadline = now + 3
          channel.active = job
        else
          os.remove(job.request)
          job.target.status = { ok = false, message = 'Falha ao iniciar envio.' }
          channel.queue = {}
        end
      else
        job.target.status = { ok = false, message = 'Falha ao preparar envio.' }
        channel.queue = {}
      end
    end
  end
  for i = #(self.cleanup or {}), 1, -1 do
    local entry = self.cleanup[i]
    if now >= entry.at then
      os.remove(entry[1])
      os.remove(entry[2])
      table.remove(self.cleanup, i)
    end
  end
end

return Transport
