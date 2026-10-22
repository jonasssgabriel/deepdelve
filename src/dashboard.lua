-- DeepDelve | dashboard.lua
-- Touch control room for your turtle fleet (Advanced Monitor)
--
--  FROTA  lista de todas as Turtles (toque numa linha para abrir)
--  GERAL  combustivel, inventario, historico
--  MINA   progresso, tempo restante e MAPA da escavacao ao vivo
--  CTRL   pausar / continuar / voltar / cancelar, nova tarefa e memoria da area
--
-- Tudo e controlado por toque no monitor. Requires miner.lua on the Turtles.

---------------------------------------------------------------------
-- CONFIGURACAO
---------------------------------------------------------------------
local SENHA = nil                 -- mesma senha da Turtle (se ela usar)
local APENAS_IDS = nil            -- nil = todas. Ex: {0, 3, 7}
local META_COMBUSTIVEL = 3200     -- referencia da barra, NAO a capacidade
local TEMPO_OFFLINE = 8           -- segundos sem pacote = OFFLINE
local AMOSTRA_A_CADA = 3          -- segundos entre pontos do grafico
local HIST_MAX = 240
local LIMITE_TOTAL, LIMITE_DIM, MARGEM_MAX = 100000, 130, 119
local TITULO, SUBTITULO = 'DEEPDELVE', 'MINING FLEET CONTROL'
local ARQ_CFG = 'dashboard.cfg'

local PROTO = 'doscria.status.v1'
local CMD = 'doscria.comando.v6'
local RES = 'doscria.resposta.v6'

local mon = peripheral.find('monitor')
local modem = peripheral.find('modem', function(_, m) return m.isWireless and m.isWireless() end)
if not mon then error('Advanced Monitor nao encontrado. Conecte-o ao PC.') end
if not modem then error('Wireless Modem nao encontrado no PC.') end
rednet.open(peripheral.getName(modem))
mon.setTextScale(0.5)

---------------------------------------------------------------------
-- TEMA (as 16 cores do CC recebem RGB proprio)
---------------------------------------------------------------------
local BG, PANEL, EDGE, MUTED, TEXT = colors.black, colors.gray, colors.brown, colors.lightGray, colors.white
local ACC, OK, BAD, WARN, PUR = colors.cyan, colors.lime, colors.red, colors.orange, colors.purple
local HEAD, TAB, OKBG, BADBG = colors.blue, colors.lightBlue, colors.green, colors.magenta
local SPARK, TRACK = colors.pink, colors.yellow

local PALETA = {
  [BG]    = 0x070B13, [PANEL] = 0x111827, [EDGE]  = 0x1D2840, [MUTED] = 0x8793AB,
  [TEXT]  = 0xEEF1F8, [ACC]   = 0x22D3EE, [OK]    = 0x34D399, [BAD]   = 0xF87171,
  [WARN]  = 0xFBA43C, [PUR]   = 0xA78BFA, [HEAD]  = 0x0E1838, [TAB]   = 0x2563EB,
  [OKBG]  = 0x0C3A2D, [BADBG] = 0x43181C, [SPARK] = 0x1B6A82, [TRACK] = 0x2A3752,
}
local BLIT = {}
for c in pairs(PALETA) do BLIT[c] = colors.toBlit(c) end

---------------------------------------------------------------------
-- CANVAS EM PIXELS (cada celula = 2 colunas x 3 linhas de pixels)
-- Regra: no maximo 2 cores por celula.
---------------------------------------------------------------------
local win, W, H, PW, PH, P
local T = {} -- textos desenhados por cima do canvas

local function setup()
  W, H = mon.getSize()
  PW, PH = W * 2, H * 3
  win = window.create(mon, 1, 1, W, H, false)
  for c, rgb in pairs(PALETA) do
    mon.setPaletteColor(c, rgb)
    win.setPaletteColor(c, rgb)
  end
  P = {}
  for y = 1, PH do
    local r = {}
    for x = 1, PW do r[x] = BG end
    P[y] = r
  end
end

local function restorePalette()
  for c in pairs(PALETA) do
    pcall(function() mon.setPaletteColor(c, term.nativePaletteColor(c)) end)
  end
end

local function clearBuf()
  for y = 1, PH do
    local r = P[y]
    for x = 1, PW do r[x] = BG end
  end
  T = {}
end

local function rect(x, y, w, h, c)
  local x1, x2 = math.max(0, x), math.min(PW - 1, x + w - 1)
  for yy = math.max(0, y), math.min(PH - 1, y + h - 1) do
    local r = P[yy + 1]
    for xx = x1, x2 do r[xx + 1] = c end
  end
end

local function rrect(x, y, w, h, r, c)
  for i = 0, h - 1 do
    local d = math.min(i, h - 1 - i)
    local inset = (d < r) and (r - d) or 0
    rect(x + inset, y + i, w - 2 * inset, 1, c)
  end
end

local function cpx(cx) return (cx - 1) * 2 end
local function cpy(cy) return (cy - 1) * 3 end
local function crect(cx, cy, cw, ch, c, r)
  rrect(cpx(cx), cpy(cy), cw * 2, ch * 3, r or 0, c)
end

-- painel com cantos suaves e um fio de luz no topo
local function panel(cx, cy, cw, ch, bg)
  crect(cx, cy, cw, ch, bg or PANEL, 1)
  if cw >= 5 then rect(cpx(cx) + 2, cpy(cy), cw * 2 - 4, 1, EDGE) end
end

---------------------------------------------------------------------
-- FONTE GRANDE 3x5 (numeros e algumas letras)
---------------------------------------------------------------------
local FONT = {
  ['0'] = { '111', '101', '101', '101', '111' },
  ['1'] = { '010', '110', '010', '010', '111' },
  ['2'] = { '111', '001', '111', '100', '111' },
  ['3'] = { '111', '001', '111', '001', '111' },
  ['4'] = { '101', '101', '111', '001', '001' },
  ['5'] = { '111', '100', '111', '001', '111' },
  ['6'] = { '111', '100', '111', '101', '111' },
  ['7'] = { '111', '001', '001', '010', '010' },
  ['8'] = { '111', '101', '111', '101', '111' },
  ['9'] = { '111', '101', '111', '001', '111' },
  ['.'] = { '0', '0', '0', '0', '1' },
  ['-'] = { '000', '000', '111', '000', '000' },
  [':'] = { '0', '1', '0', '1', '0' },
  ['/'] = { '001', '001', '010', '100', '100' },
  ['%'] = { '101', '001', '010', '100', '101' },
  ['H'] = { '101', '101', '111', '101', '101' },
  ['S'] = { '011', '100', '010', '001', '110' },
  ['X'] = { '101', '101', '010', '101', '101' },
  ['M'] = { '10001', '11011', '10101', '10001', '10001' },
  [' '] = { '00', '00', '00', '00', '00' },
}

local function bigOK(str)
  for i = 1, #str do
    if not FONT[str:sub(i, i)] then return false end
  end
  return true
end

local function bigW(str, s)
  local w = 0
  for i = 1, #str do
    w = w + #FONT[str:sub(i, i)][1] * s
    if i < #str then w = w + s end
  end
  return w
end

local function bigText(str, x, y, s, c)
  for i = 1, #str do
    local g = FONT[str:sub(i, i)]
    for row = 1, 5 do
      local line = g[row]
      for col = 1, #line do
        if line:sub(col, col) == '1' then rect(x + (col - 1) * s, y + (row - 1) * s, s, s, c) end
      end
    end
    x = x + #g[1] * s + s
  end
end

---------------------------------------------------------------------
-- TEXTO E UTILITARIOS
---------------------------------------------------------------------
local function cut(s, n)
  s = tostring(s == nil and '--' or s)
  if n < 1 then return '' end
  if #s > n then return s:sub(1, math.max(1, n - 2)) .. '..' end
  return s
end

local function txt(cx, cy, s, fg, maxw)
  if cy < 1 or cy > H or cx < 1 or cx > W then return end
  s = cut(s, math.min(maxw or W, W - cx + 1))
  if s == '' then return end
  T[#T + 1] = { cx, cy, s, fg }
end

local function wrap(s, n)
  local out, line = {}, ''
  for word in s:gmatch('%S+') do
    if line ~= '' and #line + 1 + #word > n then
      out[#out + 1] = line
      line = word
    else
      line = (line == '') and word or (line .. ' ' .. word)
    end
  end
  if line ~= '' then out[#out + 1] = line end
  return out
end

local function fmt(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub('(%d%d%d)', '%1.'):reverse()
  return (out:gsub('^%.', ''))
end

local function fmtEta(s)
  s = math.floor(s)
  if s >= 3600 then return math.floor(s / 3600) .. 'H' .. string.format('%02d', math.floor(s % 3600 / 60)) end
  if s >= 60 then return math.floor(s / 60) .. 'M' end
  return s .. 'S'
end

-- converte o canvas em caracteres teletext (128-159) e envia ao monitor
local function flush()
  for cy = 1, H do
    local r1, r2, r3 = P[3 * cy - 2], P[3 * cy - 1], P[3 * cy]
    local ch, fgs, bgs = {}, {}, {}
    for cx = 1, W do
      local i = 2 * cx
      local a, b, c, d, e, f = r1[i - 1], r1[i], r2[i - 1], r2[i], r3[i - 1], r3[i]
      if a == b and b == c and c == d and d == e and e == f then
        ch[cx] = ' '
        fgs[cx] = BLIT[f]
        bgs[cx] = BLIT[f]
      else
        local fg = a
        if fg == f then fg = b end
        if fg == f then fg = c end
        if fg == f then fg = d end
        if fg == f then fg = e end
        local bits = 0
        if a ~= f then bits = bits + 1 end
        if b ~= f then bits = bits + 2 end
        if c ~= f then bits = bits + 4 end
        if d ~= f then bits = bits + 8 end
        if e ~= f then bits = bits + 16 end
        ch[cx] = string.char(128 + bits)
        fgs[cx] = BLIT[fg]
        bgs[cx] = BLIT[f]
      end
    end
    win.setCursorPos(1, cy)
    win.blit(table.concat(ch), table.concat(fgs), table.concat(bgs))
  end
  for _, t in ipairs(T) do
    local cx, cy, s, fg = t[1], t[2], t[3], t[4]
    local bgs = {}
    for i = 1, #s do bgs[i] = BLIT[P[3 * cy][2 * (cx + i - 1)]] end
    win.setCursorPos(cx, cy)
    win.blit(s, BLIT[fg]:rep(#s), table.concat(bgs))
  end
end

---------------------------------------------------------------------
-- ESTADO
---------------------------------------------------------------------
local turtles = {}     -- [id] = {id, dado, recebidoEm, pacotes, hist, ultima}
local sel = nil        -- Turtle selecionada
local pagina = 1       -- 1 FROTA, 2 GERAL, 3 MINA, 4 CTRL
local fleetPage = 1
local zones = {}
local toast = nil      -- {text, color, ate}
local armCancel = -100 -- instante em que CANCELAR foi armado
local form = { esq = 0, dir = 2, frente = 2, cima = 2, baixo = 0, ordem = 'auto', preset = 1, reescavar = false }
local PRESETS = {
  { nome = 'CUBO 3x3x3', esq = 0, dir = 2, frente = 2, cima = 2, baixo = 0 },
  { nome = 'SALA 5x5x5', esq = 0, dir = 4, frente = 4, cima = 4, baixo = 0 },
  { nome = 'SALA 9x9x5', esq = 4, dir = 4, frente = 8, cima = 4, baixo = 0 },
  { nome = 'SALA 11x13x7', esq = 0, dir = 10, frente = 12, cima = 6, baixo = 0 },
  { nome = 'TUNEL 3x3x20', esq = 1, dir = 1, frente = 19, cima = 2, baixo = 0 },
  { nome = 'POCO 3x3 DESCE 20', esq = 1, dir = 1, frente = 2, cima = 0, baixo = 20 },
  { nome = 'LIVRE (MARGENS)' },
}
local armMem = -100

-- "Turtle atual": preenchidas a cada desenho
local dado, recebidoEm, pacotes, hist, curT = nil, nil, 0, {}, nil

local function isActive(t)
  return t and t.dado and t.recebidoEm and (os.clock() - t.recebidoEm) < TEMPO_OFFLINE
end

local function active()
  return dado and recebidoEm and (os.clock() - recebidoEm) < TEMPO_OFFLINE
end

local function sortedIds()
  local ids = {}
  for id in pairs(turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function zone(x1, y1, x2, y2, fn)
  zones[#zones + 1] = { x1, y1, x2, y2, fn }
end

local function ratioColor(r)
  if r >= 0.5 then return OK end
  if r >= 0.2 then return WARN end
  return BAD
end

local function stateColor(st)
  st = tostring(st or '')
  if st:find('MINER') then return OK end
  if st:find('CONCLU') then return ACC end
  if st:find('PAUS') or st:find('INVENT') or st:find('COMBUST') or st:find('PERIGO') or st:find('CANCEL')
    or st:find('CONFIRM') or st:find('VOLTANDO') or st:find('DESCARREG') or st:find('RETOMANDO')
    or st:find('REABAST') or st:find('NA BASE') or st:find('BAU') or st:find('SEGURO') then return WARN end
  if st:find('ERRO') then return BAD end
  return MUTED
end

local function busyStatus(st)
  st = tostring(st or '')
  return st:find('MINER') or st:find('PAUS') or st:find('INVENT') or st:find('COMBUST') or st:find('PERIGO')
    or st:find('CONFIRM') or st:find('VOLTANDO') or st:find('DESCARREG') or st:find('RETOMANDO')
    or st:find('REABAST') or st:find('NA BASE') or st:find('BAU CHEIO') or st:find('SEM BAU')
end

local function setToast(text, color, secs)
  toast = { text = text, color = color, ate = os.clock() + (secs or 12) }
end

local function saveCfg()
  pcall(function()
    local f = fs.open(ARQ_CFG, 'w')
    f.write(textutils.serialize({ esq = form.esq, dir = form.dir, frente = form.frente, cima = form.cima,
      baixo = form.baixo, ordem = form.ordem, preset = form.preset, reescavar = form.reescavar }))
    f.close()
  end)
end

local function loadCfg()
  pcall(function()
    if not fs.exists(ARQ_CFG) then return end
    local f = fs.open(ARQ_CFG, 'r')
    local d = textutils.unserialize(f.readAll())
    f.close()
    if type(d) == 'table' then
      for _, k in ipairs({ 'esq', 'dir', 'frente', 'cima', 'baixo' }) do
        form[k] = math.max(0, math.min(MARGEM_MAX, tonumber(d[k]) or form[k]))
      end
      if d.ordem == 'cima' or d.ordem == 'baixo' or d.ordem == 'auto' then form.ordem = d.ordem end
      form.preset = math.max(1, math.min(#PRESETS, tonumber(d.preset) or form.preset))
      form.reescavar = d.reescavar == true
    end
  end)
end

local function sendCmd(id, tbl)
  tbl.senha = SENHA
  rednet.send(id, tbl, CMD)
end

---------------------------------------------------------------------
-- CABECALHO, ABAS E RODAPE
---------------------------------------------------------------------
local HEAD_ROWS = 8
local GEM = { '..XXXX..', '.XXXXXX.', 'XXXXXXXX', '.XXXXXX.', '..XXXX..', '...XX...' }
local TABS = { 'FROTA', 'GERAL', 'MINA', 'CTRL' }

local function drawHeader(pillOK, label, tok, alerts)
  rect(0, 0, PW, HEAD_ROWS * 3, HEAD)
  rect(0, HEAD_ROWS * 3 - 1, PW, 1, TAB)

  -- espaco para o titulo (e o logo, se couber) antes da pilula
  local titleEnd = ((W >= 44) and 8 or 3) + 19
  if #label + 4 > W - 1 - (titleEnd + 1) then label = label:gsub(' ONLINE', ' ON') end
  local pw = #label + 4
  local px = W - pw - 1
  crect(px, 2, pw, 3, pillOK and OKBG or BADBG, 2)
  local blink = pillOK and (math.floor(os.clock()) % 2 == 0)
  txt(px + 1, 3, '\7', pillOK and (blink and OK or TRACK) or BAD)
  txt(px + 3, 3, label, pillOK and OK or BAD)

  local tx = 3
  if W >= 44 then
    for r = 1, #GEM do
      local line = GEM[r]
      for c = 1, #line do
        if line:sub(c, c) == 'X' then rect(cpx(3) + c - 1, cpy(2) + r - 1, 1, 1, ACC) end
      end
    end
    tx = 8
  end
  txt(tx, 2, TITULO, TEXT)
  local avail = px - 1 - tx
  local sub = SUBTITULO
  if avail < #sub then sub = SUBTITULO:sub(1, avail) end
  txt(tx, 3, sub, ACC, avail)

  -- abas
  local pad = 4
  local function total(p)
    local s = 0
    for _, l in ipairs(TABS) do s = s + #l + p end
    return s + #TABS - 1
  end
  if 3 + total(4) > W - 1 then pad = 3 end
  if 3 + total(3) > W - 1 then pad = 2 end
  local x = 3
  for i, l in ipairs(TABS) do
    local tw = #l + pad
    local ativa = (i == pagina) or (pagina == 5 and i == 4)
    if ativa then crect(x, 5, tw, 3, TAB, 2) end
    txt(x + math.floor(pad / 2), 6, l, ativa and TEXT or MUTED)
    if i == 1 and alerts > 0 and pad >= 3 then txt(x + tw - 2, 6, '!', BAD) end
    zone(x, 4, x + tw - 1, HEAD_ROWS, function() pagina = i end)
    x = x + tw + 1
  end
  if W >= 54 and sel ~= nil and pagina > 1 then
    local s = 'TURTLE #' .. sel
    if W >= 72 and tok and dado.horario then s = s .. '   ' .. tostring(dado.horario) end
    txt(W - #s - 1, 6, s, MUTED)
  end
end

local function drawFooter(ok, fleet, on, total)
  crect(1, H, W, 1, PANEL, 0)
  local msg
  if fleet then
    msg = total == 0 and 'AGUARDANDO TURTLES' or (on .. '/' .. total .. ' ONLINE')
  elseif ok then
    msg = 'TELEMETRIA ATIVA  ' .. math.floor(os.clock() - recebidoEm) .. 's'
  else
    msg = 'AGUARDANDO TURTLE'
  end
  local left = 'TOQUE NAS ABAS OU NOS CARTOES PARA NAVEGAR'
  if 2 + #left + 3 + #msg > W then left = 'PAG ' .. pagina .. '/4' end
  txt(2, H, left, MUTED)
  txt(W - #msg, H, msg, ok and OK or BAD)
end

---------------------------------------------------------------------
-- SECOES (cada uma tem altura minima/completa em celulas)
---------------------------------------------------------------------
local x0, cw, lw, rw, rx

local function runSections(y, secs)
  local limit = H - 2
  for i, sec in ipairs(secs) do
    if sec then
      local reserve = 0
      for j = i + 1, #secs do
        if secs[j] then reserve = reserve + secs[j].min + 1 end
      end
      local hh
      if y + sec.full - 1 + reserve <= limit then
        hh = sec.full
      else
        local avail = limit - y + 1 - reserve
        if sec.shrink and avail >= sec.min then
          hh = avail
        elseif y + sec.min - 1 <= limit then
          hh = sec.min
        end
      end
      if hh then
        sec.draw(y, hh)
        y = y + hh + 1
      end
    end
  end
end

local function infoSection(items)
  return {
    min = 4, full = 5,
    draw = function(y, hh)
      local cols = { { x0, lw }, { rx, rw } }
      for i, it in ipairs(items) do
        local x, w = cols[i][1], cols[i][2]
        panel(x, y, w, hh)
        txt(x + 2, y + 1, it.label, MUTED, w - 3)
        txt(x + 2, y + hh - 2, it.value, it.color, w - 3)
      end
    end,
  }
end

-- numeros grandes: escala 2 se couber e houver altura, senao 1, senao texto
local function metricSection(items)
  local cols = { { x0, lw }, { rx, rw } }
  local fit1, fit2 = true, true
  for i, it in ipairs(items) do
    if not bigOK(it.str) then
      fit1, fit2 = false, false
    else
      local inner = (cols[i][2] - 4) * 2
      if bigW(it.str, 1) > inner then fit1 = false end
      if bigW(it.str, 2) > inner then fit2 = false end
    end
  end
  return {
    min = 5, full = fit2 and 7 or 5,
    draw = function(y, hh)
      local s = fit1 and ((hh >= 7 and fit2) and 2 or 1) or 0
      for i, it in ipairs(items) do
        local x, w = cols[i][1], cols[i][2]
        panel(x, y, w, hh)
        txt(x + 2, y + 1, it.label, MUTED, w - 3)
        if s > 0 then
          local off = math.floor(((hh - 3) * 3 - 5 * s) / 2)
          bigText(it.str, cpx(x + 2), cpy(y + 2) + off, s, it.color)
        else
          txt(x + 2, y + 3, it.str, it.color, w - 3)
        end
      end
    end,
  }
end

local function bar(bx, by, bw, ratio, col)
  rect(cpx(bx), cpy(by), bw * 2, 3, TRACK)
  local fw = math.floor(bw * 2 * math.max(0, math.min(1, ratio)) + 0.5)
  if fw > 0 then rect(cpx(bx), cpy(by), fw, 3, col) end
  return fw
end

local function fuelSection(ok, fuelNum)
  return {
    min = 5, full = 8,
    draw = function(y, hh)
      local ratio = (fuelNum and META_COMBUSTIVEL > 0) and math.max(0, math.min(1, fuelNum / META_COMBUSTIVEL)) or 0
      local col = ok and ratioColor(ratio) or TRACK
      panel(x0, y, cw, hh)
      txt(x0 + 2, y + 1, 'COMBUSTIVEL', MUTED)
      if ok and fuelNum then txt(x0 + 14, y + 1, math.floor(ratio * 100 + 0.5) .. '%', col) end
      if cw >= 30 then
        local meta = 'META ' .. fmt(META_COMBUSTIVEL)
        txt(x0 + cw - #meta - 2, y + 1, meta, MUTED)
      end
      local bx, bw = x0 + 2, cw - 4
      bar(bx, y + 3, bw, ratio, col)
      if hh >= 8 then
        local width, base, height = bw * 2, cpy(y + 5) + 5, 6
        local n = math.min(#hist, width)
        for i = 1, n do
          local v = hist[#hist - n + i]
          local hgt = math.floor(height * math.min(1, v / math.max(1, META_COMBUSTIVEL)) + 0.5)
          if v > 0 and hgt < 1 then hgt = 1 end
          if hgt > 0 then rect(cpx(bx) + (width - n) + (i - 1), base - hgt + 1, 1, hgt, SPARK) end
        end
      end
    end,
  }
end

local function slotsSection(ok)
  local inner = cw - 4
  local single = inner >= 47
  local hh = single and 5 or 7
  return {
    min = hh, full = hh,
    draw = function(y)
      local n = ok and math.max(0, math.min(16, tonumber(dado.slots) or 0)) or 0
      panel(x0, y, cw, hh)
      txt(x0 + 2, y + 1, 'SLOTS OCUPADOS', MUTED)
      local right = ok and (n .. ' / 16') or '-- / 16'
      txt(x0 + cw - #right - 2, y + 1, right, ok and ((n >= 16) and WARN or TEXT) or MUTED)
      local per = single and 16 or 8
      local k = single and math.min(3, math.floor((inner - 15) / 16)) or math.min(4, math.floor((inner - 7) / 8))
      k = math.max(1, k)
      local total = per * k + (per - 1)
      local sx = x0 + 2 + math.floor((inner - total) / 2)
      for i = 0, 15 do
        local r, c = math.floor(i / per), i % per
        local filled = ok and i < n
        local col = filled and ((n >= 16) and WARN or ACC) or TRACK
        rect(cpx(sx + c * (k + 1)), cpy(y + 3 + r * 2), k * 2, 3, col)
      end
    end,
  }
end

-- faixa de alerta: toast de comando > alerta da Turtle > offline (ate 2 linhas)
local function bannerSection(ok)
  local msg, col
  if toast and os.clock() < toast.ate then
    msg, col = toast.text, toast.color
  elseif curT and not ok then
    msg, col = 'SEM SINAL: a Turtle esta offline.', BAD
  elseif ok and tostring(dado.alerta or '') ~= '' then
    msg, col = tostring(dado.alerta), (tostring(dado.status or ''):find('ERRO') and BAD or WARN)
  elseif ok and dado.pausada then
    msg, col = 'Pausada pelo operador.', WARN
  end
  if not msg then return false end
  local lines = wrap(msg, cw - 5)
  if #lines > 2 then lines = { lines[1], cut(table.concat(lines, ' ', 2), cw - 5) } end
  local hh = 2 + #lines
  return {
    min = hh, full = hh,
    draw = function(y)
      local bg = (col == OK) and OKBG or ((col == MUTED) and PANEL or BADBG)
      crect(x0, y, cw, hh, bg, 1)
      txt(x0 + 2, y + 1, (col == OK or col == MUTED) and '\7' or '!', col)
      for i, l in ipairs(lines) do txt(x0 + 4, y + i, l, TEXT, cw - 5) end
    end,
  }
end

-- seletor de Turtle:  <  #3  Nome  2/5  >
local function selectorSection()
  return {
    min = 1, full = 1,
    draw = function(y)
      local ids = sortedIds()
      local idx = 0
      for i, id in ipairs(ids) do if id == sel then idx = i end end
      crect(x0, y, cw, 1, PANEL, 0)
      local s
      if sel == nil then
        s = 'NENHUMA TURTLE'
      else
        s = '#' .. sel .. '  ' .. tostring(dado and dado.nome or '--') .. '  ' .. idx .. '/' .. #ids
      end
      s = cut(s, cw - 10)
      txt(x0 + math.floor((cw - #s) / 2), y, s, sel and TEXT or MUTED)
      local multi = #ids > 1
      local function step(d)
        return function()
          local n = #ids
          if n > 0 then sel = ids[((idx - 1 + d) % n) + 1] end
        end
      end
      txt(x0 + 2, y, '<', multi and ACC or TRACK)
      txt(x0 + cw - 3, y, '>', multi and ACC or TRACK)
      if multi then
        zone(x0, y - 1, x0 + 5, y + 1, step(-1))
        zone(x0 + cw - 6, y - 1, x0 + cw - 1, y + 1, step(1))
      end
    end,
  }
end

-- progresso grande + tempo restante + barra animada
local function heroSection(ok)
  local pct = ok and (tonumber(dado.progresso) or 0) or 0
  local pctStr = ok and (math.floor(pct) .. '%') or '--'
  local eta = ok and tonumber(dado.eta)
  local etaStr = eta and fmtEta(eta) or '--'
  local inner = (cw - 4) * 2
  local okBig = bigOK(pctStr) and bigOK(etaStr)
  local fit1 = okBig and (bigW(pctStr, 1) + bigW(etaStr, 1) + 6 <= inner)
  local fit2 = okBig and (bigW(pctStr, 2) + bigW(etaStr, 2) + 6 <= inner)
  return {
    min = 5, full = fit2 and 9 or (fit1 and 7 or 5),
    draw = function(y, hh)
      local col = ok and stateColor(dado.status) or TRACK
      panel(x0, y, cw, hh)
      if hh >= 7 then
        txt(x0 + 2, y + 1, 'PROGRESSO', MUTED)
        local lab = (cw >= 34) and 'TEMPO RESTANTE' or 'ETA'
        txt(x0 + cw - #lab - 2, y + 1, lab, MUTED)
        local s = (hh >= 9) and 2 or 1
        local nh = (hh >= 9) and 4 or 2
        local off = math.floor((nh * 3 - 5 * s) / 2)
        bigText(pctStr, cpx(x0 + 2), cpy(y + 2) + off, s, ok and TEXT or MUTED)
        bigText(etaStr, cpx(x0 + cw - 2) - bigW(etaStr, s), cpy(y + 2) + off, s, ok and ACC or MUTED)
      else
        local line = 'PROGRESSO ' .. pctStr .. '    ETA ' .. etaStr
        txt(x0 + 2, y + 1, line, ok and TEXT or MUTED, cw - 4)
      end
      local bx, bw = x0 + 2, cw - 4
      local by = y + hh - 2
      local fw = bar(bx, by, bw, pct / 100, col)
      -- ponta da barra pisca enquanto minera (alinhada a celula: so 2 cores)
      if ok and tostring(dado.status or ''):find('MINER') and fw >= 4 then
        local fe = fw - (fw % 2)
        rect(cpx(bx) + fe - 2, cpy(by), 2, 3, (math.floor(os.clock()) % 2 == 0) and TEXT or col)
        if fw % 2 == 1 then rect(cpx(bx) + fe, cpy(by), 1, 3, TRACK) end
      end
    end,
  }
end

-- mapa do plano atual (vista de cima), enviado pela Turtle
local function mapSection(ok)
  return {
    min = 9, full = 22, shrink = true,
    draw = function(y, hh)
      panel(x0, y, cw, hh)
      local b = dado and dado.caixa
      local mapa = dado and dado.mapa
      if not (ok and type(b) == 'table' and type(mapa) == 'table') then
        txt(x0 + 2, y + 1, 'MAPA DA ESCAVACAO', MUTED)
        txt(x0 + 2, y + 3, ok and 'Nenhuma escavacao em andamento.' or 'Sem dados da Turtle.', MUTED, cw - 4)
        return
      end
      local w, l = b.x1 - b.x0 + 1, b.z1 + 1
      txt(x0 + 2, y + 1, 'MAPA  NIVEL Y=' .. tostring(mapa.y) .. '  (B = BAU)', MUTED, cw - 4)
      local lim = {}
      for _, r in ipairs(mapa.runs or {}) do
        for xx = r[2], r[3] do lim[(xx - b.x0) * 128 + r[1]] = true end
      end
      local wide = cw >= 40
      local infoW = wide and 17 or 0
      local mapCW = cw - 4 - (wide and (infoW + 1) or 0)
      local mapCH = hh - 3
      local ax, ay = x0 + 2, y + 2
      local aw, ah = mapCW * 2, mapCH * 3
      local tw, th
      if w <= aw and l <= ah then
        local sc = math.max(1, math.min(math.floor(aw / w), math.floor(ah / l)))
        tw, th = w * sc, l * sc
      else
        local f = math.max(w / aw, l / ah)
        tw, th = math.max(1, math.floor(w / f)), math.max(1, math.floor(l / f))
      end
      local cwid, chei = math.ceil(tw / 2), math.ceil(th / 3)
      tw, th = cwid * 2, chei * 3
      local ox = ax + math.floor((mapCW - cwid) / 2)
      local oy = ay + math.floor((mapCH - chei) / 2)
      rect(cpx(ox), cpy(oy), cwid * 2, chei * 3, TRACK)
      local px0, py0 = cpx(ox), cpy(oy)
      for j = 0, th - 1 do
        local bz = l - 1 - math.floor(j * l / th)
        local row = P[py0 + j + 1]
        for i = 0, tw - 1 do
          local bx = math.floor(i * w / tw)
          if lim[bx * 128 + bz] then row[px0 + i + 1] = ACC end
        end
      end
      local function cell(xx, zz)
        local mx = math.floor(((xx - b.x0) + 0.5) * tw / w)
        local my = math.floor((l - 1 - zz + 0.5) * th / l)
        return ox + math.floor(mx / 2), oy + math.floor(my / 3)
      end
      local bx, by = cell(0, 0)
      txt(bx, by, 'B', TEXT)
      local tx, ty = cell(tonumber(dado.x) or 0, tonumber(dado.z) or 0)
      txt(tx, ty, '\7', WARN)

      if wide then
        local ix = x0 + cw - infoW - 1
        local items = {
          { 'BLOCOS ESCAVADOS', fmt(tonumber(dado.blocos) or 0) },
          { 'VELOCIDADE', (dado.vel and (dado.vel .. ' blocos/min') or '--') },
          { 'POSICAO', 'x' .. (dado.x or '-') .. ' y' .. (dado.y or '-') .. ' z' .. (dado.z or '-') },
          { 'VIAGENS AO BAU', tostring(dado.viagens or 0) .. '   DIST ' .. tostring(dado.distBase or 0) },
          { 'AREA', w .. 'x' .. l .. 'x' .. (b.y1 - b.y0 + 1) },
        }
        local ry = y + 2
        for _, it in ipairs(items) do
          if ry + 1 <= y + hh - 2 then
            txt(ix, ry, it[1], MUTED, infoW)
            txt(ix, ry + 1, it[2], TEXT, infoW)
            ry = ry + 3
          end
        end
      end
    end,
  }
end

---------------------------------------------------------------------
-- CONTROLE (botoes)
---------------------------------------------------------------------
local function button(x, y, w, h, label, bg, fg, fn)
  crect(x, y, w, h, bg, 1)
  local ty = y + math.floor((h - 1) / 2)
  txt(x + math.floor((w - #label) / 2), ty, label, fg)
  if fn then zone(x, y, x + w - 1, y + h - 1, fn) end
end

-- botao de passo: "-"/"+" e, nos botoes grandes, o numero (-5 / +5)
local function stepGlyph(x, y, w, h, delta, col)
  local plus = delta > 0
  local mag = math.abs(delta)
  if h < 2 then
    txt(x + math.floor((w - (mag > 1 and 2 or 1)) / 2), y, (plus and '+' or '-') .. (mag > 1 and tostring(mag) or ''), col)
    return
  end
  local sign = 3
  local total = sign + (mag > 1 and (1 + 3) or 0)
  local gx = cpx(x) + math.floor((w * 2 - total) / 2)
  local gy = cpy(y) + math.floor((h * 3 - 5) / 2)
  local sy = gy + 1
  rect(gx, sy + 1, sign, 1, col)
  if plus then rect(gx + 1, sy, 1, sign, col) end
  if mag > 1 then bigText(tostring(mag), gx + sign + 1, gy, 1, col) end
end

local function acoesSection(ok)
  return {
    min = 7, full = 7,
    draw = function(y)
      local bw = math.floor((cw - 1) / 2)
      local bw2 = cw - 1 - bw
      local x2 = x0 + bw + 1
      local armed = (os.clock() - armCancel) < 5
      local function act(name, msg)
        return function()
          if not ok then return end
          sendCmd(sel, { action = name })
          setToast(msg, MUTED, 6)
        end
      end
      button(x0, y, bw, 3, 'PAUSAR', ok and TRACK or PANEL, ok and WARN or MUTED, act('pausar', 'Comando PAUSAR enviado.'))
      button(x2, y, bw2, 3, 'CONTINUAR', ok and OKBG or PANEL, ok and OK or MUTED, act('continuar', 'Comando CONTINUAR enviado.'))
      button(x0, y + 4, bw, 3, 'VOLTAR AO BAU', ok and TRACK or PANEL, ok and ACC or MUTED, act('voltar', 'Voltando ao bau e aguardando.'))
      button(x2, y + 4, bw2, 3, armed and 'CONFIRMAR?' or 'CANCELAR', ok and BADBG or PANEL, ok and BAD or MUTED, function()
        if not ok then return end
        if (os.clock() - armCancel) < 5 then
          sendCmd(sel, { action = 'cancelar' })
          setToast('Cancelando: voltando ao bau e encerrando.', WARN, 6)
          armCancel = -100
        else
          armCancel = os.clock()
          setToast('Toque de novo em CANCELAR para confirmar.', WARN, 5)
        end
      end)
    end,
  }
end

local function novaBtnSection()
  return {
    min = 3, full = 3,
    draw = function(y)
      button(x0, y, cw, 3, 'NOVA TAREFA DE ESCAVACAO', TAB, TEXT, function() pagina = 5 end)
    end,
  }
end

local function memSection(ok)
  return {
    min = 7, full = 7,
    draw = function(y)
      panel(x0, y, cw, 7)
      txt(x0 + 2, y + 1, 'MEMORIA DA AREA ESCAVADA', MUTED, cw - 4)
      local n = ok and tonumber(dado.memoria) or nil
      txt(x0 + 2, y + 2, n and (fmt(n) .. ' blocos lembrados (nao escava de novo)') or '--', n and TEXT or MUTED, cw - 4)
      local armed = (os.clock() - armMem) < 5
      button(x0 + 2, y + 3, cw - 4, 3, armed and 'CONFIRMAR? APAGAR MEMORIA' or 'ESQUECER AREA ESCAVADA',
        ok and BADBG or PANEL, ok and BAD or MUTED, function()
          if not ok then return end
          if (os.clock() - armMem) < 5 then
            sendCmd(sel, { action = 'esquecer' })
            setToast('Pedido para esquecer a area enviado.', WARN, 6)
            armMem = -100
          else
            armMem = os.clock()
            setToast('Toque de novo para APAGAR a memoria (Turtle olhando para a frente).', WARN, 6)
          end
        end)
    end,
  }
end

---------------------------------------------------------------------
-- NOVA TAREFA (margens a partir da Turtle)
---------------------------------------------------------------------
local function dims() return form.esq + form.dir + 1, form.frente + 1, form.cima + form.baixo + 1 end

local function setPreset(i)
  local p = PRESETS[i]
  form.preset = i
  if p.esq then form.esq, form.dir, form.frente, form.cima, form.baixo = p.esq, p.dir, p.frente, p.cima, p.baixo end
  saveCfg()
end

local function setPos(m)
  local w = form.esq + form.dir + 1
  if m == 'E' then form.esq, form.dir = 0, w - 1
  elseif m == 'D' then form.esq, form.dir = w - 1, 0
  else
    form.esq = math.floor((w - 1) / 2)
    form.dir = w - 1 - form.esq
  end
  form.preset = #PRESETS
  saveCfg()
end

local function adjust(key, delta)
  local old = form[key]
  form[key] = math.max(0, math.min(MARGEM_MAX, old + delta))
  local w, l, h = dims()
  if w * l * h > LIMITE_TOTAL or w > LIMITE_DIM or l > LIMITE_DIM or h > LIMITE_DIM then
    form[key] = old
    setToast('Limite: ' .. LIMITE_DIM .. ' por lado, ' .. fmt(LIMITE_TOTAL) .. ' blocos.', WARN, 4)
    return
  end
  form.preset = #PRESETS
  saveCfg()
end

local function novaSection(ok)
  local can = ok and not busyStatus(dado and dado.status)
  return {
    min = 23, full = 32, shrink = true,
    draw = function(y, hh)
      panel(x0, y, cw, hh)
      local sh, gap = 1, 0
      if hh >= 32 then sh, gap = 2, 1 elseif hh >= 27 then sh, gap = 1, 1 end
      local inner = cw - 4

      -- modo (predefinicoes)
      local p = PRESETS[form.preset] or PRESETS[#PRESETS]
      txt(x0 + 2, y + 1, 'MODO', MUTED)
      txt(x0 + 8, y + 1, '<', ACC)
      txt(x0 + cw - 3, y + 1, '>', ACC)
      txt(x0 + 10, y + 1, p.nome, TEXT, cw - 14)
      zone(x0 + 6, y, x0 + 9, y + 2, function() setPreset((form.preset - 2) % #PRESETS + 1) end)
      zone(x0 + cw - 6, y, x0 + cw - 1, y + 2, function() setPreset(form.preset % #PRESETS + 1) end)

      -- onde a Turtle esta na largura
      txt(x0 + 2, y + 3, 'TURTLE FICA NA', MUTED)
      local atual = (form.esq == 0 and 'E') or ((form.dir == 0) and 'D' or 'M')
      local pw = math.floor((inner - 2) / 3)
      local nomes = (pw >= 8) and { 'ESQUERDA', 'MEIO', 'DIREITA' } or { 'ESQ.', 'MEIO', 'DIR.' }
      local chaves = { 'E', 'M', 'D' }
      for i = 1, 3 do
        local bx = x0 + 2 + (i - 1) * (pw + 1)
        local w = (i == 3) and (inner - 2 * (pw + 1)) or pw
        local on = (atual == chaves[i])
        button(bx, y + 4, w, 3, nomes[i], on and TAB or TRACK, on and TEXT or MUTED, function() setPos(chaves[i]) end)
      end

      -- margens
      local ry = y + 8
      local wide = inner >= 36
      local linhas = { { 'esq', 'ESQUERDA' }, { 'dir', 'DIREITA' }, { 'frente', 'FRENTE' }, { 'cima', 'CIMA' }, { 'baixo', 'BAIXO' } }
      local grupos = (gap == 0) and (hh - 23 >= 2)
      for idx, it in ipairs(linhas) do
        local key = it[1]
        local x = x0 + 2
        txt(x, ry + math.floor((sh - 1) / 2), it[2], TEXT, 9)
        x = x + 10
        local function btn(delta)
          local bw = (math.abs(delta) > 1) and 5 or 4
          crect(x, ry, bw, sh, TRACK, 1)
          stepGlyph(x, ry, bw, sh, delta, ACC)
          zone(x, ry, x + bw - 1, ry + sh - 1 + gap, function() adjust(key, delta) end)
          x = x + bw + 1
        end
        if wide then btn(-5) end
        btn(-1)
        local str = tostring(form[key])
        if sh >= 2 then
          bigText(str, cpx(x) + math.floor((10 - bigW(str, 1)) / 2), cpy(ry) + math.floor((sh * 3 - 5) / 2), 1, TEXT)
        else
          txt(x + math.floor((5 - #str) / 2), ry, str, TEXT)
        end
        x = x + 6
        btn(1)
        if wide then btn(5) end
        ry = ry + sh + gap + ((grupos and (idx == 2 or idx == 3)) and 1 or 0)
      end

      -- ordem e memoria
      ry = ry + 1
      local hw = math.floor((inner - 1) / 2)
      local lo = form.ordem == 'cima' and 'ORDEM: DE CIMA' or (form.ordem == 'baixo' and 'ORDEM: DE BAIXO' or 'ORDEM: AUTO')
      local lm = form.reescavar and 'MEMORIA: IGNORAR' or 'MEMORIA: USAR'
      crect(x0 + 2, ry, hw, 1, TRACK, 0)
      txt(x0 + 2 + math.floor((hw - #lo) / 2), ry, lo, ACC)
      zone(x0 + 2, ry - 1, x0 + 1 + hw, ry + 1, function()
        form.ordem = (form.ordem == 'auto') and 'cima' or ((form.ordem == 'cima') and 'baixo' or 'auto')
        saveCfg()
      end)
      local x2 = x0 + 3 + hw
      local w2 = inner - hw - 1
      crect(x2, ry, w2, 1, TRACK, 0)
      txt(x2 + math.floor((w2 - #lm) / 2), ry, lm, form.reescavar and WARN or ACC)
      zone(x2, ry - 1, x2 + w2 - 1, ry + 1, function() form.reescavar = not form.reescavar saveCfg() end)

      -- resumo
      local W, L, A = dims()
      txt(x0 + 2, ry + 2, W .. ' x ' .. L .. ' x ' .. A .. '  =  ' .. fmt(W * L * A) .. ' BLOCOS', TEXT, inner)
      local extra = (ok and tonumber(dado.memoria) and tonumber(dado.memoria) > 1 and not form.reescavar)
        and ('JA ESCAVADO NA MEMORIA: ' .. fmt(tonumber(dado.memoria))) or
        ('CIMA ' .. form.cima .. '  BAIXO ' .. form.baixo .. '  ESQ ' .. form.esq .. '  DIR ' .. form.dir)
      txt(x0 + 2, ry + 3, extra, MUTED, inner)

      -- botoes
      local by = y + hh - 4
      button(x0 + 2, by, 9, 3, 'VOLTAR', TRACK, MUTED, function() pagina = 4 end)
      button(x0 + 12, by, cw - 14, 3, can and 'INICIAR ESCAVACAO' or (ok and 'TURTLE OCUPADA' or 'TURTLE OFFLINE'),
        can and OKBG or TRACK, can and OK or MUTED, can and function()
          sendCmd(sel, { action = 'escavar', esq = form.esq, dir = form.dir, frente = form.frente,
            cima = form.cima, baixo = form.baixo, ordem = form.ordem, reescavar = form.reescavar })
          setToast('Ordem enviada. Aguardando a Turtle...', OK, 15)
          pagina = 3
        end or nil)
    end,
  }
end

---------------------------------------------------------------------
-- FROTA
---------------------------------------------------------------------
local function pageFleet()
  local ids = sortedIds()
  local on, blocos = 0, 0
  for _, id in ipairs(ids) do
    local t = turtles[id]
    if isActive(t) then on = on + 1 end
    blocos = blocos + (tonumber(t.dado and t.dado.blocos) or 0)
  end
  local y = HEAD_ROWS + 2

  local y1 = y + 4
  -- altura das linhas: 5 (com detalhes) ou 4 (compacta) se muitas Turtles
  local avail = H - 2 - y1 + 1
  local rowH = (#ids * 6 - 1 <= avail) and 5 or ((#ids * 5 - 1 <= avail) and 4 or 5)
  local cap = math.max(1, math.floor((avail + 1) / (rowH + 1)))
  local pages = math.max(1, math.ceil(#ids / cap))
  if fleetPage > pages then fleetPage = pages end
  if fleetPage < 1 then fleetPage = 1 end

  -- faixa de resumo (a direita: paginador ou total de blocos)
  panel(x0, y, cw, 3)
  local a = #ids .. (#ids == 1 and ' TURTLE' or ' TURTLES')
  local b = on .. ' ON'
  local c = (#ids - on) .. ' OFF'
  local right, rightX
  if pages > 1 then
    right = '<  ' .. fleetPage .. '/' .. pages .. '  >'
  elseif W >= 46 then
    right = 'BLOCOS ' .. fmt(blocos)
  end
  local limitX = right and (x0 + cw - 2 - #right - 2) or (x0 + cw - 2)
  txt(x0 + 2, y + 1, a, TEXT)
  local nx = x0 + 2 + #a + 2
  if nx + #b <= limitX then
    txt(nx, y + 1, b, on > 0 and OK or MUTED)
    nx = nx + #b + 2
    if nx + #c <= limitX then txt(nx, y + 1, c, (#ids - on) > 0 and BAD or MUTED) end
  end
  if pages > 1 then
    local sx = x0 + cw - 2 - #right
    txt(sx, y + 1, '<', ACC)
    txt(sx + 3, y + 1, fleetPage .. '/' .. pages, TEXT)
    txt(sx + #right - 1, y + 1, '>', ACC)
    zone(sx - 1, y, sx + 3, y + 2, function() fleetPage = (fleetPage - 2) % pages + 1 end)
    zone(sx + #right - 3, y, sx + #right, y + 2, function() fleetPage = fleetPage % pages + 1 end)
  elseif right then
    txt(x0 + cw - #right - 2, y + 1, right, MUTED)
  end

  if #ids == 0 then
    if y1 + 4 <= H - 2 then
      panel(x0, y1, cw, 5)
      txt(x0 + 2, y1 + 1, 'AGUARDANDO TURTLES', WARN)
      txt(x0 + 2, y1 + 3, 'Run miner on the Turtles.', MUTED, cw - 4)
    end
    return on, #ids
  end
  if avail < rowH then return on, #ids end

  for k = 1, cap do
    local id = ids[(fleetPage - 1) * cap + k]
    if not id then break end
    local t = turtles[id]
    local isOn = isActive(t)
    local d = t.dado
    local ry = y1 + (rowH + 1) * (k - 1)
    panel(x0, ry, cw, rowH)
    local st = isOn and tostring(d.status or '--') or 'OFFLINE'
    local scol = isOn and stateColor(d.status) or BAD
    local pct = (isOn and tonumber(d.passos) and tonumber(d.passos) > 0) and (tonumber(d.progresso) or 0) or 0

    local nameStr = '#' .. id .. '  ' .. tostring(d.nome or '--')
    if #nameStr + #st + 6 > cw then
      st = st:gsub('INVENTARIO', 'INV.'):gsub('COMBUSTIVEL', 'COMB.'):gsub('AGUARDANDO CONFIRMACAO', 'CONFIRMAR')
    end
    txt(x0 + 1, ry + 1, '\7', scol)
    txt(x0 + 3, ry + 1, nameStr, isOn and TEXT or MUTED, cw - #st - 6)
    txt(x0 + cw - #st - 2, ry + 1, st, scol)
    if rowH >= 5 then
      local fuelNum = tonumber(d.fuel)
      local left = 'COMB ' .. (fuelNum and fmt(fuelNum) or tostring(d.fuel or '--')) .. '  SLOTS ' .. (tonumber(d.slots) or 0) .. '/16'
      local right = ''
      if isOn and tonumber(d.passos) and tonumber(d.passos) > 0 then
        right = math.floor(pct) .. '%' .. (tonumber(d.eta) and ('  ETA ' .. fmtEta(tonumber(d.eta))) or '')
      end
      txt(x0 + 2, ry + 2, left, MUTED, cw - 4 - #right - 1)
      txt(x0 + cw - #right - 2, ry + 2, right, TEXT)
    end
    bar(x0 + 2, ry + rowH - 2, cw - 4, pct / 100, isOn and scol or TRACK)
    zone(x0, ry, x0 + cw - 1, ry + rowH - 1, function() sel = id; pagina = 3 end)
  end
  return on, #ids
end

local function lootSection(ok)
  local items = {}
  if ok and type(dado.loot) == 'table' then
    for nome, n in pairs(dado.loot) do items[#items + 1] = { nome, n } end
    table.sort(items, function(a, b) return a[2] > b[2] end)
  end
  local nshow = math.min(#items, 4)
  local hh = 3 + math.max(1, nshow)
  return {
    min = hh, full = hh,
    draw = function(y)
      panel(x0, y, cw, hh)
      txt(x0 + 2, y + 1, 'GUARDADO NO BAU', MUTED)
      local v = ok and ('VIAGENS ' .. tostring(dado.viagens or 0)) or ''
      txt(x0 + cw - #v - 2, y + 1, v, TEXT)
      if nshow == 0 then txt(x0 + 2, y + 2, 'nada ainda', MUTED) end
      for i = 1, nshow do
        local nm = tostring(items[i][1])
        nm = nm:gsub('^[^:]+:', '')
        nm = nm:gsub('_', ' ')
        txt(x0 + 2, y + 1 + i, nm, TEXT, cw - 14)
        local c = fmt(items[i][2])
        txt(x0 + cw - #c - 2, y + 1 + i, c, ACC)
      end
    end,
  }
end

---------------------------------------------------------------------
-- PAGINAS DA TURTLE SELECIONADA
---------------------------------------------------------------------
local function pageGeral(ok)
  local nome = ok and tostring(dado.nome or '--') or 'SEM SINAL'
  local situacao = ok and tostring(dado.status or 'INDEFINIDO') or 'AGUARDANDO'
  local fuelNum = ok and tonumber(dado.fuel) or nil
  local fuelStr = '--'
  if ok then fuelStr = fuelNum and fmt(fuelNum) or tostring(dado.fuel or '--') end
  local ratio = (fuelNum and META_COMBUSTIVEL > 0) and math.max(0, math.min(1, fuelNum / META_COMBUSTIVEL)) or 0

  runSections(HEAD_ROWS + 2, {
    selectorSection(),
    bannerSection(ok),
    infoSection({
      { label = 'DISPOSITIVO', value = nome, color = ok and TEXT or MUTED },
      { label = 'STATUS', value = '\7 ' .. situacao, color = ok and stateColor(dado.status) or BAD },
    }),
    metricSection({
      { label = 'COMBUSTIVEL', str = fuelStr, color = ok and ratioColor(ratio) or MUTED },
      { label = 'INVENTARIO', str = ok and tostring(dado.itens or 0) or '--', color = ok and PUR or MUTED },
    }),
    fuelSection(ok, fuelNum),
    slotsSection(ok),
    lootSection(ok),
  })
end

local function pageMina(ok)
  runSections(HEAD_ROWS + 2, {
    selectorSection(),
    bannerSection(ok),
    heroSection(ok),
    mapSection(ok),
  })
end

local function pageCtrl(ok)
  runSections(HEAD_ROWS + 2, {
    selectorSection(),
    bannerSection(ok),
    acoesSection(ok),
    novaBtnSection(),
    memSection(ok),
  })
end

local function pageNova(ok)
  runSections(HEAD_ROWS + 2, {
    selectorSection(),
    bannerSection(ok),
    novaSection(ok),
  })
end

---------------------------------------------------------------------
-- DESENHO PRINCIPAL
---------------------------------------------------------------------
local function draw()
  local w, h = mon.getSize()
  if not win or w ~= W or h ~= H then setup() end

  if sel ~= nil and not turtles[sel] then sel = nil end
  if sel == nil then sel = sortedIds()[1] end
  curT = sel and turtles[sel]
  dado = curT and curT.dado
  recebidoEm = curT and curT.recebidoEm
  pacotes = curT and curT.pacotes or 0
  hist = curT and curT.hist or {}
  local ok = active() and true or false

  win.setVisible(false)
  clearBuf()
  zones = {}

  local on, total, alerts = 0, 0, 0
  for _, id in ipairs(sortedIds()) do
    local t = turtles[id]
    total = total + 1
    if isActive(t) then
      on = on + 1
      local d = t.dado
      if tostring(d.alerta or '') ~= '' then alerts = alerts + 1 end
    else
      alerts = alerts + 1
    end
  end

  if W < 35 or H < 17 then
    crect(1, H > 0 and 1 or 1, W, H, HEAD, 0)
    local function center(y, s, c) txt(math.floor((W - #s) / 2) + 1, y, s, c) end
    center(2, TITULO, ACC)
    center(4, 'AMPLIE A TELA / ESCALA 0.5', WARN)
    center(6, 'TURTLES: ' .. on .. '/' .. total .. ' ONLINE', on > 0 and OK or BAD)
  else
    x0, cw = 3, W - 4
    lw = math.floor((cw - 1) / 2)
    rw = cw - 1 - lw
    rx = x0 + lw + 1

    local fleet = (pagina == 1)
    local pillOK, pillLabel
    if fleet then
      pillOK = on > 0
      pillLabel = on .. '/' .. total .. ' ONLINE'
    else
      pillOK = ok
      pillLabel = ok and 'ONLINE' or 'OFFLINE'
    end
    drawHeader(pillOK, pillLabel, ok, alerts)
    if fleet then pageFleet()
    elseif pagina == 2 then pageGeral(ok)
    elseif pagina == 3 then pageMina(ok)
    elseif pagina == 4 then pageCtrl(ok)
    else pageNova(ok) end
    drawFooter(pillOK, fleet, on, total)
  end

  flush()
  win.setVisible(true)
end

---------------------------------------------------------------------
-- EVENTOS
---------------------------------------------------------------------
local function allowed(id)
  if not APENAS_IDS then return true end
  for _, v in ipairs(APENAS_IDS) do if v == id then return true end end
  return false
end

local function onPacket(id, msg)
  if type(id) ~= 'number' or type(msg) ~= 'table' or msg.versao ~= 1 or not allowed(id) then return end
  local t = turtles[id]
  if not t then
    t = { id = id, pacotes = 0, hist = {}, ultima = -100 }
    turtles[id] = t
  end
  t.dado = msg
  t.recebidoEm = os.clock()
  t.pacotes = t.pacotes + 1
  local f = tonumber(msg.fuel)
  if f and t.recebidoEm - t.ultima >= AMOSTRA_A_CADA then
    t.ultima = t.recebidoEm
    t.hist[#t.hist + 1] = f
    if #t.hist > HIST_MAX then table.remove(t.hist, 1) end
  end
end

local function onResponse(id, msg)
  if type(msg) ~= 'table' then return end
  local who = tostring(msg.nome or ('#' .. tostring(id)))
  if msg.ok then
    setToast(who .. ': ' .. tostring(msg.reason), OK, 10)
  else
    setToast(who .. ': ' .. tostring(msg.reason), BAD, 15)
  end
end

local function onTouch(x, y)
  for _, z in ipairs(zones) do
    if x >= z[1] and x <= z[3] and y >= z[2] and y <= z[4] then
      z[5]()
      return
    end
  end
end

local lastErr
local function safeDraw()
  local okd, err = pcall(draw)
  if not okd and err ~= lastErr then
    lastErr = err
    print('ERRO DE DESENHO: ' .. tostring(err))
  end
end

local function main()
  print('Dashboard started. Aceitando varias Turtles.')
  print('Toque nas abas e nos cartoes para navegar.')
  print('Commands need miner.lua on the Turtles.')
  local ticker = os.startTimer(1)
  safeDraw()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == 'rednet_message' then
      -- rednet_message: sender, payload, protocol
      if c == PROTO then onPacket(a, b)
      elseif c == RES then onResponse(a, b) end
      safeDraw()
    elseif e == 'monitor_touch' then
      onTouch(b, c)
      safeDraw()
    elseif e == 'timer' and a == ticker then
      safeDraw()
      ticker = os.startTimer(1)
    elseif e == 'monitor_resize' or e == 'peripheral' or e == 'peripheral_detach' then
      win = nil
      safeDraw()
    end
  end
end

loadCfg()
setup()
local okRun, err = pcall(main)
restorePalette()
mon.setBackgroundColor(colors.black)
mon.clear()
if not okRun and err ~= 'Terminated' then error(err, 0) end
