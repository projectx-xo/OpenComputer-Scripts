local term=require('term')
local event=require('event')
local computer=require('computer')
local serialization=require('serialization')
local unicode=require('unicode')

return function(service,model)
    if term.isAvailable and not term.isAvailable() then return 'console' end
    local gpu=term.gpu and term.gpu() or require('component').gpu
    if not gpu then return 'console' end
    local fg,fgPalette=gpu.getForeground();local bg,bgPalette=gpu.getBackground()
    local cx,cy=term.getCursor()
    local blink=term.getCursorBlink and term.getCursorBlink()
    local colors={normal=0xC0CCD8,title=0x55DDFF,section=0x55DDFF,good=0x77DD88,warn=0xFFCC66,bad=0xFF7777}
    local initial=service.status().version
    local snapshot,received,request,deadline,nextRequest=nil,nil,nil,nil,0
    local offset,cache,lastWidth,lastHeight,lastX,lastY=0,{},nil,nil,nil,nil
    local function clipped(value,width)
        local s=unicode.sub(tostring(value):gsub('[%c]',' '),1,width)
        while unicode.wlen(s)>width do s=unicode.sub(s,1,unicode.len(s)-1) end
        return s..string.rep(' ',math.max(0,width-unicode.wlen(s)))
    end
    local function loop()
        if term.setCursorBlink then term.setCursorBlink(false) end
        while true do
            local now=computer.uptime();local status=service.status()
            if status.version~=initial then return 'reload' end
            if request then
                local result=service.result(request)
                if result then
                    request=nil
                    if result.ok then
                        local ok,value=pcall(serialization.unserialize,result.text)
                        if ok and type(value)=='table' then snapshot=value;received=now end
                    end
                elseif now>=deadline then request=nil end
            end
            if not request and now>=nextRequest and status.state=='running' then
                request=service.submit('snapshot');deadline=now+8;nextRequest=now+3
            end
            local width,height,dx,dy=term.getViewport();dx=dx or 0;dy=dy or 0
            width=math.max(1,math.floor(width));height=math.max(1,math.floor(height))
            if width~=lastWidth or height~=lastHeight or dx~=lastX or dy~=lastY then
                cache={};lastWidth=width;lastHeight=height;lastX=dx;lastY=dy
            end
            local age=received and now-received or nil
            local rows=model(snapshot,status,service.logs(5),age)
            if not received or age>10 then table.insert(rows,3,{text=received and 'STALE SNAPSHOT - waiting for node' or 'Waiting for node snapshot...',tone='warn'}) end
            local visible=math.max(1,height-3)
            offset=math.max(0,math.min(offset,math.max(0,#rows-visible)))
            local screen={}
            if width>=20 and height>=6 then
                screen[1]={text='+'..string.rep('-',width-2)..'+',tone='section'}
                for i=1,height-3 do
                    local r=rows[offset+i] or {text='',tone='normal'}
                    screen[i+1]={text='| '..clipped(r.text,width-4)..' |',tone=r.tone}
                end
                screen[height-1]={text='+'..string.rep('-',width-2)..'+',tone='section'}
                screen[height]={text='C console | Q detach | Up/Down scroll',tone='section'}
            else
                screen[1]={text='STRATCOM: '..tostring(status.state),tone='title'}
                for i=2,height-1 do screen[i]=rows[offset+i-1] or {text='',tone='normal'} end
                if height>1 then screen[height]={text='C console  Q exit',tone='section'} end
            end
            gpu.setBackground(0x081018)
            for y=1,height do
                local row=screen[y] or {text='',tone='normal'};local text=clipped(row.text,width)
                local color=colors[row.tone] or colors.normal
                if not cache[y] or cache[y].text~=text or cache[y].color~=color then
                    gpu.setForeground(color);gpu.set(dx+1,dy+y,text);cache[y]={text=text,color=color}
                end
            end
            local name,_,char,key=event.pull(.25)
            if name=='interrupted' then return 'detach' end
            if name=='key_down' then
                if char==99 or char==67 then return 'console' end
                if char==113 or char==81 then return 'detach' end
                if key==200 then offset=offset-1 elseif key==208 then offset=offset+1 end
            end
        end
    end
    local ok,result=pcall(loop)
    pcall(gpu.setForeground,fg,fgPalette);pcall(gpu.setBackground,bg,bgPalette)
    pcall(term.clear);pcall(term.setCursor,cx,cy)
    if term.setCursorBlink then pcall(term.setCursorBlink,blink==nil and true or blink) end
    if not ok then print('Node dashboard unavailable: '..tostring(result));return 'console' end
    return result
end
