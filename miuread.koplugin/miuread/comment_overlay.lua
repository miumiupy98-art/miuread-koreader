-- B3: paints cached comment anchors after the reader text, never into EPUB.
local Range=require("miuread.annotations.range")
local M={}; M.__index=M

function M:new()
    return setmetatable({records={},visible={},enabled=true,last_page=nil},self)
end

function M:setRecords(rows)
    rows=type(rows)=="table" and rows or {}
    local changed=#rows~=#self.records
    if not changed then
        for i,row in ipairs(rows) do
            local old=self.records[i]
            if row.book_id~=old.book_id or row.chapter_uid~=old.chapter_uid or row.range~=old.range
                or row.pos0~=old.pos0 or row.pos1~=old.pos1 or row.quote~=old.quote then
                changed=true
                break
            end
        end
    end
    if changed then
        self.records=rows
        self:invalidate()
    end
    return changed
end
function M:setEnabled(value)
    value=value==true
    if self.enabled~=value then
        self.enabled=value
        self:invalidate()
    end
end
function M:invalidate()
    self.visible={}
    self.last_page=nil
    self.generation=(self.generation or 0)+1
    self._last_visible_key=nil
    self._last_visible={}
end

local function intersects(a,b)
    return a.x<b.x+b.w and a.x+a.w>b.x and a.y<b.y+b.h and a.y+a.h>b.y
end

local function geometry(ui,screen)
    local doc=ui.document
    local size=ui.view and ui.view.dimen or ui.dimen
    local viewport={x=size and size.x or 0,y=size and size.y or 0,
        w=size and size.w or screen:getWidth(),h=size and size.h or screen:getHeight()}
    local view=ui.view
    if view and view.footer_visible and view.footer and type(view.footer.getHeight)=="function" then
        viewport.h=math.max(1,viewport.h-view.footer:getHeight())
    end
    local top=type(doc.getCurrentPos)=="function" and tonumber(doc:getCurrentPos()) or nil
    local page=type(doc.getCurrentPage)=="function" and doc:getCurrentPage() or 0
    local key=table.concat({top or "",page or "",viewport.x,viewport.y,viewport.w,viewport.h},":")
    return viewport,top,key
end

function M:paintTo(bb)
    self.visible={}
    if not self.enabled or #self.records==0 then return end
    local doc=self.ui and self.ui.document
    if not doc or type(doc.getScreenBoxesFromPositions)~="function" then return end
    local okBB,BB=pcall(require,"ffi/blitbuffer")
    if not okBB or not BB then return end
    local screen=require("device").screen
    local ink=BB.Color8(0x80)
    local px=math.max(1,screen:scaleBySize(1))
    local viewport,top,view_key=geometry(self.ui,screen)
    local count=type(doc.getVisiblePageCount)=="function" and
        tonumber(doc:getVisiblePageCount()) or 1
    local bottom=top and top+viewport.h*math.max(1,count or 1) or nil
    local key=tostring(self.generation or 0)..":"..view_key
    if self._last_visible_key~=key then
        local entries={}
        for _,record in ipairs(self.records) do
            local should_check=true
            if top and type(doc.getPosFromXPointer)=="function" then
                local ok0,first=pcall(doc.getPosFromXPointer,doc,record.pos0)
                local ok1,last=pcall(doc.getPosFromXPointer,doc,record.pos1)
                if ok0 and ok1 and tonumber(first) and tonumber(last) then
                    should_check=first<=bottom and last>=top
                end
            end
            if should_check then
                local ok,boxes=pcall(doc.getScreenBoxesFromPositions,doc,record.pos0,record.pos1,true)
                if ok and type(boxes)=="table" then
                    for _,rect in ipairs(boxes) do
                        if type(rect)=="table" and tonumber(rect.x) and tonumber(rect.y)
                            and tonumber(rect.w) and tonumber(rect.h) and rect.w>0 and rect.h>0
                            and intersects(rect,viewport) then
                            entries[#entries+1]={rect=rect,record=record}
                        end
                    end
                end
            end
        end
        self._last_visible=entries
        self._last_visible_key=key
    end
    self.visible={}
    self._painted_view_key=view_key
    for _,entry in ipairs(self._last_visible) do
        local rect=entry.rect
        -- Screen boxes can straddle the reader viewport. Never draw a mark
        -- into the toolbar, margins outside the viewport, or negative pixels.
        local left=math.max(0,viewport.x,rect.x)
        local right=math.min(screen:getWidth(),viewport.x+viewport.w,rect.x+rect.w)
        local viewport_top=math.max(0,viewport.y)
        local viewport_bottom=math.min(screen:getHeight(),viewport.y+viewport.h)
        local line_bottom=rect.y+rect.h
        local y=math.min(line_bottom+2*px,viewport_bottom-px)
        if left<right and rect.y<viewport_bottom and y>=viewport_top and line_bottom>=viewport_top then
            for x=left,right-1,7*px do
                local width=math.min(4*px,right-x)
                if width>0 then bb:paintRect(x,y,width,px,ink) end
            end
            self.visible[#self.visible+1]={record=entry.record,left=left,right=right,
                top=math.max(rect.y,viewport_top),bottom=y+px,mark_y=y,text_bottom=math.min(line_bottom,viewport_bottom)}
        end
    end
end

function M:hitTest(pos)
    if not self.enabled or type(pos)~="table" then return nil end
    local x,y=tonumber(pos.x),tonumber(pos.y)
    if not x or not y then return nil end
    if #self.visible==0 or not (self.ui and self.ui.document) then return nil end
    local screen=require("device").screen
    local _,_,key=geometry(self.ui,screen)
    if key~=self._painted_view_key then return nil end
    local best,distance,span,bounds
    for _,item in ipairs(self.visible) do
        if x>=item.left-2 and x<=item.right+2 and y>=item.top and y<=item.bottom+2 then
            local range_start,range_stop=Range.parse(item.record.range)
            local width=range_start and range_stop and range_stop-range_start or item.right-item.left
            local delta=math.abs(y-item.mark_y)
            if not best or delta<distance or (delta==distance and width<span) then
                best,distance,span,bounds=item.record,delta,width,item
            end
        end
    end
    return best,bounds
end
return M
