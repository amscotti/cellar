-- A webhook receiver, which is the reference app for cellar: it needs a
-- signature header, idempotency, durable rows and a bounded table.
--
-- Deploy:
--   cellar deploy examples/webhook/app.lua --cell hook --server http://127.0.0.1:8199 --token t
-- Send (signs like Stripe does):
--   python3 examples/webhook/send.py

local M = {}

local SECRET = "whsec_demo_not_a_real_secret"
local MAX_EVENTS = 1000
local MAX_SKEW_S = 300

local function setup()
  db.exec([[create table if not exists events (
    id text primary key,
    type text,
    received_at integer not null,
    body text
  )]])
end

-- Stripe's scheme: `Stripe-Signature: t=<unix>,v1=<hex hmac-sha256 of "t.body">`.
-- The timestamp is inside the signed string, which is what stops a captured
-- request from being replayed later.
local function verify(body, headers)
  local sig = headers["stripe-signature"]
  if not sig then return false, "missing signature" end

  local t, v1
  for part in sig:gmatch("[^,]+") do
    local k, v = part:match("^%s*([%w]+)=(.*)$")
    if k == "t" then t = v elseif k == "v1" then v1 = v end
  end
  if not t or not v1 then return false, "malformed signature" end

  if crypto.hmac_sha256(SECRET, t .. "." .. body) ~= v1 then
    return false, "bad signature"
  end
  if math.abs(time.now_s() - tonumber(t)) > MAX_SKEW_S then
    return false, "stale timestamp"
  end
  return true
end

function M.hook(body, headers)
  setup()
  local ok, why = verify(body, headers or {})
  if not ok then return "reject:" .. why end

  local ev = json.decode(body)
  if type(ev) ~= "table" or type(ev.id) ~= "string" then
    return "reject:no id"
  end

  -- The primary key is the whole idempotency mechanism: the second delivery of
  -- an event cannot insert, and `changes()` tells us which case we are in.
  db.exec(
    "insert or ignore into events (id, type, received_at, body) values (?, ?, ?, ?)",
    ev.id, ev.type or "", time.now_ms(), body
  )
  local inserted = db.value("select changes()")

  -- Bounded growth: keep the newest MAX_EVENTS rows.
  db.run(
    "delete from events where id in (select id from events order by received_at desc limit -1 offset ?)",
    MAX_EVENTS
  )

  if inserted == 1 then
    return "accepted:" .. ev.id
  end
  return "duplicate:" .. ev.id
end

function M.count(_)
  setup()
  return tostring(db.value("select count(*) from events"))
end

return M
