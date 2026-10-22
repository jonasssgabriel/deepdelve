-- DeepDelve | miner.lua
-- Autonomous excavator for CC:Tweaked turtles: it ALWAYS returns to its chest.
--
-- * Origem = bloco onde a Turtle esta, OLHANDO para a frente da mina.
--   Bau (ou Linked Chest) IMEDIATAMENTE ATRAS dela.
-- * Volume por margens a partir da origem: esquerda, direita, frente,
--   cima e baixo. Origem a esquerda, no meio ou a direita: so mudar as margens.
-- * Posicao exata sempre: diario gravado antes de cada movimento; apos queda ou
--   reinicio ela descobre pelo combustivel se o movimento aconteceu.
-- * Volta ao bau pelo caminho MINIMO (A*), nao refazendo a trilha.
-- * Reserva de combustivel a cada passo: nunca fica sem combustivel para voltar.
-- * Inventario cheio / pouco combustivel / pedido do painel: volta, descarrega,
--   reabastece e retorna sozinha. Reinicia sozinha apos queda de energia.
-- * Controlled from the touch dashboard (dashboard.lua) over wireless rednet.

---------------------------------------------------------------------
-- CONFIGURACAO
---------------------------------------------------------------------
local SENHA = nil               -- senha dos comandos remotos (mesma no painel/central)
local LIMITE_DIM, LIMITE_TOTAL = 130, 100000
local AUTO_REFUEL = true        -- usa combustivel do inventario quando precisar
local AUTO_RETOMAR = true       -- apos reiniciar, retoma a tarefa sozinha
local AUX_LADO = nil            -- 'cima','baixo','esq','dir': bau de COMBUSTIVEL junto da origem
local VIES_MEIO = 'esq'         -- origem no meio de largura par: 'esq' ou 'dir'
local PESO_GIRO = 0.15          -- custo de virar nas rotas (menos giros)
local PESO_ESCAVAR = 2.5        -- custo extra de atravessar bloco ainda nao escavado
local RESERVA_COMB = 20         -- folga minima de combustivel ao voltar
local MARGEM_COMB = 1.25        -- margem sobre a distancia ate o bau
local SLOTS_LIVRES_MIN = 2      -- abaixo disso, vai descarregar
local OPORTUNISTA_LIVRES = 5    -- descarrega antes se o bau estiver perto
local OPORTUNISTA_DIST = 10
local MANTER_COMBUSTIVEL = 32   -- itens de combustivel que ela guarda para si
local MANTER_SELO = 32          -- blocos para selar liquidos
local BAUS = { 'chest', 'barrel', 'linked', 'shulker', 'drawer', 'ender', 'storage' }
local SELOS = { 'cobblestone', 'cobbled_deepslate', 'dirt', 'netherrack' }
local LIQUIDOS = { 'water', 'lava' }
local PROTEGIDOS = { 'bedrock', 'spawner', 'chest', 'barrel', 'shulker', 'furnace', 'hopper',
  'dropper', 'dispenser', 'drawer', 'computercraft', 'turtle', 'command_block', 'portal',
  'linked', 'ender_chest', 'storage' }

local PROTO = 'doscria.status.v1'
local CMD = 'doscria.comando.v6'
local RES = 'doscria.resposta.v6'
local SAVE = 'deepdelve_job.dat'
local MEM = 'deepdelve_memory.dat'          -- memoria: tudo que ja foi escavado (a partir da base)
local MEMBASE = 'deepdelve_memory_base.dat'  -- memoria congelada no inicio da tarefa (plano estavel)
local VERSAO = '10.4'

local modem = peripheral.find('modem', function(_, p) return p.isWireless and p.isWireless() end)
assert(modem, 'Instale um Wireless Modem na Turtle.')
rednet.open(peripheral.getName(modem))
local NOME = os.getComputerLabel() or string.format('TURTLE %02d', os.getComputerID())

---------------------------------------------------------------------
-- UTILITARIOS
---------------------------------------------------------------------
local OFF = 128
local function K(x, y, z) return ((x + OFF) * 256 + (y + OFF)) * 256 + (z + OFF) end
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local function casa(nome, lista)
  nome = nome or ''
  for _, v in ipairs(lista) do
    if nome:find(v, 1, true) then return true end
  end
  return false
end

local function abs(n) return n < 0 and -n or n end

local function yieldAgora()
  os.queueEvent('doscria_y')
  os.pullEvent('doscria_y')
end

-- fila de prioridade (heap binario)
local function heapNovo() return { n = 0 } end
local function heapPush(h, f, v)
  h.n = h.n + 1
  local i = h.n
  h[i] = { f, v }
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p][1] <= h[i][1] then break end
    h[p], h[i] = h[i], h[p]
    i = p
  end
end
local function heapPop(h)
  local top = h[1]
  h[1] = h[h.n]
  h[h.n] = nil
  h.n = h.n - 1
  local i = 1
  while true do
    local l, r, m = i * 2, i * 2 + 1, i
    if l <= h.n and h[l][1] < h[m][1] then m = l end
    if r <= h.n and h[r][1] < h[m][1] then m = r end
    if m == i then break end
    h[m], h[i] = h[i], h[m]
    i = m
  end
  return top[1], top[2]
end

---------------------------------------------------------------------
-- PLANO DE ESCAVACAO (por margens a partir da origem)
---------------------------------------------------------------------
-- caixa: x0..x1 (esq..dir), y0..y1 (baixo..cima), z 0..z1 (frente)
local function varredura(b, cx, cz, eixo, primeiro)
  local path = {}
  local x0, x1, z1 = b.x0, b.x1, b.z1
  local function add(x, z, novo) path[#path + 1] = { x, z, novo } end
  if eixo == 'x' then
    local zs, ze, zd = 0, z1, 1
    if cz ~= 0 then zs, ze, zd = z1, 0, -1 end
    local x = cx
    local r = 0
    for z = zs, ze, zd do
      if r == 0 then
        if x0 == x1 then
          -- coluna unica: nada a percorrer na linha
        elseif x == x0 or x == x1 then
          local d = (x == x0) and 1 or -1
          for xx = x + d, (d == 1) and x1 or x0, d do add(xx, z, true) end
          x = (d == 1) and x1 or x0
        else
          local e1, e2 = x0, x1
          if primeiro == 'R' then e1, e2 = x1, x0 end
          local d1 = (e1 < x) and -1 or 1
          for xx = x + d1, e1, d1 do add(xx, z, true) end
          local d2 = -d1
          for xx = e1 + d2, e2, d2 do
            add(xx, z, (d2 == 1) and (xx > x) or (d2 == -1 and xx < x))
          end
          x = e2
        end
      else
        add(x, z, true)
        if x0 ~= x1 then
          local d = (x == x0) and 1 or -1
          for xx = x + d, (d == 1) and x1 or x0, d do add(xx, z, true) end
          x = (d == 1) and x1 or x0
        end
      end
      r = r + 1
    end
  else
    local cols = {}
    if x0 == x1 then
      cols = { x0 }
    elseif cx == x0 then
      for xx = x0, x1 do cols[#cols + 1] = xx end
    elseif cx == x1 then
      for xx = x1, x0, -1 do cols[#cols + 1] = xx end
    elseif primeiro == 'R' then
      for xx = cx, x1 do cols[#cols + 1] = xx end
      for xx = cx - 1, x0, -1 do cols[#cols + 1] = xx end
    else
      for xx = cx, x0, -1 do cols[#cols + 1] = xx end
      for xx = cx + 1, x1 do cols[#cols + 1] = xx end
    end
    local zc = cz
    local xcur = cx
    for idx, xx in ipairs(cols) do
      if idx > 1 then
        -- passa por colunas ja limpas ate chegar na proxima
        local d = (xx > xcur) and 1 or -1
        local passo = xcur + d
        while passo ~= xx do
          add(passo, zc, false)
          passo = passo + d
        end
        add(xx, zc, true)
        xcur = xx
      end
      local alvo = (zc == 0) and z1 or 0
      local d = (alvo > zc) and 1 or -1
      if alvo ~= zc then
        for zz = zc + d, alvo, d do add(xx, zz, true) end
        zc = alvo
      end
    end
  end
  return path
end

local function custoVarredura(path, cx, cz)
  local giros = 0
  local pdx, pdz = nil, nil
  local px, pz = cx, cz
  for _, p in ipairs(path) do
    local dx, dz = p[1] - px, p[2] - pz
    if pdx ~= nil and (dx ~= pdx or dz ~= pdz) then giros = giros + 1 end
    pdx, pdz = dx, dz
    px, pz = p[1], p[2]
  end
  return #path + 0.3 * giros
end

local function melhorVarredura(b, cx, cz)
  local melhor, custo
  for _, eixo in ipairs({ 'x', 'z' }) do
    for _, prim in ipairs({ 'L', 'R' }) do
      local p = varredura(b, cx, cz, eixo, prim)
      local c = custoVarredura(p, cx, cz)
      if not custo or c < custo - 1e-9 then melhor, custo = p, c end
    end
  end
  return melhor
end

local function planoBruto(b, ordem)
  local plan = {}
  local up, dn = b.y1, -b.y0
  local topdown
  if ordem == 'cima' then topdown = true
  elseif ordem == 'baixo' then topdown = false
  else topdown = (up < dn) end
  local bands = {}
  if topdown then
    local hi = b.y1
    while hi >= b.y0 do
      local lo = math.max(b.y0, hi - 2)
      bands[#bands + 1] = { lo, hi }
      hi = lo - 1
    end
  else
    local lo = b.y0
    while lo <= b.y1 do
      local hi = math.min(b.y1, lo + 2)
      bands[#bands + 1] = { lo, hi }
      lo = hi + 1
    end
  end
  local cx, cy, cz = 0, 0, 0
  for gi, band in ipairs(bands) do
    local lo, hi = band[1], band[2]
    local n = hi - lo + 1
    local ty, fu, fd
    if n >= 3 then ty, fu, fd = lo + 1, 1, 1
    elseif n == 2 then
      if topdown then ty, fu, fd = hi, 0, 1 else ty, fu, fd = lo, 1, 0 end
    else ty, fu, fd = lo, 0, 0 end
    yieldAgora()
    local moved = false
    while cy ~= ty do
      cy = cy + ((ty > cy) and 1 or -1)
      moved = true
      local last = (cy == ty)
      plan[#plan + 1] = { cx, cy, cz, last and fu or 0, last and fd or 0, gi }
    end
    if not moved and (fu + fd) > 0 then plan[#plan + 1] = { cx, cy, cz, fu, fd, gi } end
    local path = melhorVarredura(b, cx, cz)
    for _, p in ipairs(path) do
      plan[#plan + 1] = { p[1], ty, p[2], p[3] and fu or 0, p[3] and fd or 0, gi }
      cx, cz = p[1], p[2]
    end
  end
  return plan
end

-- conjuntos de celulas (memoria) gravados em faixas compactas
local function copiarSet(s)
  local c = {}
  for k in pairs(s) do c[k] = true end
  return c
end

local function salvarSet(path, set)
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  local runs = {}
  local i = 1
  while i <= #keys do
    local k0, n = keys[i], 1
    while keys[i + n] and keys[i + n] == k0 + n do n = n + 1 end
    runs[#runs + 1] = k0
    runs[#runs + 1] = n
    i = i + n
  end
  local f = fs.open(path, 'w')
  if f then
    f.write(textutils.serialize(runs))
    f.close()
  end
end

local function carregarSet(path)
  local set = {}
  if not fs.exists(path) then return set end
  local f = fs.open(path, 'r')
  local runs = textutils.unserialize(f.readAll())
  f.close()
  if type(runs) == 'table' then
    for i = 1, #runs, 2 do
      for k = runs[i], runs[i] + runs[i + 1] - 1 do set[k] = true end
    end
  end
  return set
end

-- plano final: remove passos que nao limpam nada novo (area ja escavada ou ja planejada)
local function buildPlan(b, ordem, mem)
  local bruto = planoBruto(b, ordem)
  local feito = mem and copiarSet(mem) or {}
  local out = {}
  for idx, s in ipairs(bruto) do
    if idx % 3000 == 0 then yieldAgora() end
    local kt = K(s[1], s[2], s[3])
    local ku = (s[4] == 1) and K(s[1], s[2] + 1, s[3]) or nil
    local kd = (s[5] == 1) and K(s[1], s[2] - 1, s[3]) or nil
    if not feito[kt] or (ku and not feito[ku]) or (kd and not feito[kd]) then
      out[#out + 1] = s
      feito[kt] = true
      if ku then feito[ku] = true end
      if kd then feito[kd] = true end
    end
  end
  return out
end

---------------------------------------------------------------------
-- ESTADO
---------------------------------------------------------------------
local job, plan, free, blocked = nil, nil, nil, {}
local memBaseSet, memCount = nil, 0
local mapaCache = { step = -1 }
local estado, detalhe, alerta = 'AGUARDANDO', 'Pronta', ''
local paused, cancelReq, returnReq, runReq, contReq = false, false, false, false, false
local emRetorno, trabalhando = false, false
local anel = {}
local eventos = {}
local SENT_CANCEL, SENT_VOLTAR = 'DOSCRIA_CANCEL', 'DOSCRIA_VOLTAR'

local function log(msg)
  eventos[#eventos + 1] = string.format('%s %s', textutils.formatTime(os.time(), true), msg)
  if #eventos > 20 then table.remove(eventos, 1) end
end

local function setEstado(e, d, a)
  estado = e
  if d then detalhe = d end
  alerta = a or ''
end

local function saveJob()
  local f = assert(fs.open(SAVE, 'w'))
  f.write(textutils.serialize(job))
  f.close()
end

local function loadJob()
  if not fs.exists(SAVE) then return nil end
  local f = fs.open(SAVE, 'r')
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) ~= 'table' or not d.box or not d.step then return nil end
  return d
end

local function inBox(x, y, z)
  local b = job.box
  return x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 and z >= 0 and z <= b.z1
end

local function markFree(x, y, z) free[K(x, y, z)] = true end

local function planoDoJob()
  memBaseSet = memBaseSet or carregarSet(MEMBASE)
  return buildPlan(job.box, job.ordem, memBaseSet)
end

local function salvarMem()
  local n = 0
  for _ in pairs(free) do n = n + 1 end
  memCount = n
  salvarSet(MEM, free)
end

local function mapaPlano()
  if not job then return nil end
  if mapaCache.step == job.step and mapaCache.y == job.y then return mapaCache.v end
  local b = job.box
  local runs = {}
  for z = 0, b.z1 do
    local xa
    for x = b.x0, b.x1 do
      local f = free[K(x, job.y, z)]
      if f and not xa then xa = x end
      if (not f) and xa then
        runs[#runs + 1] = { z, xa, x - 1 }
        xa = nil
      end
    end
    if xa then runs[#runs + 1] = { z, xa, b.x1 } end
  end
  mapaCache = { step = job.step, y = job.y, v = { y = job.y, runs = runs } }
  return mapaCache.v
end

local function rebuildFree()
  free = carregarSet(MEM)
  free[K(0, 0, 0)] = true
  for i = 1, job.step do
    local s = plan[i]
    free[K(s[1], s[2], s[3])] = true
    if s[4] == 1 then free[K(s[1], s[2] + 1, s[3])] = true end
    if s[5] == 1 then free[K(s[1], s[2] - 1, s[3])] = true end
  end
  for _, k in ipairs(job.ext) do free[k] = true end
  free[K(job.x, job.y, job.z)] = true
end

---------------------------------------------------------------------
-- COMBUSTIVEL / INVENTARIO
---------------------------------------------------------------------
local function fuelNum()
  local f = turtle.getFuelLevel()
  if f == 'unlimited' then return math.huge end
  return f
end

local function refuelAny(alvo)
  if fuelNum() >= alvo then return true end
  local cur = turtle.getSelectedSlot()
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      if turtle.refuel(0) then
        while turtle.getItemCount(i) > 0 and fuelNum() < alvo do
          if not turtle.refuel(1) then break end
        end
      end
    end
    if fuelNum() >= alvo then break end
  end
  turtle.select(cur)
  return fuelNum() >= alvo
end

local function livres()
  local n = 0
  for i = 1, 16 do if turtle.getItemCount(i) == 0 then n = n + 1 end end
  return n
end

local function compactar()
  local cur = turtle.getSelectedSlot()
  for i = 16, 2, -1 do
    local a = turtle.getItemDetail(i)
    if a then
      for j = 1, i - 1 do
        local b = turtle.getItemDetail(j)
        if b and b.name == a.name and turtle.getItemSpace(j) > 0 then
          turtle.select(i)
          turtle.transferTo(j)
          if turtle.getItemCount(i) == 0 then break end
        end
      end
    end
  end
  turtle.select(cur)
end

local function md(ax, ay, az, bx, by, bz) return abs(ax - bx) + abs(ay - by) + abs(az - bz) end

local function combustivelNecessario(x, y, z)
  return math.ceil(md(x, y, z, 0, 0, 0) * MARGEM_COMB) + RESERVA_COMB
end

---------------------------------------------------------------------
-- MOVIMENTO COM DIARIO (WAL)
---------------------------------------------------------------------
local ACT = {
  F = { inspect = turtle.inspect, dig = turtle.dig, move = turtle.forward, attack = turtle.attack, place = turtle.place },
  U = { inspect = turtle.inspectUp, dig = turtle.digUp, move = turtle.up, attack = turtle.attackUp, place = turtle.placeUp },
  D = { inspect = turtle.inspectDown, dig = turtle.digDown, move = turtle.down, attack = turtle.attackDown, place = turtle.placeDown },
}

local function checkpoint()
  if emRetorno then return end
  if cancelReq then error(SENT_CANCEL, 0) end
  if returnReq then error(SENT_VOLTAR, 0) end
  if paused then
    local anterior = estado
    setEstado('PAUSADA', 'Pausada pelo operador')
    while paused and not cancelReq and not returnReq do sleep(0.5) end
    if cancelReq then error(SENT_CANCEL, 0) end
    if returnReq then error(SENT_VOLTAR, 0) end
    setEstado(anterior == 'PAUSADA' and 'MINERANDO' or anterior)
    anel = {}
  end
end

local function girar(direita)
  local de = job.dir
  local para = (de + (direita and 1 or 3)) % 4
  job.intent = { k = 'turn', de = de, para = para }
  saveJob()
  local ok = direita and turtle.turnRight() or turtle.turnLeft()
  if not ok then
    job.intent = nil
    saveJob()
    error('Nao consegui virar.', 0)
  end
  job.dir = para
  job.intent = nil
  saveJob()
end

local function virarPara(alvo)
  while job.dir ~= alvo do
    local d = (alvo - job.dir) % 4
    girar(d ~= 3)
  end
end

local function eLiquido(nm) return casa(nm, LIQUIDOS) end
local function eProtegido(nm) return casa(nm, PROTEGIDOS) end
-- outra Turtle no caminho: obstaculo TEMPORARIO (nunca quebrar, nunca pular para sempre)
local function eTurtle(nm) return (nm or ''):find('computercraft:turtle', 1, true) ~= nil end

local function marcarExcluido(x, y, z, motivo)
  job.excl[K(x, y, z)] = true
  free[K(x, y, z)] = nil
  log('pulou ' .. x .. ',' .. y .. ',' .. z .. ' (' .. tostring(motivo) .. ')')
  saveJob()
end

-- coloca um bloco de selo dentro do liquido
local function selar(kind, x, y, z)
  local k = K(x, y, z)
  job.selos[k] = (job.selos[k] or 0) + 1
  if job.selos[k] > 3 then return false end
  local cur = turtle.getSelectedSlot()
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and casa(d.name, SELOS) then
      turtle.select(i)
      local ok = ACT[kind].place()
      turtle.select(cur)
      return ok
    end
  end
  turtle.select(cur)
  return false
end

local function garantirCombustivel()
  if fuelNum() >= 1 then return true end
  refuelAny(50)
  if fuelNum() >= 1 then return true end
  setEstado('SEM COMBUSTIVEL', 'Sem combustivel: coloque carvao na Turtle', 'Sem combustivel (emergencia)')
  while fuelNum() < 1 do
    refuelAny(50)
    if fuelNum() >= 1 then break end
    sleep(2)
  end
  setEstado('MINERANDO', 'Combustivel recuperado')
  return true
end

-- avanca uma casa na direcao 'kind' (cava se preciso). Retorna ok, motivo
local function avancar(kind, nx, ny, nz)
  local A = ACT[kind]
  local digFalhas = 0
  for _ = 1, 60 do
    checkpoint()
    local has, b = A.inspect()
    if has then
      local nm = b.name or ''
      if eLiquido(nm) then
        if not selar(kind, nx, ny, nz) then return false, 'liquido' end
      elseif eTurtle(nm) then
        return false, 'turtle'
      elseif eProtegido(nm) then
        return false, 'protegido:' .. nm
      else
        if livres() == 0 then
          compactar()
          if livres() == 0 then return false, 'cheio' end
        end
        if A.dig() then
          digFalhas = 0
          job.broken = job.broken + 1
          if nm:find('gravel', 1, true) or nm:find('sand', 1, true) then sleep(0.4) end
        else
          -- nao quebra (bedrock de mod, barrier, etc.): trata como protegido
          digFalhas = digFalhas + 1
          if digFalhas >= 4 then return false, 'protegido:inquebravel ' .. nm end
          sleep(0.2)
        end
      end
    else
      garantirCombustivel()
      job.intent = { k = 'mv', fx = job.x, fy = job.y, fz = job.z, tx = nx, ty = ny, tz = nz, fuel = fuelNum() }
      saveJob()
      if A.move() then
        job.x, job.y, job.z = nx, ny, nz
        job.intent = nil
        markFree(nx, ny, nz)
        saveJob()
        return true
      end
      job.intent = nil
      saveJob()
      A.attack()
      sleep(0.3)
    end
  end
  return false, 'bloqueado'
end

---------------------------------------------------------------------
-- ROTAS (A* com giros e custo de escavar)
---------------------------------------------------------------------
local function custoCelula(x, y, z)
  local k = K(x, y, z)
  if free[k] then return 1 end
  local bl = blocked[k]
  if bl then
    if bl == true or bl > os.clock() then return nil end
    blocked[k] = nil
  end
  if job.excl[k] then return nil end
  if inBox(x, y, z) then return 1 + PESO_ESCAVAR end
  return nil
end

local function astar(sx, sy, sz, sdir, gx, gy, gz)
  if sx == gx and sy == gy and sz == gz then return {} end
  local open = heapNovo()
  local gs, parent, dados, fechado = {}, {}, {}, {}
  local function nk(x, y, z, d) return K(x, y, z) * 4 + d end
  local s = nk(sx, sy, sz, sdir)
  gs[s] = 0
  dados[s] = { sx, sy, sz, sdir }
  heapPush(open, md(sx, sy, sz, gx, gy, gz), s)
  local exp = 0
  while open.n > 0 do
    local _, nodo = heapPop(open)
    if not fechado[nodo] then
      fechado[nodo] = true
      local d = dados[nodo]
      local x, y, z, dir = d[1], d[2], d[3], d[4]
      if x == gx and y == gy and z == gz then
        local path = {}
        local cur = nodo
        while cur ~= s do
          local dd = dados[cur]
          table.insert(path, 1, { dd[1], dd[2], dd[3] })
          cur = parent[cur]
        end
        return path
      end
      exp = exp + 1
      if exp > 40000 then return nil end
      if exp % 400 == 0 and not (DOSCRIA_TEST and DOSCRIA_TEST.semYield) then yieldAgora() end
      local g0 = gs[nodo]
      for mv = 1, 6 do
        local nx, ny, nz, nd, extra = x, y, z, dir, 0
        if mv <= 4 then
          local dd = mv - 1
          nx, nz = x + DX[dd], z + DZ[dd]
          local t = abs(dd - dir)
          if t > 2 then t = 4 - t end
          extra = t * PESO_GIRO
          nd = dd
        elseif mv == 5 then ny = y + 1
        else ny = y - 1 end
        local c = custoCelula(nx, ny, nz)
        if c then
          local key = nk(nx, ny, nz, nd)
          if not fechado[key] then
            local ng = g0 + c + extra
            if not gs[key] or ng < gs[key] then
              gs[key] = ng
              parent[key] = nodo
              dados[key] = { nx, ny, nz, nd }
              heapPush(open, ng + md(nx, ny, nz, gx, gy, gz), key)
            end
          end
        end
      end
    end
  end
  return nil
end

local function passoPara(nx, ny, nz)
  local dx, dy, dz = nx - job.x, ny - job.y, nz - job.z
  if dy == 1 then return avancar('U', nx, ny, nz) end
  if dy == -1 then return avancar('D', nx, ny, nz) end
  local d
  if dx == 1 then d = 1 elseif dx == -1 then d = 3 elseif dz == 1 then d = 0 else d = 2 end
  virarPara(d)
  return avancar('F', nx, ny, nz)
end

-- vai ate a celula (pode cavar dentro da caixa). Retorna ok, motivo
local function irPara(gx, gy, gz)
  local falhas, esperasTurtle, semRota = 0, 0, 0
  while true do
    if job.x == gx and job.y == gy and job.z == gz then return true end
    local path = astar(job.x, job.y, job.z, job.dir, gx, gy, gz)
    if not path then
      -- pode ser outra Turtle bloqueando: espera um pouco e tenta de novo
      if semRota < 15 and next(blocked) then
        semRota = semRota + 1
        sleep(2 + math.random() * 2)
        blocked = {}
        path = astar(job.x, job.y, job.z, job.dir, gx, gy, gz)
      end
      if not path then return false, 'sem_rota' end
    end
    local replanejar = false
    for _, c in ipairs(path) do
      local ok, why = passoPara(c[1], c[2], c[3])
      if not ok then
        local ck = K(c[1], c[2], c[3])
        if why == 'cheio' then return false, 'cheio' end
        if why == 'turtle' then
          esperasTurtle = esperasTurtle + 1
          if esperasTurtle > 40 and c[1] == gx and c[2] == gy and c[3] == gz then return false, 'ocupado' end
          blocked[ck] = os.clock() + 6 + math.random() * 6
          sleep(0.5 + math.random() * 2)
          replanejar = true
          break
        end
        if why and why:find('protegido', 1, true) or why == 'liquido' then
          marcarExcluido(c[1], c[2], c[3], why)
          if c[1] == gx and c[2] == gy and c[3] == gz then return false, 'excluido' end
        else
          blocked[ck] = true
          falhas = falhas + 1
          if falhas > 4 then
            blocked = {}
            return false, 'bloqueado'
          end
        end
        replanejar = true
        break
      end
    end
    if not replanejar then
      if job.x == gx and job.y == gy and job.z == gz then return true end
    end
  end
end

---------------------------------------------------------------------
-- BASE: bau atras da origem
---------------------------------------------------------------------
local function temBau()
  local ok, b = turtle.inspect()
  if ok and casa(b.name, BAUS) then return true end
  if peripheral.hasType then
    local okp, r = pcall(peripheral.hasType, 'front', 'inventory')
    if okp and r then return true end
  end
  return false
end

local function irParaBase()
  local antes = emRetorno
  emRetorno = true
  local ok, why = irPara(0, 0, 0)
  emRetorno = antes
  if not ok then error('Nao consegui voltar ao bau: ' .. tostring(why), 0) end
  virarPara(2)
end

local function lerMaoDe(slot)
  return turtle.getItemDetail(slot)
end

local function descarregar()
  virarPara(2)
  setEstado('DESCARREGANDO', 'No bau: descarregando')
  local manterComb, manterSelo = MANTER_COMBUSTIVEL, MANTER_SELO
  while true do
    if not temBau() then
      setEstado('SEM BAU', 'Nao ha bau atras da origem', 'Sem bau atras da origem!')
      if cancelReq then return false end
      sleep(5)
    else
      local sobra = 0
      local cur = turtle.getSelectedSlot()
      for i = 1, 16 do
        local d = lerMaoDe(i)
        if d then
          turtle.select(i)
          local n = d.count
          local manter = 0
          if turtle.refuel(0) and manterComb > 0 then
            manter = math.min(n, manterComb)
            manterComb = manterComb - manter
          elseif casa(d.name, SELOS) and manterSelo > 0 then
            manter = math.min(n, manterSelo)
            manterSelo = manterSelo - manter
          end
          local levar = n - manter
          if levar > 0 then
            turtle.drop(levar)
            local resta = turtle.getItemCount(i) - manter
            local foi = levar - resta
            if foi > 0 then job.loot[d.name] = (job.loot[d.name] or 0) + foi end
            if resta > 0 then sobra = sobra + resta end
          end
        end
      end
      turtle.select(cur)
      if sobra == 0 then
        job.viagens = job.viagens + 1
        saveJob()
        log('descarregou (viagem ' .. job.viagens .. ')')
        return true
      end
      setEstado('BAU CHEIO', 'Bau cheio: libere espaco', 'Bau cheio na base')
      if cancelReq then return false end
      sleep(5)
    end
  end
end

local function fuelAlvo()
  local restante = plan and (#plan - job.step) or 0
  local b = job.box
  local maxd = (b.x1 - b.x0) + (b.y1 - b.y0) + b.z1
  local limite = turtle.getFuelLimit and turtle.getFuelLimit() or 20000
  if limite == 'unlimited' then limite = 20000 end
  return math.min(math.floor(limite * 0.9), math.max(400, restante + 3 * maxd + 100))
end

local function auxVirar()
  if AUX_LADO == 'esq' then virarPara(3)
  elseif AUX_LADO == 'dir' then virarPara(1) end
end

local function auxFns()
  if AUX_LADO == 'cima' then return turtle.suckUp, turtle.dropUp end
  if AUX_LADO == 'baixo' then return turtle.suckDown, turtle.dropDown end
  return turtle.suck, turtle.drop
end

local function reabastecer()
  local alvo = fuelAlvo()
  if AUTO_REFUEL then refuelAny(alvo) end
  if fuelNum() < alvo and AUX_LADO then
    setEstado('REABASTECENDO', 'Pegando combustivel no bau auxiliar')
    auxVirar()
    local suck, drop = auxFns()
    local cur = turtle.getSelectedSlot()
    for _ = 1, 20 do
      if fuelNum() >= alvo or livres() == 0 then break end
      local ok = suck(64)
      if not ok then break end
      local usou = false
      for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
          turtle.select(i)
          if turtle.refuel(0) then
            usou = true
            while turtle.getItemCount(i) > 0 and fuelNum() < alvo do
              if not turtle.refuel(1) then break end
            end
          end
        end
      end
      if not usou then
        -- item que nao e combustivel: devolve e para
        for i = 1, 16 do
          if turtle.getItemCount(i) > 0 and not (turtle.select(i) and turtle.refuel(0)) then
            turtle.select(i)
          end
        end
        break
      end
    end
    turtle.select(cur)
    virarPara(2)
  end
  if fuelNum() < RESERVA_COMB + 5 then
    setEstado('SEM COMBUSTIVEL', 'Base sem combustivel disponivel', 'Coloque combustivel na Turtle ou no bau auxiliar')
    while fuelNum() < RESERVA_COMB + 5 do
      if cancelReq then return false end
      refuelAny(alvo)
      sleep(3)
    end
  end
  return true
end

local function viagemBase(motivo)
  log('voltando: ' .. motivo)
  job.fase = 'VOLTANDO'
  setEstado('VOLTANDO AO BAU', 'Indo ao bau (' .. motivo .. ')')
  saveJob()
  irParaBase()
  job.fase = 'BASE'
  saveJob()
  descarregar()
  reabastecer()
  salvarMem()
  job.fase = 'MINA'
  anel = {}
  setEstado('MINERANDO', 'Retornando ao ponto de trabalho')
  saveJob()
end

---------------------------------------------------------------------
-- LIMPEZA E PASSOS
---------------------------------------------------------------------
local function limpar(kind, x, y, z)
  local k = K(x, y, z)
  if job.excl[k] then return true end
  local A = ACT[kind]
  local digFalhas, viuTurtle = 0, false
  for _ = 1, 40 do
    local has, b = A.inspect()
    if not has then markFree(x, y, z) return true end
    local nm = b.name or ''
    viuTurtle = false
    if eLiquido(nm) then
      if not selar(kind, x, y, z) then marcarExcluido(x, y, z, 'liquido') return true end
    elseif eTurtle(nm) then
      viuTurtle = true
      sleep(1 + math.random() * 2)
    elseif eProtegido(nm) then
      marcarExcluido(x, y, z, 'protegido ' .. nm)
      return true
    else
      if livres() == 0 then
        compactar()
        if livres() == 0 then return false, 'cheio' end
      end
      if A.dig() then
        digFalhas = 0
        job.broken = job.broken + 1
        if nm:find('gravel', 1, true) or nm:find('sand', 1, true) then sleep(0.4) end
      else
        digFalhas = digFalhas + 1
        if digFalhas >= 4 then marcarExcluido(x, y, z, 'inquebravel ' .. nm) return true end
        sleep(0.2)
      end
    end
  end
  if viuTurtle then
    job.pend[#job.pend + 1] = { x, y, z } -- outra Turtle parada ali: volta depois
    return true
  end
  marcarExcluido(x, y, z, 'bloqueado')
  return true
end

local function precisaVoltar(s)
  local lvl = fuelNum()
  if lvl ~= math.huge then
    local ate = md(job.x, job.y, job.z, s[1], s[2], s[3]) + 1
    local precisa = combustivelNecessario(s[1], s[2], s[3]) + ate
    if lvl < precisa and AUTO_REFUEL then
      -- usa o carvao/lava que ela mesma minerou, sem precisar voltar
      refuelAny(precisa + 40)
      lvl = fuelNum()
    end
    if lvl < precisa then return 'combustivel' end
  end
  local l = livres()
  if l <= SLOTS_LIVRES_MIN then
    compactar()
    l = livres()
    if l <= SLOTS_LIVRES_MIN then return 'inventario' end
  end
  if l <= OPORTUNISTA_LIVRES and md(job.x, job.y, job.z, 0, 0, 0) <= OPORTUNISTA_DIST then
    return 'oportunidade'
  end
  return nil
end

-- sensor: espaco vazio visto de graca (frente/cima/baixo) conta como ja escavado
local function sentir()
  local function ver(kind, x, y, z)
    local k = K(x, y, z)
    if free[k] or job.excl[k] then return end
    if not ACT[kind].inspect() then free[k] = true end
  end
  ver('U', job.x, job.y + 1, job.z)
  ver('D', job.x, job.y - 1, job.z)
  ver('F', job.x + DX[job.dir], job.y, job.z + DZ[job.dir])
end

local function executarStep(i)
  local s = plan[i]
  local tx, ty, tz = s[1], s[2], s[3]
  -- tudo que este passo limparia ja e vazio (visto antes): nem precisa ir la
  if free[K(tx, ty, tz)] and (s[4] ~= 1 or free[K(tx, ty + 1, tz)]) and (s[5] ~= 1 or free[K(tx, ty - 1, tz)]) then
    job.step = i
    saveJob()
    return true
  end
  if not job.excl[K(tx, ty, tz)] then
    local ok, why = irPara(tx, ty, tz)
    if not ok then
      if why == 'cheio' then return false, 'cheio' end
      if why == 'excluido' then
        -- ja marcado: segue
      elseif why == 'ocupado' then
        -- outra Turtle ficou parada ali: deixa para depois
        job.pend[#job.pend + 1] = { tx, ty, tz }
      else
        marcarExcluido(tx, ty, tz, why)
      end
    end
  end
  if job.x == tx and job.y == ty and job.z == tz then
    if s[4] == 1 then
      local ok, why = limpar('U', tx, ty + 1, tz)
      if not ok then return false, why end
    end
    if s[5] == 1 then
      local ok, why = limpar('D', tx, ty - 1, tz)
      if not ok then return false, why end
    end
    sentir()
  else
    -- celula do plano pulada: as de cima/baixo dela ficam pendentes
    if s[4] == 1 then job.pend[#job.pend + 1] = { tx, ty + 1, tz } end
    if s[5] == 1 then job.pend[#job.pend + 1] = { tx, ty - 1, tz } end
  end
  job.step = i
  saveJob()
  return true
end

-- limpa celulas que ficaram para tras (vindo das vizinhas)
local function limparPendentes()
  while #job.pend > 0 do
    local c = job.pend[#job.pend]
    local k = K(c[1], c[2], c[3])
    if job.excl[k] or free[k] then
      table.remove(job.pend)
      saveJob()
    else
      checkpoint()
      local g = precisaVoltar({ c[1], c[2], c[3] })
      if g then viagemBase(g) end
      local ok, why = irPara(c[1], c[2], c[3])
      if not ok and why == 'cheio' then
        viagemBase('inventario')
      else
        if not ok and why ~= 'excluido' then marcarExcluido(c[1], c[2], c[3], why) end
        table.remove(job.pend)
        saveJob()
      end
    end
  end
end

local function minerar()
  setEstado('MINERANDO', 'Escavando')
  job.fase = 'MINA'
  while job.step < #plan do
    local i = job.step + 1
    checkpoint()
    local g = precisaVoltar(plan[i])
    if g then viagemBase(g) end
    local ok, why = executarStep(i)
    if not ok then
      if why == 'cheio' then viagemBase('inventario') else sleep(1) end
    else
      anel[#anel + 1] = { os.clock(), job.step, job.broken }
      if #anel > 40 then table.remove(anel, 1) end
      if job.step % 150 == 0 then salvarMem() end
    end
  end
  limparPendentes()
  emRetorno = true
  viagemBase('fim')
  virarPara(0) -- termina de COSTAS para o bau (olhando para a mina), pronta para a proxima tarefa
  emRetorno = false
  job.fase = 'CONCLUIDA'
  job.done = true
  saveJob()
  salvarMem()
  if fs.exists(MEMBASE) then fs.delete(MEMBASE) end
  memBaseSet = nil
  setEstado('CONCLUIDA', 'Escavacao finalizada; na base')
  log('concluida')
end

---------------------------------------------------------------------
-- PRE-VOO
---------------------------------------------------------------------
local function preflight()
  local r = {}
  local function add(nome, ok, msg, duro) r[#r + 1] = { nome = nome, ok = ok, msg = msg, duro = duro } end
  local ferr = false
  if turtle.getEquippedLeft then
    local l, rr = turtle.getEquippedLeft(), turtle.getEquippedRight()
    local n = (l and l.name or '') .. ' ' .. (rr and rr.name or '')
    ferr = n:find('pickaxe', 1, true) ~= nil
  else
    ferr = true
  end
  add('picareta', ferr, ferr and 'ok' or 'Equipe uma picareta', true)
  -- acha o bau girando e ajusta a direcao assumida (se a Turtle estiver virada para outro lado)
  local achados = {}
  for k = 0, 3 do
    if temBau() then achados[#achados + 1] = k end
    turtle.turnRight()
  end
  local esperado = (2 - job.dir) % 4
  local bau = false
  for _, k in ipairs(achados) do if k == esperado then bau = true end end
  if not bau and #achados == 1 then
    job.dir = (2 - achados[1]) % 4
    bau = true
  end
  virarPara(0)
  add('bau atras', bau, bau and 'ok' or 'Sem bau/Linked Chest atras da origem', true)
  if AUX_LADO then
    auxVirar()
    local suck = AUX_LADO == 'cima' or AUX_LADO == 'baixo'
    local ok, b
    if AUX_LADO == 'cima' then ok, b = turtle.inspectUp()
    elseif AUX_LADO == 'baixo' then ok, b = turtle.inspectDown()
    else ok, b = turtle.inspect() end
    virarPara(0)
    local aux = ok and casa(b.name, BAUS)
    add('bau auxiliar', aux, aux and 'ok' or 'Sem bau de combustivel em ' .. AUX_LADO, true)
  end
  local need = #plan + 60
  add('combustivel', fuelNum() >= RESERVA_COMB + 20, 'nivel ' .. tostring(turtle.getFuelLevel()) ..
    ' (estimado ' .. need .. ')', true)
  add('inventario livre', livres() >= 6, livres() .. ' slots livres', false)
  local selo = false
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and casa(d.name, SELOS) then selo = true end
  end
  add('bloco de selo', selo, selo and 'ok' or 'Sem pedra para selar liquidos (aviso)', false)
  local ok = true
  for _, c in ipairs(r) do if c.duro and not c.ok then ok = false end end
  return ok, r
end

---------------------------------------------------------------------
-- TAREFAS E COMANDOS
---------------------------------------------------------------------
local function reply(sender, ok, reason, action, extra)
  local m = { ok = ok, reason = reason, action = action, id = os.getComputerID(), nome = NOME }
  if extra then for k, v in pairs(extra) do m[k] = v end end
  rednet.send(sender, m, RES)
end

local function caixaDeMsg(msg)
  local b = {}
  local n = function(v) return tonumber(v) end
  if msg.dir ~= nil or msg.esq ~= nil or msg.cima ~= nil or msg.baixo ~= nil or msg.frente ~= nil then
    local esq, dir = n(msg.esq) or 0, n(msg.dir) or 0
    local cima, baixo, frente = n(msg.cima) or 0, n(msg.baixo) or 0, n(msg.frente)
    if not frente then return nil, 'Informe a frente (frente=N)' end
    b = { x0 = -esq, x1 = dir, y0 = -baixo, y1 = cima, z1 = frente }
  else
    local w, l, h = n(msg.w), n(msg.l), n(msg.h)
    if not (w and l and h) then return nil, 'Medidas ausentes' end
    local esq = 0
    if msg.pos == 'M' then
      esq = (VIES_MEIO == 'esq') and math.floor((w - 1) / 2) or math.ceil((w - 1) / 2)
    elseif msg.pos == 'D' then
      esq = w - 1
    end
    b = { x0 = -esq, x1 = w - 1 - esq, y0 = 0, y1 = h - 1, z1 = l - 1 }
  end
  for _, v in pairs(b) do
    if v % 1 ~= 0 then return nil, 'Medidas devem ser inteiras' end
  end
  if b.x0 > 0 or b.x1 < 0 or b.y0 > 0 or b.y1 < 0 or b.z1 < 0 then return nil, 'Margens invalidas' end
  local dx, dy, dz = b.x1 - b.x0 + 1, b.y1 - b.y0 + 1, b.z1 + 1
  if dx > LIMITE_DIM or dy > LIMITE_DIM or dz > LIMITE_DIM or dx * dy * dz > LIMITE_TOTAL then
    return nil, 'Area grande demais (max ' .. LIMITE_DIM .. ' por lado, ' .. LIMITE_TOTAL .. ' blocos)'
  end
  return b
end

local function novoJob(b, ordem)
  local aux = {}
  if AUX_LADO == 'cima' then aux[K(0, 1, 0)] = true
  elseif AUX_LADO == 'baixo' then aux[K(0, -1, 0)] = true
  elseif AUX_LADO == 'esq' then aux[K(-1, 0, 0)] = true
  elseif AUX_LADO == 'dir' then aux[K(1, 0, 0)] = true end
  return { v = 10, box = b, ordem = ordem or 'auto', step = 0, x = 0, y = 0, z = 0, dir = 0,
    broken = 0, viagens = 0, loot = {}, excl = aux, ext = {}, selos = {}, pend = {}, fase = 'MINA', done = false }
end

local function iniciar(msg, sender)
  local b, err = caixaDeMsg(msg)
  if not b then return reply(sender, false, err, 'escavar') end
  -- direcao real: apos uma tarefa a Turtle termina de frente para o bau
  local anterior = job or loadJob()
  local dir0 = (anterior and anterior.done and anterior.dir) or 0
  job = novoJob(b, msg.ordem)
  job.dir = dir0
  if msg.reescavar then memBaseSet = {} else memBaseSet = carregarSet(MEM) end
  salvarSet(MEMBASE, memBaseSet)
  plan = buildPlan(b, job.ordem, memBaseSet)
  if #plan == 0 then
    if fs.exists(MEMBASE) then fs.delete(MEMBASE) end
    memBaseSet = nil
    job, plan = anterior, nil
    return reply(sender, false, 'Nada novo a escavar: toda essa area ja esta na memoria. Use MEMORIA: IGNORAR para refazer.', 'escavar')
  end
  blocked = {}
  rebuildFree()
  local pulados = 0
  for x = b.x0, b.x1 do
    for y = b.y0, b.y1 do
      for z = 0, b.z1 do
        if memBaseSet[K(x, y, z)] then pulados = pulados + 1 end
      end
    end
  end
  local ok, rel = preflight()
  if not ok then
    local falhas = {}
    for _, c in ipairs(rel) do if c.duro and not c.ok then falhas[#falhas + 1] = c.nome .. ': ' .. c.msg end end
    job, plan = nil, nil
    return reply(sender, false, 'Pre-voo: ' .. table.concat(falhas, '; '), 'escavar', { preflight = rel })
  end
  cancelReq, returnReq, paused = false, false, false
  saveJob()
  log('iniciou ' .. (b.x1 - b.x0 + 1) .. 'x' .. (b.z1 + 1) .. 'x' .. (b.y1 - b.y0 + 1))
  setEstado('MINERANDO', 'Iniciando')
  runReq = true
  reply(sender, true, 'Escavacao iniciada (' .. #plan .. ' passos, ' .. pulados .. ' blocos ja escavados pulados)',
    'escavar', { preflight = rel, passos = #plan, pulados = pulados })
end

local function ocupado()
  return job ~= nil and not job.done and (trabalhando or runReq)
end

local function autorizado(msg) return SENHA == nil or msg.senha == SENHA end

local function handle(sender, msg)
  local act = msg.action
  if act == 'ping' then return reply(sender, true, 'Online', act) end
  if not autorizado(msg) then return reply(sender, false, 'Senha incorreta', act) end
  if act == 'escavar' then
    if ocupado() or (job and not job.done) then
      -- tarefa antiga esperando na base (VOLTAR): a nova a substitui
      if job and not job.done and job.fase == 'ESPERA' and not trabalhando and not runReq then
        job.done = true
        saveJob()
        log('tarefa em espera substituida')
      else
        return reply(sender, false, 'Tarefa em andamento', act)
      end
    end
    iniciar(msg, sender)
  elseif act == 'pausar' then
    paused = true
    reply(sender, true, 'Pausada', act)
  elseif act == 'continuar' then
    paused = false
    if job and not job.done and not trabalhando and not runReq then
      returnReq = false
      contReq = true
      runReq = true
      return reply(sender, true, 'Retomando', act)
    end
    returnReq = false
    reply(sender, true, 'Continuando', act)
  elseif act == 'cancelar' then
    if job and not job.done then
      cancelReq, paused = true, false
      if not trabalhando then runReq = true end
      reply(sender, true, 'Voltando ao bau e encerrando', act)
    else
      reply(sender, false, 'Nao ha tarefa ativa', act)
    end
  elseif act == 'esquecer' then
    if ocupado() or (job and not job.done) then return reply(sender, false, 'Termine ou cancele a tarefa antes', act) end
    free = { [K(0, 0, 0)] = true }
    memCount = 1
    if fs.exists(MEM) then fs.delete(MEM) end
    if fs.exists(MEMBASE) then fs.delete(MEMBASE) end
    if fs.exists(SAVE) then fs.delete(SAVE) end
    job, plan, memBaseSet = nil, nil, nil
    log('memoria apagada (a Turtle deve estar olhando para a frente)')
    reply(sender, true, 'Memoria da area escavada apagada', act)
  elseif act == 'voltar' then
    if job and not job.done and trabalhando then
      returnReq, paused = true, false
      reply(sender, true, 'Voltando ao bau e aguardando', act)
    else
      reply(sender, false, 'Nao esta minerando', act)
    end
  end
end

---------------------------------------------------------------------
-- TELEMETRIA
---------------------------------------------------------------------
local function slotsUsados()
  local s, n = 0, 0
  for i = 1, 16 do
    local q = turtle.getItemCount(i)
    n = n + q
    if q > 0 then s = s + 1 end
  end
  return s, n
end

local function taxas()
  local n = #anel
  if n < 2 then return nil, nil end
  local a, b = anel[1], anel[n]
  local dt = b[1] - a[1]
  if dt <= 0 then return nil, nil end
  return (b[2] - a[2]) / dt, (b[3] - a[3]) / dt * 60
end

local function publish()
  local s, n = slotsUsados()
  local total = plan and #plan or 0
  local step = job and job.step or 0
  local prog = (total > 0) and math.floor(100 * step / total) or 0
  local sps, bpm = taxas()
  local eta
  if sps and sps > 0 and step < total then eta = math.floor((total - step) / sps) end
  local b = job and job.box
  local legado = b and b.x0 == 0 and b.y0 == 0
  rednet.broadcast({
    versao = 1, v6 = true, v10 = true, id = os.getComputerID(), nome = NOME,
    status = estado, detalhe = detalhe, alerta = alerta,
    fuel = turtle.getFuelLevel(), slots = s, itens = n,
    progresso = prog, camada = job and (job.y + 1) or 0,
    camadas = b and (b.y1 - b.y0 + 1) or 0,
    largura = legado and (b.x1 + 1) or nil, comprimento = legado and (b.z1 + 1) or nil,
    altura = legado and (b.y1 + 1) or nil, caixa = b,
    blocos = job and job.broken or 0, passo = step, passos = total,
    x = job and job.x, y = job and job.y, z = job and job.z, dir = job and job.dir,
    fase = job and job.fase, viagens = job and job.viagens or 0, loot = job and job.loot,
    distBase = job and md(job.x, job.y, job.z, 0, 0, 0) or 0, eventos = eventos,
    mapa = job and mapaPlano() or nil, memoria = memCount,
    eta = eta, vel = bpm and math.floor(bpm + 0.5) or nil, pausada = paused,
    horario = textutils.formatTime(os.time(), true), lib = VERSAO,
  }, PROTO)
end

---------------------------------------------------------------------
-- REINICIO: resolve diario e reorienta
---------------------------------------------------------------------
local function modeloSolido(x, y, z)
  -- true = bloco, false = ar, nil = desconhecido
  if free[K(x, y, z)] then return false end
  if x == 0 and y == 0 and z == -1 then return true end
  return nil
end

local function reorientar(candidatos)
  -- gira nas 4 direcoes e compara com o modelo; ajusta job.dir
  local obs = {}
  for k = 0, 3 do
    obs[k] = turtle.detect()
    if k < 3 then turtle.turnRight() end
  end
  turtle.turnRight() -- volta a direcao original
  local melhores, n0 = {}, 0
  for _, cand in ipairs(candidatos) do
    local erros, certos = 0, 0
    for k = 0, 3 do
      local d = (cand + k) % 4
      local m = modeloSolido(job.x + DX[d], job.y, job.z + DZ[d])
      if m ~= nil then
        if m == obs[k] then certos = certos + 1 else erros = erros + 1 end
      end
    end
    if erros == 0 and certos > 0 then
      n0 = n0 + 1
      melhores[#melhores + 1] = cand
    end
  end
  if n0 == 1 then
    job.dir = melhores[1]
    return true
  end
  return false
end

local function resolverBoot()
  rebuildFree()
  local it = job.intent
  if not it then return true end
  if it.k == 'mv' then
    local f = fuelNum()
    if f == math.huge or it.fuel == math.huge then return false, 'movimento ambiguo (combustivel ilimitado)' end
    if f < it.fuel then
      job.x, job.y, job.z = it.tx, it.ty, it.tz
      markFree(job.x, job.y, job.z)
    end
    job.intent = nil
    saveJob()
    return true
  elseif it.k == 'turn' then
    job.intent = nil
    local okr = reorientar({ it.de, it.para })
    if not okr then
      -- tenta qualquer direcao
      okr = reorientar({ 0, 1, 2, 3 })
    end
    saveJob()
    if not okr then return false, 'direcao incerta' end
    return true
  end
  return true
end

---------------------------------------------------------------------
-- LACOS
---------------------------------------------------------------------
local function tratarFim(ok, err)
  if ok then return end
  if err == SENT_CANCEL then
    emRetorno = true
    local ok2, e2 = pcall(function()
      irParaBase()
      descarregar()
      virarPara(0)
    end)
    emRetorno = false
    cancelReq = false
    if ok2 then
      job.fase = 'CANCELADA'
      job.done = true
      saveJob()
      salvarMem()
      if fs.exists(MEMBASE) then fs.delete(MEMBASE) end
      memBaseSet = nil
      setEstado('CANCELADA', 'Na base. Tarefa encerrada.')
    else
      setEstado('ERRO', 'Falha ao voltar ao bau', tostring(e2))
    end
  elseif err == SENT_VOLTAR then
    emRetorno = true
    local ok2, e2 = pcall(function()
      irParaBase()
      descarregar()
      reabastecer()
      virarPara(0)
    end)
    emRetorno = false
    returnReq = false
    if ok2 then
      job.fase = 'ESPERA'
      saveJob()
      salvarMem()
      setEstado('NA BASE', 'Aguardando CONTINUAR')
    else
      setEstado('ERRO', 'Falha ao voltar ao bau', tostring(e2))
    end
  else
    log('erro: ' .. tostring(err))
    emRetorno = true
    local ok2 = pcall(irParaBase)
    emRetorno = false
    setEstado(ok2 and 'ERRO (NA BASE)' or 'ERRO', 'Falha inesperada', tostring(err))
    job.fase = 'ERRO'
    pcall(saveJob)
  end
end

local function executarJob()
  plan = plan or planoDoJob()
  if job.fase == 'VOLTANDO' or job.fase == 'BASE' then
    emRetorno = true
    irParaBase()
    descarregar()
    reabastecer()
    emRetorno = false
  end
  minerar()
end

local function telemetria()
  while true do
    publish()
    sleep(1)
  end
end

local function worker()
  while true do
    if runReq and job then
      runReq = false
      trabalhando = true
      local ok, err = pcall(executarJob)
      trabalhando = false
      tratarFim(ok, err)
      publish()
    end
    sleep(0.3)
  end
end

local function ouvinte()
  -- arranque: retoma tarefa salva
  free = carregarSet(MEM)
  free[K(0, 0, 0)] = true
  for _ in pairs(free) do memCount = memCount + 1 end
  local salvo = loadJob()
  if salvo and not salvo.done then
    job = salvo
    job.pend = job.pend or {}
    memBaseSet = nil
    plan = planoDoJob()
    blocked = {}
    local ok, why = resolverBoot()
    if not ok then
      setEstado('MODO SEGURO', tostring(why), 'Posicao incerta: confira a Turtle. Nao cava.')
      job.fase = 'SEGURO'
      log('modo seguro: ' .. tostring(why))
    elseif AUTO_RETOMAR and job.fase ~= 'ESPERA' and job.fase ~= 'ERRO' then
      setEstado('RETOMANDO', 'Retomando do passo ' .. job.step .. '/' .. #plan)
      sleep(3)
      runReq = true
    else
      setEstado('NA BASE', 'Aguardando CONTINUAR')
    end
  end
  print('Turtle ' .. os.getComputerID() .. ' (' .. NOME .. ') V' .. VERSAO .. ' pronta.')
  while true do
    local sender, msg = rednet.receive(CMD)
    if type(msg) == 'table' then
      local ok, err = pcall(handle, sender, msg)
      if not ok then
        print('Erro no comando: ' .. tostring(err))
        pcall(reply, sender, false, 'Erro interno: ' .. tostring(err), msg.action)
      end
    end
  end
end

if DOSCRIA_TEST then
  DOSCRIA_TEST.buildPlan = buildPlan
  DOSCRIA_TEST.astar = function(sx, sy, sz, d, gx, gy, gz, j, fr)
    job, free = j, fr
    return astar(sx, sy, sz, d, gx, gy, gz)
  end
  DOSCRIA_TEST.K = K
end

parallel.waitForAny(telemetria, ouvinte, worker)
