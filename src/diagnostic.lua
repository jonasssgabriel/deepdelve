-- DeepDelve | diagnostic.lua
-- Programa de teste: descobre o que funciona de verdade no seu mundo.
-- Roda NA TURTLE (menu 1 a 6). No computador do painel rode:  diagnostic eco
-- Nao escava nada e nao se move. Os testes que mexem em blocos ou itens
-- pedem confirmacao (digite SIM). O relatorio e salvo em diagnostic.txt.

local args = { ... }
local PORTA = 4242
local VERSAO = 'diag-1'

---------------------------------------------------------------------
-- MODO ECO (computador do painel): responde aos pings da Turtle
---------------------------------------------------------------------
local function acharModem()
  for _, n in ipairs(peripheral.getNames()) do
    local ok, tipo = pcall(peripheral.getType, n)
    if ok and tipo == 'modem' then
      local m = peripheral.wrap(n)
      if m and m.isWireless and m.isWireless() then return m, n end
    end
  end
  return nil
end

if args[1] == 'eco' then
  local m, nome = acharModem()
  if not m then
    print('Sem Wireless Modem neste computador.')
    return
  end
  m.open(PORTA)
  print('ECO ativo (canal ' .. PORTA .. '). Ctrl+T para sair.')
  print('Deixe rodando e va testar com a Turtle.')
  while true do
    local e, lado, canal, resp, msg, dist = os.pullEvent('modem_message')
    if canal == PORTA then
      m.transmit(resp, PORTA, msg)
      print(os.time() .. '  ' .. tostring(msg) .. '  dist=' .. tostring(dist and math.floor(dist) or '?'))
    end
  end
end

---------------------------------------------------------------------
-- Saida com relatorio e paginacao
---------------------------------------------------------------------
local rel = {}
local W, H = term.getSize()
local linhas = 0

local function parada()
  write('[ENTER para continuar] ')
  read()
  linhas = 0
end

local function out(s)
  s = tostring(s)
  rel[#rel + 1] = s
  print(s)
  linhas = linhas + math.max(1, math.ceil(#s / W))
  if linhas >= H - 2 then parada() end
end

local function pergunta(p)
  write(p)
  local r = read()
  rel[#rel + 1] = p .. tostring(r)
  return r
end

local function sim(p)
  return pergunta(p .. ' (SIM/NAO): '):upper() == 'SIM'
end

local function cabecalho(t)
  out('')
  out('== ' .. t .. ' ==')
end

local function nomes(t, max)
  local lista = {}
  for k in pairs(t) do lista[#lista + 1] = tostring(k) end
  table.sort(lista)
  if max and #lista > max then
    local cortada = {}
    for i = 1, max do cortada[i] = lista[i] end
    cortada[#cortada + 1] = '... +' .. (#lista - max)
    return table.concat(cortada, ', ')
  end
  return table.concat(lista, ', ')
end

local LADOS = {
  f = { 'frente', 'front', turtle and turtle.inspect, turtle and turtle.detect },
  c = { 'cima', 'top', turtle and turtle.inspectUp, turtle and turtle.detectUp },
  b = { 'baixo', 'bottom', turtle and turtle.inspectDown, turtle and turtle.detectDown },
}

---------------------------------------------------------------------
-- 1) Resumo automatico
---------------------------------------------------------------------
local function resumo()
  cabecalho('RESUMO DO SISTEMA')
  out('Programa: ' .. VERSAO)
  out('CC: ' .. tostring(_HOST))
  out('ID ' .. os.getComputerID() .. '  rotulo: ' .. tostring(os.getComputerLabel()))
  out('Avancado (cores): ' .. tostring(term.isColor and term.isColor()))

  if turtle then
    local f = turtle.getFuelLevel()
    local lim = turtle.getFuelLimit and turtle.getFuelLimit() or '?'
    out('Combustivel: ' .. tostring(f) .. ' / limite ' .. tostring(lim))
    if turtle.getEquippedLeft then
      local l, r = turtle.getEquippedLeft(), turtle.getEquippedRight()
      out('Equipado esquerda: ' .. (l and l.name or 'nada'))
      out('Equipado direita : ' .. (r and r.name or 'nada'))
    else
      out('getEquippedLeft/Right: indisponivel nesta versao')
    end
  else
    out('(nao e uma Turtle: testes de bloco/inventario indisponiveis)')
  end

  cabecalho('PERIFERICOS NOS LADOS')
  local achou = false
  for _, n in ipairs(peripheral.getNames()) do
    achou = true
    local tipos = { peripheral.getType(n) }
    out(n .. ' = ' .. table.concat(tipos, ','))
    local ok, mets = pcall(peripheral.getMethods, n)
    if ok and mets then
      local dic = {}
      for _, mm in ipairs(mets) do dic[mm] = true end
      out('   metodos: ' .. nomes(dic, 10))
    end
  end
  if not achou then out('nenhum periferico detectado') end
  local m = acharModem()
  out('Wireless Modem: ' .. (m and 'SIM' or 'NAO'))

  cabecalho('REDE / INTERNET / GPS')
  if http then
    for _, url in ipairs({ 'https://discord.com', 'https://example.com' }) do
      local ok, a, b = pcall(http.checkURL, url)
      out('HTTP ' .. url .. ': ' .. tostring(ok and a) .. (b and (' (' .. tostring(b) .. ')') or ''))
    end
  else
    out('HTTP desativado neste computador')
  end
  if gps and m then
    m.open(gps.CHANNEL_GPS or 65534)
    out('Procurando GPS (2s)...')
    local x, y, z = gps.locate(2)
    out(x and ('GPS: ' .. x .. ',' .. y .. ',' .. z) or 'GPS: sem sinal (nao ha constelacao de GPS)')
  else
    out('GPS: sem modem para testar')
  end

  cabecalho('ARMAZENAMENTO')
  local livre = fs.getFreeSpace and fs.getFreeSpace('/') or '?'
  out('Espaco livre no computador: ' .. tostring(livre) .. ' bytes')
  out('Speaker: ' .. tostring(peripheral.find('speaker') ~= nil))

  if turtle then
    cabecalho('INVENTARIO E COMBUSTIVEIS')
    local atual = turtle.getSelectedSlot()
    local vazio = true
    for i = 1, 16 do
      local d = turtle.getItemDetail(i)
      if d then
        vazio = false
        turtle.select(i)
        local comb = turtle.refuel(0) and ' [COMBUSTIVEL]' or ''
        out(i .. ': ' .. d.name .. ' x' .. d.count .. comb)
      end
    end
    if vazio then out('inventario vazio') end
    turtle.select(atual)
  end
end

---------------------------------------------------------------------
-- 2) Inspecionar bloco (nome e tags): aponte para um minerio
---------------------------------------------------------------------
local function inspecionar()
  cabecalho('INSPECIONAR BLOCO')
  if not turtle then out('So funciona na Turtle.') return end
  out('Aponte a Turtle para o bloco (minerio de outro mod, etc).')
  while true do
    local r = pergunta('Direcao f/c/b (ENTER sai): '):lower()
    if r == '' then return end
    local d = LADOS[r]
    if not d then
      out('Use f (frente), c (cima) ou b (baixo).')
    else
      local ok, b = d[3]()
      if not ok then
        out(d[1] .. ': nada para inspecionar (' .. tostring(b) .. ')')
      else
        out(d[1] .. ': ' .. tostring(b.name))
        if b.tags then out('   tags: ' .. nomes(b.tags, 14)) end
        if b.state and next(b.state) then out('   estado: ' .. nomes(b.state, 8)) end
        local minerio = false
        if b.tags then
          for t in pairs(b.tags) do
            if tostring(t):find('ores', 1, true) then minerio = true end
          end
        end
        out('   MINERIO (tag *ores*): ' .. (minerio and 'SIM' or 'nao'))
      end
    end
  end
end

---------------------------------------------------------------------
-- 3) Linked Chest (ou qualquer baú): depositar e conferir
---------------------------------------------------------------------
local function testeBau()
  cabecalho('TESTE DE BAU / LINKED CHEST')
  if not turtle then out('So funciona na Turtle.') return end
  out('Coloque o Linked Chest (ou outro bau) na frente, em cima')
  out('ou embaixo da Turtle e 1 item de teste (ex: pedra) em um slot.')
  local r = pergunta('Onde esta o bau? f/c/b: '):lower()
  local lado = { f = 'front', c = 'top', b = 'bottom' }
  local drop = { f = turtle.drop, c = turtle.dropUp, b = turtle.dropDown }
  local suck = { f = turtle.suck, c = turtle.suckUp, b = turtle.suckDown }
  if not lado[r] then out('Opcao invalida.') return end
  local insp = LADOS[r][3]
  local ok, b = insp()
  out('Bloco: ' .. (ok and tostring(b.name) or 'nenhum'))

  local present = peripheral.isPresent(lado[r])
  out('Aparece como periferico em "' .. lado[r] .. '": ' .. tostring(present))
  if present then
    local tipos = { peripheral.getType(lado[r]) }
    out('   tipos: ' .. table.concat(tipos, ','))
    local inv = peripheral.wrap(lado[r])
    if inv and inv.size then
      local okS, tam = pcall(inv.size)
      out('   size(): ' .. tostring(okS and tam or 'erro'))
      if inv.list then
        local okL, lst = pcall(inv.list)
        local n = 0
        if okL and lst then for _ in pairs(lst) do n = n + 1 end end
        out('   pilhas guardadas agora: ' .. n)
      end
    end
  end

  local slot = tonumber(pergunta('Slot (1-16) do item de teste (ENTER cancela): '))
  if not slot or slot < 1 or slot > 16 or turtle.getItemCount(slot) == 0 then
    out('Teste de deposito cancelado.')
    return
  end
  local d = turtle.getItemDetail(slot)
  out('Vai depositar 1 x ' .. d.name .. ' no bau.')
  if not sim('Confirma o deposito de 1 item') then return end
  turtle.select(slot)
  local antes = turtle.getItemCount(slot)
  local okD, motivo = drop[r](1)
  local depois = turtle.getItemCount(slot)
  out('drop(1) -> ' .. tostring(okD) .. (motivo and (' (' .. tostring(motivo) .. ')') or ''))
  out('Quantidade no slot: ' .. antes .. ' -> ' .. depois)
  if okD and depois < antes then
    out('RESULTADO: a Turtle CONSEGUE depositar nesse bau.')
  else
    out('RESULTADO: deposito FALHOU (bau cheio, canal sem acesso ou nao aceita).')
  end
  if okD then
    out('Para conferir, abra o bau no outro ponto do canal.')
    if sim('Quer pegar o item de volta (suck) - pode vir outro item do canal') then
      local okP, m2 = suck[r](1)
      out('suck(1) -> ' .. tostring(okP) .. (m2 and (' (' .. tostring(m2) .. ')') or ''))
    end
  end
end

---------------------------------------------------------------------
-- 4) Chunk loader: a Turtle consegue colocar?
---------------------------------------------------------------------
local function testeLoader()
  cabecalho('TESTE DE CHUNK LOADER')
  if not turtle then out('So funciona na Turtle.') return end
  out('Deixe o espaco a FRENTE vazio e coloque 1 Chunk Loader')
  out('(item) em um slot. Depois confira na tela do loader')
  out('quem e o dono e se os chunks ficam carregados.')
  local slot = tonumber(pergunta('Slot (1-16) do chunk loader (ENTER cancela): '))
  if not slot or slot < 1 or slot > 16 or turtle.getItemCount(slot) == 0 then
    out('Cancelado.')
    return
  end
  local d = turtle.getItemDetail(slot)
  out('Item: ' .. d.name)
  if turtle.detect() then out('Ha um bloco na frente. Libere o espaco.') return end
  if not sim('Colocar este bloco na frente agora') then return end
  turtle.select(slot)
  local ok, motivo = turtle.place()
  out('place() -> ' .. tostring(ok) .. (motivo and (' (' .. tostring(motivo) .. ')') or ''))
  local ins, b = turtle.inspect()
  out('Bloco agora na frente: ' .. (ins and tostring(b.name) or 'nada'))
  if ok then
    out('Abra a tela do loader e veja: dono, chunks carregados.')
    if sim('Recolher o bloco de volta (precisa de picareta)') then
      local okC, m2 = turtle.dig()
      out('dig() -> ' .. tostring(okC) .. (m2 and (' (' .. tostring(m2) .. ')') or ''))
    end
  end
end

---------------------------------------------------------------------
-- 5) Alcance do modem (rode "diagnostic eco" no computador do painel)
---------------------------------------------------------------------
local function testeAlcance()
  cabecalho('TESTE DE ALCANCE DO MODEM')
  local m = acharModem()
  if not m then out('Sem Wireless Modem.') return end
  out('No computador do painel rode: diagnostic eco')
  out('Afaste-se andando e veja ate onde responde.')
  local n = tonumber(pergunta('Quantos pings (padrao 30, 1 por segundo): ')) or 30
  m.open(PORTA + 1)
  local ok, falhou, maior = 0, 0, 0
  for i = 1, n do
    m.transmit(PORTA, PORTA + 1, 'ping' .. i)
    local timer = os.startTimer(1)
    local got = false
    while true do
      local e, a, canal, resp, msg, dist = os.pullEvent()
      if e == 'modem_message' and canal == PORTA + 1 then
        ok = ok + 1
        got = true
        if dist and dist > maior then maior = dist end
        print('#' .. i .. ' resposta dist=' .. tostring(dist and math.floor(dist) or '?'))
        break
      elseif e == 'timer' and a == timer then
        falhou = falhou + 1
        print('#' .. i .. ' sem resposta')
        break
      end
    end
    if got then sleep(1) end
  end
  out('Respostas: ' .. ok .. '  Falhas: ' .. falhou .. '  Maior distancia: ' .. math.floor(maior))
  out('Se a maior distancia ficou perto de 64, o limite padrao esta valendo.')
end

---------------------------------------------------------------------
-- 6) Salvar relatorio
---------------------------------------------------------------------
local function salvar()
  local f = fs.open('diagnostic.txt', 'w')
  if not f then
    print('Nao consegui salvar diagnostic.txt')
    return
  end
  f.write(table.concat(rel, '\n'))
  f.close()
  print('Salvo em diagnostic.txt (' .. #rel .. ' linhas).')
end

---------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------
term.clear()
term.setCursorPos(1, 1)
print('DEEPDELVE - DIAGNOSTIC')
print('Nada aqui escava ou anda. Ctrl+T sai.')
while true do
  print('')
  print('1 Resumo automatico')
  print('2 Inspecionar bloco / tags')
  print('3 Testar Linked Chest / bau')
  print('4 Testar colocar Chunk Loader')
  print('5 Testar alcance do modem')
  print('6 Salvar relatorio e sair')
  local op = pergunta('Opcao: ')
  linhas = 0
  if op == '1' then resumo()
  elseif op == '2' then inspecionar()
  elseif op == '3' then testeBau()
  elseif op == '4' then testeLoader()
  elseif op == '5' then testeAlcance()
  elseif op == '6' then
    salvar()
    return
  end
end
