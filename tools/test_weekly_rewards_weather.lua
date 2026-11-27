package.path="./miuread.koplugin/?.lua;"..package.path

local Rewards=require("miuread.weekly_rewards")
local open={readtimeAwards={{
    awardLevelId=4,awardStatus=1,awardLevelDesc="读 5 分钟",
    awardChoices={{choiceType=1,awardNum=2},{choiceType=2,awardNum=3,canChoice=0}},
}},readingTime=412,readingDay=1}
local closed={readtimeAwards={{awardLevelId=4,awardStatus=2,awardChooseType=1}}}
local client={reads=0,writes=0,current=open}
function client:request(method,path,payload,stage,options)
    assert(method=="POST" and path=="/weekly/exchange" and stage=="rewards")
    if payload.isExchangeAward==0 then
        self.reads=self.reads+1
        assert(payload.awardLevelId==0 and payload.awardChoiceType==0)
        return self.current
    end
    assert(payload.awardLevelId==4 and payload.awardChoiceType==1 and options.single_dispatch)
    self.writes=self.writes+1
    self.current=closed
    error("lost reply after processing")
end
assert(Rewards.query(client).tiers[1].choices[1].enabled)
assert(Rewards.claim(client,4,2,3).state=="changed" and client.writes==0)
assert(Rewards.claim(client,4,1,3).state=="changed" and client.writes==0)
assert(Rewards.claim(client,4,1,2).state=="received" and client.writes==1)
assert(Rewards.claim(client,4,1,2).state=="changed" and client.writes==1)
client.current=open
function client:request(_,_,payload)
    if payload.isExchangeAward==0 then return self.current end
    self.writes=self.writes+1
    error("lost reply without processing")
end
assert(Rewards.claim(client,4,1,2).state=="unconfirmed" and client.writes==2)

local Weather=require("miuread.weather")
local http={}
function http:get_json(url,options)
    assert(options.auth==false and url:match("^https://"))
    if url:find("geocoding%-api") then
        assert(url:find("%26",1,true))
        return {results={{name="东京",latitude=35.68,longitude=139.76,country="日本"},
            {name="坏数据",latitude=92,longitude=44}}}
    end
    assert(url:find("latitude=35.68000",1,true) and url:find("longitude=139.76000",1,true))
    return {current={temperature_2m=10.8,weather_code=61}}
end
local cities=Weather.cities(http,"东京&Tokyo")
assert(#cities==1 and cities[1].detail=="日本")
assert(Weather.current(http,cities[1]).text=="11°C · 小雨")

package.loaded["ui/uimanager"]={}
package.loaded["libs/libkoreader-lfs"]={}
local Account=require("miuread.reading_account_ui")
local member={expiredTime=10}
function member:membership_summary() return {expiredTime=self.expiredTime} end
function member:request(method,path,parameters,stage)
    assert(method=="GET" and path=="/pay/memberCardDetails" and stage=="account")
    assert(parameters.pf=="android" and parameters.getPredicted==(self.expiredTime>0 and 0 or 1))
    return {data={{name="会员专属书库"}}}
end
local plugin={menus=0}
function plugin:_fetch_eink_display(_,_,worker,_,done)
    return done(worker({_native=function() return member end}))
end
function plugin:_show_miuread_menu(title,rows)
    assert(title=="会员权益明细" and rows[1].text=="会员专属书库" and rows[1].readonly_label)
    self.menus=self.menus+1
end
Account.member_benefits(plugin)
member.expiredTime=0
Account.member_benefits(plugin)
assert(plugin.menus==2)
print("Weekly reward eligibility and readback, anonymous weather, and native member benefits passed")
