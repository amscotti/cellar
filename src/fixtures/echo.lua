local count = 0
local M = {}

function M.echo(body)
  return "echo:" .. body
end

function M.incr(body)
  count = count + 1
  return tostring(count)
end

function M.get(body)
  return tostring(count)
end

function M.spin(body)
  local i = 0
  while true do i = i + 1 end
end

function M.mk(body)
  db.exec("create table if not exists t(x integer)")
  return "ok"
end

function M.add(body)
  db.exec("insert into t(x) values (?)", tonumber(body) or 1)
  return "ok"
end

function M.count(body)
  return tostring(db.value("select count(*) from t"))
end

function M.rows(body)
  local out = {}
  for i, r in ipairs(db.exec("select rowid, x from t order by rowid")) do
    out[i] = r.x
  end
  return table.concat(out, ",")
end

function M.boom(body)
  db.exec("insert into t(x) values (1)")
  error("boom")
end

function M.try_commit(body)
  local ok = pcall(function() db.exec("commit") end)
  return tostring(ok)
end

function M.try_attach(body)
  local ok = pcall(function() db.exec("attach database '/tmp/cellar-evil.db' as evil") end)
  return tostring(ok)
end

function M.try_pragma(body)
  local ok = pcall(function() db.exec("pragma journal_mode=OFF") end)
  return tostring(ok)
end

function M.mkbig(body)
  db.exec("create table if not exists big(b text)")
  return "ok"
end

function M.fillbig(body)
  local n = tonumber(body) or 1
  for i = 1, n do
    db.exec("insert into big(b) values (?)", string.rep("x", 4096))
  end
  return "ok"
end

function M.countbig(body)
  return tostring(db.value("select count(*) from big"))
end

function M.json_round(body)
  return json.encode(json.decode(body))
end

function M.hash(body)
  return crypto.sha256(body)
end

function M.hmac(body)
  return crypto.hmac_sha256("key", body)
end

function M.rand(_)
  return crypto.random(8)
end

function M.logs(_)
  log.info("hello from the guest")
  return "logged"
end

function M.clock(_)
  return tostring(time.now_ms() > 1700000000000)
end

local alarms_fired = 0

function M.set_alarm(body)
  local ms = tonumber(body) or 50
  alarm.set(ms)
  return "set"
end

function M.clear_alarm(_)
  alarm.clear()
  return "cleared"
end

function M.alarm_due(_)
  local d = alarm.get()
  if d == nil then return "none" end
  return tostring(d)
end

function M.on_alarm(_)
  alarms_fired = alarms_fired + 1
  return "fired"
end

function M.alarm_count(_)
  return tostring(alarms_fired)
end

function M.work(body)
  local ms = tonumber(body) or 100
  local start = time.now_ms()
  local n = 0
  while time.now_ms() - start < ms do n = n + 1 end
  return "done:" .. tostring(ms)
end

function M.hdr(_, headers)
  if headers == nil then return "no table" end
  return (headers["x-test"] or "none") .. "|" .. (headers["content-type"] or "none")
end

function M.fetch_echo(body)
  local ok, res = http.fetch(body)
  if not ok then return "err:" .. res end
  return res
end

function M.fetch_disabled(_)
  local ok, err = http.fetch("http://example.test/")
  return tostring(ok) .. ":" .. tostring(err)
end

-- Multi-statement input must be refused, not silently truncated to its first
-- statement. Returns "<ran>|<error>|<row count>" so the test can prove nothing
-- was written.
function M.two_statements(body)
  local ok, err = pcall(function()
    db.exec("insert into t(x) values (11); insert into t(x) values (12)")
  end)
  return tostring(ok) .. "|" .. tostring(err) .. "|" .. tostring(db.value("select count(*) from t"))
end

return M
