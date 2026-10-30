"""Offline reading-time protocol, real SQLite ledger and KOReader adapter tests.

Only the runtime/HTTP boundaries are mocked. No account or live API is used.
Requires lupa (LuaJIT); run from the repository root.
"""
import hashlib
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

from lupa.luajit21 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1]


def runtime(root):
    lua = LuaRuntime(unpack_returned_tuples=True)

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value

    def from_lua(value):
        if lua_type(value) == "table":
            keys = list(value.keys())
            if keys and set(keys) == set(range(1, len(keys) + 1)):
                return [from_lua(value[i]) for i in range(1, len(keys) + 1)]
            return {k: from_lua(v) for k, v in value.items()}
        return value

    lua.globals().json_encode = lambda v: json.dumps(from_lua(v), ensure_ascii=False)
    lua.globals().json_decode = lambda v: to_lua(json.loads(v))
    lua.globals().fixture_root = root.as_posix()
    lua.globals().plugin_root = (ROOT / "miuread.koplugin").as_posix()
    lua.globals().py_open = lambda p, mode=None: sqlite3.connect(
        f"file:{p}?mode=ro" if mode == "ro" else p,
        uri=mode == "ro", isolation_level=None,
    )
    def execute(connection, sql):
        cursor = connection.execute(sql)
        cursor.fetchall()
        cursor.close()

    lua.globals().py_exec = execute
    lua.globals().py_query = lambda c, s, p: c.execute(s, tuple(from_lua(p)) if list(p.keys()) else ())
    lua.globals().py_stmt_close = lambda c: c.close()

    def fetch(cursor):
        row = cursor.fetchone()
        return to_lua(list(row)) if row is not None else None

    lua.globals().py_fetch = fetch
    lua.globals().py_close = lambda c: c.close()
    lua.execute(r'''
        package.path=plugin_root..'/?.lua;'..package.path
        local function copy(v)
            if type(v)~='table' then return v end
            local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
        end
        package.preload['miuread.util']=function() return {copy=copy,mkdir=function() return true end} end
        package.preload['miuread.json']=function() return {encode=json_encode,decode=json_decode} end
        package.preload['logger']=function() return {info=function() end,warn=function() end} end
        package.preload['miuread.http']=function() return {
            is_rate_limit_error=function() return false end,is_auth_error=function() return false end,
            rate_limit_details=function() end,auth_error_code=function() end,
        } end
        package.preload['lua-ljsqlite3/init']=function() return {open=function(path,mode)
            local handle=py_open(path,mode)
            return {exec=function(_,sql) return py_exec(handle,sql) end,
                close=function() py_close(handle) end,
                prepare=function(_,sql)
                    local params,cursor={},nil
                    local stmt={}
                    function stmt:bind(...) params={...}; return self end
                    function stmt:step()
                        if not cursor then cursor=py_query(handle,sql,params) end
                        return py_fetch(cursor)
                    end
                    function stmt:close() if cursor then py_stmt_close(cursor) end end
                    return stmt
                end}
        end} end
        local real_date=os.date
        os.date=function(format,stamp)
            if format=='%z' then return '+0800' end
            return real_date(format,stamp)
        end
        Protocol=require('miuread.readtime_protocol')
        Outbox=require('miuread.readtime_outbox')
        Stats=require('miuread.readtime_stats')
        store={data_dir=fixture_root}
        queue=Outbox.new(store)
        function begin(id,at)
            return queue:begin('a',{id=id,book_id='book',start_time=at,time_zone='+08:00'})
        end
    ''')
    return lua


class OfflineReadtimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.lua = runtime(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_signature_reference_vector(self):
        # Public captured-request vector from moon's GPL-3.0 app_spec.lua.
        self.lua.execute('''
            local payload='393727764_35645832171399234841676621530100678335_35645832171399234841676621530100678335_CB_00K1XI1aSDlZ76f75hG9n7JG_0_+08:00_81_0_1792317600_+08:00_81_0'
            local token,source=Protocol.guest_token({feature={}})
            assert(source=='client_default')
            assert(Protocol.sign({token,'821','1792318161',payload})==
                'dfd6f2ceb1e4a5d1152c6d19fd9c9f84115cad69989ee799faec377d05d8a833')
        ''')

    def test_signature_feature_override_default_and_invalid_types(self):
        self.lua.execute('''
            local token,source=Protocol.guest_token({feature={guest_token='remote-fixture'}})
            assert(token=='remote-fixture' and source=='remote')
            local default=Protocol.guest_token({feature={}})
            assert(default==Protocol.guest_token({feature={guest_token=''}}))
            assert(default==Protocol.guest_token({}))
            assert(not pcall(Protocol.guest_token,{feature={guest_token={}}}))
            assert(not pcall(Protocol.guest_token,{feature={guest_token=false}}))
            assert(not pcall(Protocol.guest_token,{feature='invalid'}))
        ''')

    def test_native_time_only_batch_and_historical_hours(self):
        self.lua.execute('''
            batch=Protocol.batch({vid='123',deviceId='fixture-device'},'book',{
                {start_time=86390,duration=20,time_zone='+08:00'},
                {start_time=86500,duration=8,time_zone='+08:00'}},'guest','config',1792318161,7)
            local body=batch.books[1]
            assert(body.hours[1].startOfHour==82800 and body.hours[1].readingTime==10)
            assert(body.hours[2].startOfHour==86400 and body.hours[2].readingTime==18)
            assert(body.readingTime==28 and body.isResendReadingInfo==1)
            assert(body.chapterUid==nil and body.chapterIdx==nil and body.chapterOffset==nil)
            assert(batch.timestamp==1792318161000 and body.timestamp==1792318161)
            assert(not pcall(Protocol.batch,{vid='123'},'book',{},'','',1,1))
        ''')
        expected = hashlib.sha256(b"1792318161000config7").hexdigest()
        self.assertEqual(self.lua.eval("batch.signature"), expected)

    def test_native_wire_fields_match_inspected_dto_and_envelope(self):
        # Independent contract from the pinned DEX annotations/serializer,
        # including the surprising novalTime spelling and excluded voiceType.
        contract = json.loads((ROOT / "tools/fixtures/eink_readtime_212_contract.json").read_text(encoding="utf-8"))
        self.lua.execute('''
            local sign=Protocol.sign
            Protocol.sign=function(parts) signed_parts=parts; return sign(parts) end
            batch=Protocol.batch({vid='123',deviceId='fixture-device'},'book',{
                {start_time=1792317600,duration=81,time_zone='+08:00'}},
                'guest','config',1792318161,7,{timestamp=1792318162456,random=0})
            Protocol.sign=sign
        ''')
        body = json.loads(self.lua.eval("json_encode(batch.books[1])"))
        envelope = json.loads(self.lua.eval("json_encode(batch)"))
        self.assertEqual(set(body), set(contract["base_book_wire_fields"]))
        self.assertTrue(all(field not in body for field in contract["excluded_book_fields"]))
        self.assertIs(body["finish"], False)
        self.assertEqual(body["novalTime"], 0)
        self.assertEqual(set(body["hours"][0]), set(contract["hour_fields"]))
        self.assertEqual(set(envelope), set(contract["request"]["required_envelope_fields"]))
        self.assertEqual(envelope["timestamp"], 1792318162456)
        self.assertEqual(envelope["random"], 0)
        self.assertEqual(body["timestamp"], 1792318161)
        self.assertEqual(body["random"], 7)
        self.assertEqual(envelope["signature"], hashlib.sha256(b"1792318162456config0").hexdigest())
        self.assertEqual(json.loads(self.lua.eval("json_encode(signed_parts)")), [
            "guest", "7", "1792318161",
            "123_fixture-device__book_0_+08:00_81_0_1792317600_+08:00_81_0",
        ])
        self.lua.execute('''
            assert(not pcall(Protocol.batch,{vid='123',deviceId='d'},'book',{
                {start_time=1000,duration=10,time_zone='+08:00'}},'g','c',2000,7,
                {timestamp=2000000,random=1000}))
        ''')

    def test_native_zone_uses_standard_offset_including_non_hour_dst(self):
        # mktime with isdst=false must be used; a hard-coded minus one hour
        # would fail Lord Howe's 30-minute DST and negative DST.
        self.lua.execute('''
            local date,time=os.date,os.time
            local stamp=1792318161
            for _,case in ipairs({
                {'+0200',3600,'+01:00'},
                {'+1100',1800,'+10:30'},
                {'+0000',-3600,'+01:00'},
                {'-0400',3600,'-05:00'},
            }) do
                os.date=function(format)
                    if format=='%z' then return case[1] end
                    return {year=2026,month=10,day=25,hour=12,min=0,sec=0,isdst=true}
                end
                os.time=function(fields)
                    assert(fields.isdst==false)
                    return stamp+case[2]
                end
                assert(Protocol.time_zone(stamp)==case[3])
            end
            os.date,os.time=date,time
            assert(Protocol.time_zone(stamp)=='+08:00')
        ''')

    def test_watermarks_memory_database_and_growth(self):
        self.lua.execute('''
            assert(begin('w',100))
            local rows={{page=1,start_time=90,duration=30},{page=1,start_time=90,duration=30}}
            assert(queue:collect('a','w',rows,120).seconds==20)
            assert(queue:collect('a','w',rows,120).seconds==0)
            assert(queue:collect('a','w',{{page=1,start_time=90,duration=40}},130).seconds==10)
            assert(queue:summary('a').pending==30)
            assert(queue:summary('b').pending==0)
        ''')
        other = runtime(self.root)
        self.assertEqual(other.eval("queue:summary('a').pending"), 30)

    def test_crash_after_claim_is_unknown_and_never_replayed(self):
        self.lua.execute('''
            begin('w',100)
            queue:collect('a','w',{{page=1,start_time=100,duration=20}},120,true)
            batch=queue:pending('a',120)
            assert(queue:claim('a',batch,'attempt'))
            assert(not queue:claim('a',batch,'other'))
        ''')
        other = runtime(self.root)
        other.execute('''
            assert(queue:recover('a')==1)
            assert(queue:summary('a').unknown==20)
            assert(#queue:pending('a',999).rows==0)
        ''')

    def test_confirmation_removes_only_claimed_rows_and_keeps_watermark(self):
        self.lua.execute('''
            begin('w',100)
            queue:collect('a','w',{{page=1,start_time=100,duration=20}},120)
            local batch=queue:pending('a',120)
            queue:claim('a',batch,'one')
            queue:collect('a','w',{{page=1,start_time=100,duration=30}},130)
            queue:finish('a',batch,'one','confirmed',130)
            assert(queue:summary('a').pending==10)
            assert(queue:collect('a','w',{{page=1,start_time=100,duration=30}},130).seconds==0)
        ''')

    def test_suspend_resume_uses_original_statistics_rules(self):
        self.lua.execute('''
            local stats={settings={min_sec=5,max_sec=120},curr_page=1,page_stat={[1]={{100,0}}}}
            begin('before',100)
            queue:collect('a','before',Stats.snapshot(stats,150),150,true)
            stats.page_stat[1][1][1]=200 -- KOReader shifts start by 100s asleep
            begin('after',250)
            queue:collect('a','after',Stats.snapshot(stats,280),280)
            assert(queue:summary('a').pending==80) -- 50 + 30, never 180
            assert(#Stats.snapshot(stats,203)==0)
            assert(Stats.snapshot(stats,500)[1].duration==120)
        ''')

    def test_short_pause_reuses_tuple_identity_and_database_alias(self):
        self.lua.execute('''
            local stats={settings={min_sec=5,max_sec=120},curr_page=1,page_stat={[1]={{100,0}}}}
            local sources=setmetatable({},{__mode='k'})
            begin('w',100)
            queue:collect('a','w',Stats.snapshot(stats,120,sources),120)
            stats.page_stat[1][1][1]=200
            queue:collect('a','w',Stats.snapshot(stats,280,sources),280)
            assert(queue:summary('a').pending==80)
            -- Same shifted tuple later flushed into statistics.sqlite3.
            queue:collect('a','w',{{page=1,start_time=200,duration=80}},280)
            assert(queue:summary('a').pending==80)
        ''')

    def test_corrupt_ledger_fails_closed(self):
        self.lua.execute("assert(begin('w',100))")
        connection = sqlite3.connect(self.root / "readtime-outbox.sqlite3")
        try:
            connection.execute("UPDATE kv SET value='corrupt' WHERE key='account:a'")
            connection.commit()
        finally:
            connection.close()
        self.lua.execute('''
            local result,err=queue:pending('a',999)
            assert(result==nil and err=='ledger_failed')
        ''')

    def test_long_page_is_split_and_does_not_block_batch_limit(self):
        self.lua.execute('''
            begin('w',100)
            queue:collect('a','w',{{page=1,start_time=100,duration=850}},950,true)
            local first=queue:pending('a',950)
            assert(first.seconds==600)
            queue:claim('a',first,'first')
            queue:finish('a',first,'first','confirmed',950)
            local second=queue:pending('a',951)
            assert(second.seconds==250 and #second.rows>0)
        ''')

    def test_native_dispatch_boundary_and_no_http_retries(self):
        self.lua.execute('''
            local transport=require('miuread.eink_readtime')
            local calls=0
            local http={post_json=function(_,url,body,options)
                calls=calls+1
                assert(options.retries==0 and options.rate_limit_retries==0)
                assert(url=='https://i.weread.qq.com/book/batchUploadProgress')
                error('synthetic transport failure')
            end}
            local prepared={credentials={vid='123',accessToken='secret'},body={}}
            assert(transport.send(http,prepared,function() return false end).dispatched==false)
            assert(calls==0)
            assert(transport.send(http,prepared,function() return true end).state=='unknown')
            assert(calls==1)
            http.post_json=function() return {succ=1} end
            assert(transport.send(http,prepared,function() return true end).state=='confirmed')
            http.post_json=function() return {} end
            assert(transport.send(http,prepared,function() return true end).state=='unknown')
        ''')

    def controller_fixture(self):
        self.lua.execute('''
            fake_now=1000
            os.time=function() return fake_now end
            timers={}
            package.preload['ui/uimanager']=function() return {
                scheduleIn=function(_,delay,fn) timers[#timers+1]={delay=delay,fn=fn} end,
                unschedule=function() end,
            } end
            package.preload['miuread.async']=function() return {new=function()
                return {busy=function(self) return self.running==true end,
                    cancel=function(self) self.running=false end,
                    run=function(self,_,fn,cb)
                        self.running=true
                        local ok,value=pcall(fn)
                        self.running=false
                        cb(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
                        return true
                    end}
            end} end
            auth={account={vid='a'},login_session_id='session',native_shelf={vid='a',
                deviceId='synthetic-device',accessToken='private-access',refreshToken='private-refresh'}}
            prefs={sync={time_enabled=true,time_diagnostics=true}}
            function store:auth() return auth end
            function store:preferences() return prefs end
            function store:read_persisted(key) if key=='auth' then return auth end end
            stat={id_curr_book=1,settings={min_sec=5,max_sec=120},curr_page=1,
                page_stat={[1]={{1000,0}}},isEnabledAndNotFrozen=function() return true end}
            Stats.persisted=function() return {} end
            online=false
            calls=0
            cloud={chapterUid=3,chapterOffset=77,readingTime=10}
            host={ui={statistics=stat},is_online=function() return online end}
            host.http={post_json=function(_,url,body)
                calls=calls+1
                if fail_http then error('synthetic transport failure private-access') end
                cloud.readingTime=cloud.readingTime+body.books[1].readingTime
                if change_position then cloud.chapterOffset=88 end
                return {succ=1}
            end}
            package.preload['miuread.eink_client']=function() return {new=function(http,s)
                return {store=s,http=http,request=function(self,_,path,_,stage)
                    if self.before_request then self.before_request(stage) end
                    if path=='/config' then
                        if no_config then return {} end
                        return {token='private-config'}
                    end
                    if path=='/feature' then
                        if no_guest then return {feature={}} end
                        if bad_guest then return {feature={guest_token={value='private-guest'}}} end
                        return {feature={guest_token='private-guest'}}
                    end
                    if path=='/book/getProgress' then return {book=cloud} end
                    error('unexpected endpoint')
                end}
            end} end
            Controller=require('miuread.readtime_controller')
            controller=Controller.new(store)
            sync={host=host,controller_token='fixture'}
            assert(controller:start(sync,{book={book_id='book'}}))
        ''')

    def test_live_reading_never_dispatches_eink_history_until_closed(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;online=true
            assert(controller:collect(false))
            assert(controller.active and controller:summary().pending==20)
            assert(not controller:send() and calls==0)
            controller:stop(sync,'close',false)
            assert(controller.active==nil and controller:summary().pending==20)
            assert(controller:send() and calls==1)
            assert(controller:summary().pending==0)
        ''')

    def test_controller_collects_offline_then_uploads_and_logs_safely(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020
            assert(controller:collect(false))
            assert(not controller:send() and calls==0)
            assert(controller:summary().pending==20)
            online=true
            -- The live reader owns the clock; it may queue but never POST.
            assert(not controller:send() and calls==0)
            controller:stop(sync,'close',false)
            assert(controller.active==nil)
            assert(controller:send() and calls==1)
            assert(cloud.readingTime==30 and cloud.chapterOffset==77)
            assert(controller:summary().pending==0)
            assert(not controller:send() and calls==1)
            assert(controller.active==nil)
        ''')
        log = (self.root / "miuread.log").read_text(encoding="utf-8")
        self.assertIn("phase=position_after", log)
        self.assertIn("position_unchanged=true", log)
        self.assertIn("cloud_delta=20", log)
        self.assertNotIn("private-", log)

    def test_controller_missing_feature_uses_client_default(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;no_guest=true
            controller:send()
            assert(calls==1 and controller:summary().pending==0)
            assert(cloud.readingTime==30)
        ''')
        log = (self.root / "miuread.log").read_text(encoding="utf-8")
        self.assertIn("token_source=client_default", log)
        self.assertIn("feature_token_present=false", log)
        self.assertIn("config_token_present=true", log)
        self.assertNotIn("build_id=", log)
        self.assertNotIn("private-", log)
        self.assertNotIn("5ecdcfd7f", log)

    def test_controller_invalid_feature_keeps_pending_before_post(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;bad_guest=true
            controller:send()
            assert(calls==0 and controller:summary().pending==20)
        ''')
        log = (self.root / "miuread.log").read_text(encoding="utf-8")
        self.assertIn("reason=signature_token_invalid", log)
        self.assertIn("native_stage=reading_time_signature", log)
        self.assertNotIn("private-", log)

    def test_controller_missing_config_keeps_pending_before_post(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;no_config=true;no_guest=true
            controller:send()
            assert(calls==0 and controller:summary().pending==20)
        ''')

    def test_existing_218_second_queue_can_drain_without_more_reading(self):
        self.controller_fixture()
        self.lua.execute('''
            local spans,at={},1000
            for page,duration in ipairs({7,7,15,15,15,15,30,15,15,15,15,30,12,12}) do
                spans[#spans+1]={page=page,start_time=at,duration=duration}
                at=at+duration
            end
            fake_now=at
            queue:collect('a',controller.active.window.id,spans,at,true)
            controller:stop(sync,'close',false)
            assert(queue:summary('a').pending==218)
            assert(#queue:pending('a',at).rows==14)
        ''')
        # A fresh connection sees the existing v1 ledger unchanged by r2.
        other = runtime(self.root)
        self.assertEqual(other.eval("queue:summary('a').pending"), 218)
        self.lua.execute('''
            online=true;no_guest=true
            assert(controller:send())
            assert(calls==1 and queue:summary('a').pending==0)
            assert(cloud.readingTime==228)
            fake_now=fake_now+120
            assert(not controller:send() and calls==1)
        ''')

    def test_controller_stops_after_position_change_and_unknown_is_not_replayed(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;change_position=true
            controller:send()
            assert(controller:summary().blocked=='cloud_position_changed')
            fake_now=1040;controller:collect(false)
            assert(not controller:send() and calls==1)
            assert(controller:summary().blocked=='cloud_position_changed')
        ''')
        self.assertIn("position_unchanged=false", (self.root / "miuread.log").read_text())

    def test_controller_transport_failure_is_durable_unknown(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;fail_http=true
            controller:send()
            assert(controller:summary().unknown==20)
            fake_now=1090;fail_http=false
            assert(not controller:send() and calls==1)
        ''')
        other = runtime(self.root)
        self.assertEqual(other.eval("queue:summary('a').unknown"), 20)
        log = (self.root / "miuread.log").read_text()
        self.assertNotIn("private-access", log)

    def test_controller_progress_fence_and_disabled_statistics(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:collect(false);online=true
            local granted
            controller:yield_to_progress(sync,function(ok) granted=ok end)
            assert(granted==true and not controller:send() and calls==0)
            controller:release_progress(sync)
            assert(not controller:send() and calls==0) -- still reading
            controller:stop(sync,'close',false)
            assert(controller:send() and calls==1)
            controller:stop(sync,'suspend',true)
            stat.isEnabledAndNotFrozen=function() return false end
            assert(not controller:start(sync,{book={book_id='book'}}))
        ''')

    def test_controller_disabling_stops_capture_and_background_timer(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:collect(false)
            prefs.sync.time_enabled=false
            controller:stop(sync,'disabled',false)
            assert(controller.active==nil and controller.task==nil and controller.suspended)
            online=true
            assert(not controller:send() and calls==0)
            assert(controller:summary().pending==20)
        ''')

    def test_sync_lifecycle_uses_one_timer_and_saves_tail_on_close(self):
        self.controller_fixture()
        self.lua.execute('''
            controller:stop(sync,'fixture_reset',true)
            for _,name in ipairs({'ui/event','ffi/util','miuread.read_report_service',
                'miuread.legacy_adapter_worker','miuread.book_integrity','miuread.precise_position',
                'miuread.source_position','miuread.subprocess_hygiene'}) do
                package.preload[name]=function() return {} end
            end
            local Sync=require('miuread.sync')
            local s=setmetatable({store=store,host=host,controller_token='real-sync',
                async={cancel=function() end},record_generation=1,session_started_at=1000,
                record=function() return {book={book_id='book'}} end,
                _read_report_allowed=function() return true end,
                periodic_progress_enabled=function() error('legacy verification reached') end,
                _start_daemon=function() error('legacy clock started') end,
                _stop_daemon_fast=function() return nil end,
            },Sync)
            fake_now=1000
            assert(s:start('test'))
            assert(s.offline_time==controller)
            fake_now=1012
            s:stop_fast('close')
            assert(controller.active==nil and controller:summary().pending==12)
            local first,second
            s:begin_progress_write('one',function(ok) first=ok end)
            assert(first==true and controller.progress_owner==s)
            s:begin_progress_write('two',function(ok) second=ok end)
            assert(second==false and controller.progress_owner==s)
            s:end_progress_write('complete')
            assert(controller.progress_owner==nil)
        ''')

    def test_v1_upgrade_preserves_pending_unknown_and_cooldown(self):
        self.lua.execute('''
            begin('v1',100)
            queue:collect('a','v1',{{page=1,start_time=100,duration=90}},190,true)
            local batch=queue:pending('a',190)
            queue:claim('a',batch,'interrupted')
        ''')
        with closing(sqlite3.connect(self.root / "readtime-outbox.sqlite3")) as conn:
            raw = json.loads(conn.execute("SELECT value FROM kv WHERE key='account:a'").fetchone()[0])
            raw["version"] = 1
            raw.pop("control", None)
            conn.execute("UPDATE kv SET value=? WHERE key='account:a'", (json.dumps(raw),))
            conn.commit()
        other = runtime(self.root)
        other.execute('''
            queue:recover('a')
            assert(queue:summary('a').unknown==90)
            assert(#queue:pending('a',99999).rows==0)
            queue:defer('a',200,'rate_limited',7200,'pending')
        ''')
        again = runtime(self.root)
        self.assertEqual(again.eval("queue:summary('a').control.next_send"), 7400)
        self.assertEqual(again.eval("queue:summary('a').control.reason"), "rate_limited")

    def test_unknown_details_ignore_and_completed_metadata_pruning(self):
        self.lua.execute('''
            begin('w',100)
            queue:collect('a','w',{{page=1,start_time=100,duration=90}},190,true)
            local batch=queue:pending('a',190)
            queue:claim('a',batch,'attempt')
            queue:finish('a',batch,'attempt','unknown',190,'interrupted')
            local groups=queue:unknown('a')
            assert(#groups==1 and groups[1].seconds==90 and #groups[1].ids==2)
            assert(groups[1].start_time==100 and groups[1].end_time==190)
            assert(queue:ignore('b',groups[1])==0)
            assert(queue:ignore('a',groups[1])==90)
            assert(queue:ignore('a',groups[1])==0)
            assert(queue:summary('a').rows==0)
        ''')
        with closing(sqlite3.connect(self.root / "readtime-outbox.sqlite3")) as conn:
            value = json.loads(conn.execute("SELECT value FROM kv WHERE key='account:a'").fetchone()[0])
        self.assertFalse(value["windows"])
        self.assertFalse(value["seen"])
        self.assertFalse(value["aliases"])

    def test_queue_capacity_rolls_back_capture_without_losing_watermark(self):
        # Lower only the capacity constant, using the unchanged ledger code.
        source = (ROOT / "miuread.koplugin/miuread/readtime_outbox.lua").read_text(encoding="utf-8")
        self.lua.globals().limited_source = source.replace("local MAX_ROWS=50000", "local MAX_ROWS=2")
        self.lua.execute('''
            local Limited=assert(loadstring(limited_source))()
            queue=Limited.new(store)
            begin('w',100)
            local result,err=queue:collect('a','w',{{page=1,start_time=100,duration=180}},280)
            assert(result==nil and err=='ledger_full')
            assert(queue:summary('a').pending==0)
            assert(queue:collect('a','w',{{page=1,start_time=100,duration=120}},220).seconds==120)
            local batch=queue:pending('a',280)
            queue:claim('a',batch,'one');queue:finish('a',batch,'one','confirmed',280)
            assert(queue:collect('a','w',{{page=1,start_time=100,duration=180}},280).seconds==60)
        ''')

    def test_controller_default_log_is_concise_and_diagnostic_is_optional(self):
        self.controller_fixture()
        self.lua.execute('''
            prefs.sync.time_diagnostics=false
            fake_now=1020;controller:stop(sync,'close',false);online=true;controller:send()
        ''')
        log = (self.root / "miuread.log").read_text(encoding="utf-8")
        self.assertIn("phase=complete", log)
        self.assertNotIn("phase=position_after", log)
        self.assertNotIn("phase=signature_parameters", log)
        self.assertNotIn("private-", log)

    def test_controller_retry_is_persisted_and_manual_wake_obeys_it(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;no_config=true
            controller:send()
            assert(controller:summary().control.next_send==1080)
            controller:wake(host);no_config=false
            fake_now=1079;assert(not controller:send() and calls==0)
            fake_now=1080;assert(controller:send() and calls==1)
        ''')
        other = runtime(self.root)
        # Once the book is closed, there is no active 60-second reading interval.
        # The confirmed retry persists its normal 10-second idle cooldown.
        self.assertEqual(other.eval("queue:summary('a').control.next_send"), 1090)

    def test_position_pause_can_be_checked_and_resumed_without_replay(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;change_position=true
            controller:send()
            assert(controller:summary().blocked=='cloud_position_changed')
            -- A subsequent session contributes new seconds, with the first
            -- confirmed batch preserved even while cloud position is blocked.
            change_position=false
            assert(controller:start(sync,{book={book_id='book'}}))
            fake_now=1040;controller:stop(sync,'close',false)
            local resumed
            controller:check_and_resume(host,function(ok) resumed=ok end)
            assert(resumed and not controller:summary().blocked)
            fake_now=1080
            assert(controller:send() and calls==2 and cloud.readingTime==50)
        ''')

    def test_failed_resume_keeps_pause_and_account_switch_cannot_ignore(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;fail_http=true
            controller:send()
            local group=controller:unknown()[1]
            auth.account.vid='b';auth.native_shelf.vid='b'
            assert(controller:ignore(group)==nil)
            assert(queue:summary('a').unknown==20 and queue:summary('b').unknown==0)
            auth.account.vid='a';auth.native_shelf.vid='a'
            queue:block('a','cloud_position_changed','book');controller.summary_cache=nil
            online=false
            local resumed
            controller:check_and_resume(host,function(ok) resumed=ok end)
            assert(resumed==false and controller:summary().blocked=='cloud_position_changed')
        ''')

    def test_account_switch_during_preflight_never_dispatches(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true
            local client=require('miuread.eink_client')
            local original=client.new
            client.new=function(...)
                local native=original(...)
                local request=native.request
                native.request=function(self,method,path,...)
                    local result=request(self,method,path,...)
                    if path=='/book/getProgress' then auth.account.vid='b';auth.native_shelf.vid='b' end
                    return result
                end
                return native
            end
            controller:send()
            assert(calls==0 and queue:summary('a').pending==20)
            assert(queue:summary('b').pending==0)
        ''')

    def test_statistics_disabled_mid_session_stops_estimates(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:collect(false)
            stat.isEnabledAndNotFrozen=function() return false end
            fake_now=1120;controller:collect(false)
            assert(controller.active==nil and controller:summary().pending==20)
            assert(controller:summary().capture_error=='statistics_unavailable')
        ''')

    def test_master_switch_off_preserves_existing_queue(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:collect(false)
            prefs.sync.time_enabled=false
            prefs.sync.offline_time_enabled=true -- stale experimental preference
            controller:stop(sync,'disabled',false)
            assert(not controller:enabled() and queue:summary('a').pending==20)
        ''')

    def test_empty_home_queue_parks_timer(self):
        self.controller_fixture()
        self.lua.execute('''
            controller:stop(sync,'close',false);online=true
            local task=controller.task
            assert(task);task()
            assert(controller.task==nil and calls==0)
        ''')

    def sync_fixture(self):
        self.controller_fixture()
        self.lua.execute("""
            controller:stop(sync,'fixture_reset',true)
            for _,name in ipairs({'ui/event','ffi/util','miuread.read_report_service',
                'miuread.legacy_adapter_worker','miuread.book_integrity','miuread.precise_position',
                'miuread.source_position','miuread.subprocess_hygiene'}) do
                package.preload[name]=function() return {} end
            end
            local Sync=require('miuread.sync')
            local record={book={book_id='book'},path='fixture.epub'}
            daemon_starts=0
            s=setmetatable({store=store,host=host,controller_token='real-sync',
                async={cancel=function() end},record_generation=1,session_started_at=1000,
                current=record,record=function() return record end,
                _read_report_allowed=function() return true end,
                _import_daemon_status=function() end,
                _start_daemon=function(self)
                    daemon_starts=daemon_starts+1;self.daemon={active=true};return true
                end,
                _stop_daemon_fast=function() return nil end,
            },Sync)
            host.sync=s
        """)

    def test_web_session_uses_upstream_daemon_without_statistics_capture(self):
        self.sync_fixture()
        self.lua.execute("""
            prefs.api_transport='web'
            stat.isEnabledAndNotFrozen=function() return false end
            assert(s:start('open') and s.reading_time_backend=='web' and daemon_starts==1)
            fake_now=1060;controller:collect(false)
            assert(controller.active==nil and queue:summary('a').pending==0)
        """)

    def test_missing_native_auth_keeps_upstream_web_path(self):
        self.sync_fixture()
        self.lua.execute("""
            auth.native_shelf=nil
            assert(s:start('open') and s.reading_time_backend=='web' and daemon_starts==1)
            assert(controller.active==nil)
        """)

    def test_native_session_does_not_start_the_web_daemon(self):
        self.sync_fixture()
        self.lua.execute("""
            assert(s:start('open') and s.reading_time_backend=='eink' and daemon_starts==0)
            fake_now=1020;s:stop_fast('close');online=true
            assert(s.state=='stopped' and s.current~=nil and controller.active==nil)
            assert(queue:summary('a').pending==20 and controller:send() and calls==1)
            assert(cloud.readingTime==30 and cloud.chapterOffset==77)
        """)

    def test_native_clock_owner_survives_preference_and_auth_changes(self):
        self.sync_fixture()
        self.lua.execute("""
            assert(s:start('open'))
            local window=controller.active.window.id
            fake_now=1020;controller:collect(false)
            prefs.api_transport='web';auth.native_shelf=nil
            assert(s:start('auth_refresh') and s.reading_time_backend=='eink')
            assert(controller.active.window.id==window and daemon_starts==0)
            online=true;assert(not controller:send())
            assert(queue:summary('a').pending==20 and calls==0)
        """)

    def test_web_clock_owner_is_not_replaced_after_native_authorization(self):
        self.sync_fixture()
        self.lua.execute("""
            prefs.api_transport='web';assert(s:start('open'))
            prefs.api_transport='auto';fake_now=1020
            assert(s:start('auth_refresh') and s.reading_time_backend=='web')
            assert(daemon_starts==2 and controller.active==nil and queue:summary('a').pending==0)
        """)

    def test_duplicate_native_ready_preserves_the_clock_owner(self):
        self.sync_fixture()
        self.lua.execute("""
            assert(s:start('open'))
            local window=controller.active.window.id
            prefs.api_transport='web';fake_now=1020
            s:on_reader_ready()
            assert(s.reading_time_backend=='eink' and controller.active.window.id==window)
            assert(daemon_starts==0 and s.record_generation==1)
        """)

    def test_native_outbox_never_falls_back_to_web(self):
        self.controller_fixture()
        self.lua.execute("""
            package.preload['miuread.legacy_adapter_worker']=function() error('unexpected Web fallback') end
            fake_now=1020;controller:stop(sync,'close',false);online=true
            prefs.api_transport='web'
            assert(not controller:send() and queue:summary('a').pending==20 and calls==0)
            prefs.api_transport='auto'
            assert(controller:send() and calls==1 and queue:summary('a').pending==0)
        """)

    def test_pending_native_history_waits_for_web_session_and_final_flush(self):
        self.controller_fixture()
        self.lua.execute("""
            fake_now=1020;controller:stop(sync,'close',false);online=true
            host.sync={reading_time_backend='web',current={book={book_id='other'}}}
            assert(not controller:send() and calls==0)
            host.sync.current=nil;host.sync.daemon={active=false,final_flush_pending=true}
            assert(not controller:send() and calls==0)
            host.sync.daemon.final_flush_pending=false
            assert(controller:send() and calls==1 and queue:summary('a').pending==0)
        """)

    def test_duplicate_close_keeps_native_tail_without_recounting(self):
        self.controller_fixture()
        self.lua.execute("""
            fake_now=1020;controller:stop(sync,'reading_end',false)
            controller:stop(sync,'document_closed',false)
            assert(queue:summary('a').pending==20)
            online=true;assert(controller:send() and calls==1)
            controller:stop(sync,'duplicate_close',false)
            assert(not controller:send() and calls==1 and queue:summary('a').confirmed_seconds==20)
        """)

    def test_upstream_legacy_debt_policy_does_not_replay_into_native_outbox(self):
        self.sync_fixture()
        self.lua.execute("""
            local legacy={pending_report_safe=true,pending_report_seconds=90}
            function store:session() return legacy end
            function s:upload() error('historical Web debt must not replay') end
            local finished,kind
            s:retry_safe_reading_time('book',{book={book_id='book'}},
                {safe=true,chapter_uid='3',progress=0},function(ok,_,why) finished,kind=ok,why end)
            assert(finished and kind=='best_effort_disabled')
            assert(legacy.pending_report_seconds==90 and queue:summary('a').pending==0)
        """)

    def test_cross_day_upload_retains_source_time_zones(self):
        self.lua.execute('''
            begin('day',86390)
            queue:collect('a','day',{{page=1,start_time=86390,duration=30}},86420,true)
            local batch=queue:pending('a',100000)
            local body=Protocol.batch({vid='a',deviceId='device'},'book',batch.rows,'guest','config',100000,1)
            assert(body.books[1].hours[1].startOfHour==82800)
            assert(body.books[1].hours[1].readingTime==10)
            assert(body.books[1].hours[2].startOfHour==86400)
            assert(body.books[1].hours[2].readingTime==20)
            assert(body.books[1].hours[1].timeZone=='+08:00')
        ''')

    def test_preferences_migration_preserves_disabled_and_enabled_users(self):
        source = (ROOT / "miuread.koplugin/miuread/store.lua").read_text(encoding="utf-8")
        migration = source.split('    if o.db:readSetting("readtime_outbox_v2")~=true then', 1)[1]
        migration = 'if o.db:readSetting("readtime_outbox_v2")~=true then' + migration.split('    -- Do not rewrite miuread.lua', 1)[0]
        self.lua.globals().migration = migration
        self.lua.execute('''
            for _,enabled in ipairs({false,true}) do
                local values={preferences={sync={time_enabled=enabled,offline_time_enabled=true}}}
                local writes=0
                local o={db={
                    readSetting=function(_,key,default) if values[key]==nil then return default end;return values[key] end,
                    saveSetting=function(_,key,value) values[key]=value;writes=writes+1 end,
                }}
                local fn=assert(loadstring('return function(o) local startup_dirty=false; '..migration..';return startup_dirty end'))()
                assert(fn(o) and values.preferences.sync.time_enabled==enabled)
                assert(values.preferences.sync.offline_time_enabled==nil)
                assert(writes==2 and not fn(o) and writes==2)
            end
        ''')

    def test_clock_correction_seals_old_window_and_can_start_again(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:collect(false)
            local old=controller.active.window.id
            fake_now=990
            assert(not controller:collect(false) and controller.active.window.id~=old)
            assert(controller:summary().pending==20)
            assert(controller.active.window.capture_not_before==1020)
            fake_now=1010;controller:collect(false)
            assert(controller:summary().pending==20)
            fake_now=1030
            assert(controller:start(sync,{book={book_id='book'}}))
            fake_now=1040;controller:collect(false)
            assert(controller:summary().pending==40)
        ''')

    def test_progress_lock_rejects_overlapping_owner_and_releases_cleanly(self):
        self.controller_fixture()
        self.lua.execute('''
            local first,second
            assert(controller:yield_to_progress(sync,function(ok) first=ok end))
            assert(first==true)
            assert(not controller:yield_to_progress(sync,function(ok) second=ok end))
            assert(second==false and controller.progress_owner==sync)
            controller:release_progress(sync)
            assert(controller.progress_owner==nil)
            assert(controller:yield_to_progress({},function(ok) assert(ok) end))
        ''')

    def test_rate_limit_cooldown_survives_restart(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true;bad_guest=true
            require('miuread.http').rate_limit_details=function() return {wait_seconds=7200,code=429} end
            controller:send()
            assert(calls==0 and controller:summary().pending==20)
            assert(controller:summary().control.reason=='rate_limited')
            assert(controller:summary().control.next_send==8220)
        ''')
        self.lua = runtime(self.root)
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false)
            online=true;fake_now=8219
            assert(not controller:send() and calls==0)
            fake_now=8220
            assert(controller:send() and calls==1 and queue:summary('a').pending==0)
        ''')

    def test_explicit_receipt_commits_before_optional_position_readback(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:stop(sync,'close',false);online=true
            local client=require('miuread.eink_client')
            local original=client.new
            client.new=function(...)
                local native=original(...)
                local request=native.request
                native.request=function(self,method,path,params,stage)
                    if stage=='reading_time_position_after' then
                        local summary=queue:summary('a')
                        assert(summary.pending==0 and summary.in_flight==0 and summary.confirmed_seconds==20)
                        error('readback unavailable')
                    end
                    return request(self,method,path,params,stage)
                end
                return native
            end
            assert(controller:send() and calls==1)
            assert(controller:summary().pending==0 and controller:summary().unknown==0)
        ''')

    def test_unavailable_worker_parks_home_until_explicit_wake(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1020;controller:collect(false);controller:stop(sync,'close',false);online=true
            local run=controller.worker.run
            controller.worker.run=function() return false end
            controller.task()
            assert(controller.task==nil and controller.worker_unavailable and calls==0)
            assert(controller:summary().pending==20 and controller:summary().control.reason=='worker_unavailable')
            controller.worker.run=run;controller:wake(host)
            assert(not controller.worker_unavailable and controller.task)
            fake_now=1080
            assert(controller:send() and calls==1)
        ''')

    def test_window_ids_remain_unique_after_pruning_and_restart(self):
        self.lua.execute('''
            local window={id='same-seed',book_id='book',start_time=100,time_zone='+08:00'}
            local first=queue:begin('a',window,true)
            queue:collect('a',first.id,{},100,true)
            first_id=first.id
        ''')
        other = runtime(self.root)
        other.execute('''
            second=queue:begin('a',{id='same-seed',book_id='book',start_time=100,time_zone='+08:00'},true)
        ''')
        self.assertNotEqual(other.eval("second.id"), self.lua.eval("first_id"))

    def test_cancelled_progress_wait_cannot_claim_a_newer_ticket(self):
        self.controller_fixture()
        self.lua.execute('''
            controller.worker.running=true
            local first,second
            controller:yield_to_progress(sync,function(ok) first=ok end)
            local old_poll=timers[#timers].fn
            controller:release_progress(sync)
            controller:yield_to_progress(sync,function(ok) second=ok end)
            local new_poll=timers[#timers].fn
            controller.worker.running=false
            old_poll()
            assert(first==false and second==nil and controller.progress_owner==sync)
            new_poll()
            assert(second==true and controller.progress_owner==sync)
        ''')

    def test_native_clock_threshold_backward_forward_and_reboot(self):
        self.lua.execute('''
            local Clock=require('miuread.readtime_clock')
            local function sample(wall,elapsed,boot)
                return {wall=wall,elapsed=elapsed,kind='boottime',boot_id=boot or 'boot',zone='+08:00'}
            end
            local baseline=Clock.observe(nil,sample(100000,100))
            local _,near=Clock.observe(baseline,sample(100011,120))
            assert(near.risk==0 and not near.discontinuity)
            local backwards,event=Clock.observe(baseline,sample(100010,120))
            assert(event.risk==1 and event.discontinuity and event.capture_floor==100010)
            local _,forward=Clock.observe(baseline,sample(100030,120))
            assert(forward.risk==0 and forward.discontinuity)
            local _,reboot=Clock.observe(baseline,sample(100100,5,'new-boot'))
            assert(reboot.risk==0 and not reboot.discontinuity)
            local _,reboot_back=Clock.observe(baseline,sample(99900,5,'new-boot'))
            assert(reboot_back.risk==1 and reboot_back.discontinuity)
            local _,restored=Clock.observe(backwards,sample(100040,140))
            assert(restored.risk==0)
        ''')

    def test_native_zone_repeat_boundary_and_72_hour_recovery(self):
        self.lua.execute('''
            local Clock=require('miuread.readtime_clock')
            local function at(previous,wall,zone)
                return Clock.observe(previous,{wall=wall,zone=zone})
            end
            local first,event=at(nil,100000,'+08:00')
            assert(event.risk==0 and not event.zone_changed)
            local moved,one=at(first,101000,'+09:00')
            assert(one.zone_changed and one.risk==0)
            local repeated,two=at(moved,104599,'+08:00')
            assert(two.risk==4)
            local _,exact=at(moved,104600,'+08:00')
            assert(exact.risk==0)
            local _,still=at(repeated,104599+259199,'+08:00')
            local _,trusted=at(repeated,104599+259200,'+08:00')
            assert(still.risk==4 and trusted.risk==0)
        ''')

    def test_native_server_clock_default_limit_and_disable(self):
        self.lua.execute('''
            local Clock=require('miuread.readtime_clock')
            local state=Clock.observe(nil,{wall=100000,elapsed=100,kind='boottime',zone='+08:00'})
            local equal,large=Clock.server(state,99400,nil,100000)
            assert(not large)
            local skew,different=Clock.server(state,99399,nil,100000)
            assert(different)
            local _,next=Clock.observe(skew,{wall=100010,elapsed=110,kind='boottime',zone='+08:00'})
            assert(next.risk==1)
            local disabled,diff=Clock.server(skew,99000,0,100000)
            assert(not diff and not disabled.time_changed)
            assert(Clock.server(state,nil,600,100000)==nil)
            assert(Clock.server(state,0,600,100000)==nil)
        ''')

    def test_clock_sample_prefers_suspend_inclusive_boottime(self):
        self.lua.execute('''
            package.loaded['miuread.readtime_clock']=nil
            local boot=function() return 123456000000 end
            package.preload['ui/time']=function() return {
                boottime=boot,boottime_or_monotonic=boot,
                monotonic=function() error('must use sleep-inclusive clock') end,
                to_s=function(fts) return fts/1000000 end,
            } end
            local sample=require('miuread.readtime_clock').sample()
            assert(sample.elapsed==123456 and sample.kind=='boottime' and sample.zone=='+08:00')
        ''')

    def test_version_resolver_uses_file_binding_and_embedded_fallback(self):
        self.lua.execute('''
            local Metadata=require('miuread.readtime_metadata')
            local record={path='/books/current.epub',book={book_id='book',version=999},
                record={book_id='book',file='/books/current.epub',progress_source_book_version='42'}}
            local version,source=Metadata.resolve(store,record)
            assert(version==42 and source=='file_record')
            record.book.version=1001
            assert(Metadata.resolve(store,record)==42)
            record.record.progress_source_book_version=0
            function store:epub_identity(path)
                assert(path=='/books/current.epub')
                return {book_id='book',progress_source_book_version=41}
            end
            version,source=Metadata.resolve(store,record)
            assert(version==41 and source=='epub_identity')
            record.record.file='/books/other.epub'
            assert(Metadata.resolve(store,record)==0)
            record.record.file=record.path;record.record.book_id='other'
            assert(Metadata.resolve(store,record)==0)
            record.record.book_id='book'
            function store:epub_identity() return {book_id='other',progress_source_book_version=55} end
            assert(Metadata.resolve(store,record)==0)
            function store:epub_identity() return {book_id='book',version=888} end
            assert(Metadata.resolve(store,record)==0)
            record.record.progress_source_book_version=1.5
            assert(Metadata.resolve(store,record)==0)
        ''')

    def test_risk_and_version_survive_restart_and_participate_in_signature(self):
        self.lua.execute('''
            assert(queue:begin('a',{id='one',book_id='book',start_time=1000,time_zone='+08:00',
                book_version=42,book_version_source='file_record',risk=1}))
            assert(queue:collect('a','one',{{page=1,start_time=1000,duration=10}},1010,true))
            assert(queue:begin('a',{id='two',book_id='book',start_time=1010,time_zone='+08:00',
                book_version=42,book_version_source='epub_identity',risk=4}))
            assert(queue:collect('a','two',{{page=2,start_time=1010,duration=10}},1020,true))
            local recovered=Outbox.new(store)
            assert(recovered:recover('a'))
            local batch=recovered:pending('a',2000)
            local sign=Protocol.sign;local parts
            Protocol.sign=function(value) parts=value; return sign(value) end
            local body=Protocol.batch({vid='123',deviceId='d'},'book',batch.rows,'guest','config',2000,1).books[1]
            Protocol.sign=sign
            assert(body.bookVersion==42 and body.risk==5 and body.readingTime==20)
            assert(parts[4]:find('123_d__book_5_+08:00_20_0_',1,true)==1)
            assert(recovered:claim('a',batch,'attempt'))
            recovered:finish('a',batch,'attempt','unknown',2000,'timeout')
            local rows=recovered:unknown('a')
            assert(rows[1].seconds==20 and #recovered:pending('a',9999).rows==0)
        ''')

    def test_versions_are_not_mixed_in_a_batch(self):
        self.lua.execute('''
            for i,version in ipairs({42,43}) do
                local start=1000+i*10
                queue:begin('a',{id=tostring(i),book_id='book',start_time=start,time_zone='+08:00',book_version=version})
                queue:collect('a',tostring(i),{{page=i,start_time=start,duration=10}},start+10,true)
            end
            local first=queue:pending('a',2000)
            assert(first.book_version==42 and first.seconds==10)
            assert(not pcall(Protocol.book,{vid='123',deviceId='d'},'book',{
                {start_time=1000,duration=10,time_zone='+08:00',book_version=42},
                {start_time=1010,duration=10,time_zone='+08:00',book_version=43}},'guest',2000,1))
            assert(queue:claim('a',first,'a'))
            queue:finish('a',first,'a','confirmed',2000)
            local second=queue:pending('a',2000)
            assert(second.book_version==43 and second.seconds==10)
        ''')

    def test_claim_refuses_metadata_changed_after_preflight(self):
        self.lua.execute('''
            queue:observe('a',{wall=100000,elapsed=100,kind='boottime',zone='+08:00'})
            queue:begin('a',{id='w',book_id='book',start_time=100000,time_zone='+08:00',book_version=42})
            queue:collect('a','w',{{page=1,start_time=100000,duration=10}},100010)
            local stale=queue:pending('a',100010)
            local observed=queue:observe('a',{wall=100020,elapsed=150,kind='boottime',zone='+08:00'},'w')
            assert(observed.risk==1)
            assert(not queue:claim('a',stale,'stale'))
            local current=queue:pending('a',100100)
            assert(current.rows[1].risk==1 and queue:claim('a',current,'fresh'))
            queue:observe('a',{wall=100021,elapsed=160,kind='boottime',zone='+09:00'},'w')
            assert(queue:_access('a',function(data) return data.items[current.rows[1].id].risk,false end,true)==1)
        ''')

    def test_legacy_rows_keep_unknown_metadata_instead_of_latest_version(self):
        self.lua.execute('''
            begin('legacy',1000)
            queue:collect('a','legacy',{{page=1,start_time=1000,duration=10}},1010,true)
            queue:observe('a',{wall=2000,elapsed=100,kind='boottime',zone='+08:00'})
            queue:observe('a',{wall=1900,elapsed=110,kind='boottime',zone='+08:00'},'legacy')
            local legacy=queue:pending('a',3000)
            assert(legacy.rows[1].book_version==nil and legacy.rows[1].book_version_source==nil)
            local body=Protocol.book({vid='123',deviceId='d'},'book',legacy.rows,'g',3000,1)
            assert(body.bookVersion==0 and body.risk==0)
            assert(queue:_access('a',function(data) return data.version,false end,true)==3)
        ''')

    def test_controller_freezes_file_version_at_capture_not_send(self):
        self.controller_fixture()
        self.lua.execute('''
            controller:stop(sync,'close')
            local record={path='/books/current.epub',book={book_id='book',version=999},
                record={book_id='book',file='/books/current.epub',progress_source_book_version=42}}
            assert(controller:start(sync,record))
            fake_now=1030;assert(controller:collect(false))
            record.book.version=1001;record.record.progress_source_book_version=43
            fake_now=1060;assert(controller:collect(true))
            local batch=controller.queue:pending('a',fake_now)
            assert(batch.book_version==42 and batch.seconds==60)
            local post=host.http.post_json
            host.http.post_json=function(self,url,body,options)
                assert(body.books[1].bookVersion==42)
                return post(self,url,body,options)
            end
            online=true;assert(controller:send())
        ''')
        log = (self.root / "miuread.log").read_text(encoding="utf-8")
        self.assertIn("book_version=42", log)
        self.assertIn("book_version_source=file_record", log)
        self.assertNotIn("/books/current.epub", log)

    def controller_clock_fixture(self):
        self.controller_fixture()
        self.lua.execute('''
            Clock=require('miuread.readtime_clock')
            fake_elapsed=100;fake_zone='+08:00'
            Clock.sample=function() return {wall=fake_now,elapsed=fake_elapsed,kind='boottime',zone=fake_zone,boot_id='boot'} end
            controller.queue:observe('a',Clock.sample())
        ''')

    def test_controller_clock_jump_marks_risk_without_creating_seconds(self):
        self.controller_clock_fixture()
        self.lua.execute('''
            fake_now=1030;fake_elapsed=130;assert(controller:collect(false))
            fake_now=900;fake_elapsed=140
            assert(not controller:collect(false))
            assert(controller.active and controller:summary().pending==30)
            assert(controller.active.window.capture_not_before==1030)
            local batch=controller.queue:pending('a',2000)
            assert(batch.rows[1].risk==1)
            online=true;assert(not controller:send() and calls==0)
            fake_now=1010;fake_elapsed=250;controller:collect(false)
            assert(controller:summary().pending==30)
        ''')

    def test_controller_timezone_rotation_preserves_old_zones_and_sets_repeat_bit(self):
        self.controller_clock_fixture()
        self.lua.execute('''
            fake_now=1030;fake_elapsed=130;controller:collect(false)
            fake_now=1040;fake_elapsed=140;fake_zone='+09:00';controller:collect(false)
            assert(controller.active.window.time_zone=='+09:00' and controller.active.window.risk==0)
            fake_now=1070;fake_elapsed=170;controller:collect(false)
            fake_now=1080;fake_elapsed=180;fake_zone='+08:00';controller:collect(false)
            fake_now=1110;fake_elapsed=210;controller:collect(false)
            local batch=controller.queue:pending('a',fake_now)
            assert(batch.seconds==90)
            local old,new,flagged=0,0,0
            for _,row in ipairs(batch.rows) do
                if row.time_zone=='+09:00' then new=new+row.duration end
                if row.time_zone=='+08:00' then old=old+row.duration end
                if row.risk==4 then flagged=flagged+row.duration end
            end
            assert(old==60 and new==30 and flagged==60)
        ''')

    def test_clock_state_and_capture_floor_survive_restart(self):
        self.lua.execute('''
            queue:observe('a',{wall=100000,elapsed=100,kind='boottime',boot_id='boot',zone='+08:00'})
            queue:observe('a',{wall=99900,elapsed=110,kind='boottime',boot_id='boot',zone='+08:00'})
            local resumed=Outbox.new(store)
            local observed=resumed:observe('a',{wall=99920,elapsed=130,kind='boottime',boot_id='boot',zone='+08:00'})
            assert(observed.risk==1 and observed.capture_floor==100000)
        ''')

    def test_suspend_elapsed_time_does_not_set_a_clock_risk(self):
        self.controller_clock_fixture()
        self.lua.execute('''
            fake_now=1030;fake_elapsed=130;controller:collect(false)
            controller:stop(sync,'suspend',true)
            fake_now=4630;fake_elapsed=3730
            stat.page_stat={[1]={{fake_now,0}}}
            assert(controller:start(sync,{book={book_id='book'}}))
            assert(controller.active.window.risk==0)
            fake_now=4660;fake_elapsed=3760;controller:collect(false)
            local batch=controller.queue:pending('a',fake_now)
            assert(batch.seconds==60)
            for _,row in ipairs(batch.rows) do assert(row.risk==0) end
        ''')

    def test_server_timestamp_preflight_updates_subsequent_capture_risk(self):
        self.controller_clock_fixture()
        self.lua.execute('''
            local Native=require('miuread.eink_client')
            local new=Native.new
            Native.new=function(...)
                local client=new(...);local request=client.request
                client.request=function(self,method,path,...)
                    local result=request(self,method,path,...)
                    if path=='/book/getProgress' then result.timestamp=fake_now-601 end
                    return result
                end
                return client
            end
            fake_now=1030;fake_elapsed=130;controller:stop(sync,'close',false)
            online=true;assert(controller:send() and calls==1)
            assert(controller:start(sync,{book={book_id='book'}}))
            fake_now=1060;fake_elapsed=160;controller:collect(false)
            local batch=controller.queue:pending('a',fake_now)
            assert(batch.seconds==30 and batch.rows[1].risk==1)
            assert(controller.queue:server_clock('a',fake_now,600,fake_now))
            fake_now=1090;fake_elapsed=190;controller:collect(false)
            batch=controller.queue:pending('a',fake_now)
            assert(batch.seconds==60)
            for _,row in ipairs(batch.rows) do assert(row.risk==1) end -- already observed flags are immutable
        ''')

    def test_clock_metadata_write_failure_stops_preflight_before_post(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1030;controller:stop(sync,'close',false)
            controller.queue.server_clock=function() return nil,'ledger_failed' end
            online=true;controller:send()
            assert(calls==0 and controller:summary().pending==30)
        ''')

    def test_clock_rolls_back_during_preflight_never_posts_future_rows(self):
        self.controller_fixture()
        self.lua.execute('''
            fake_now=1030;controller:collect(true)
            local Native=require('miuread.eink_client');local new=Native.new
            Native.new=function(...)
                local client=new(...);local request=client.request
                client.request=function(self,method,path,...)
                    local result=request(self,method,path,...)
                    if path=='/book/getProgress' then fake_now=900 end
                    return result
                end
                return client
            end
            online=true;controller:send()
            assert(calls==0 and controller:summary().pending==30)
        ''')

    def test_failed_boundary_save_retries_without_counting_a_forward_jump(self):
        self.controller_clock_fixture()
        self.lua.execute('''
            fake_now=1030;fake_elapsed=130;controller:collect(false)
            local collect=controller.queue.collect;local fail=true
            controller.queue.collect=function(self,...)
                if fail then fail=false;return nil,'ledger_failed' end
                return collect(self,...)
            end
            fake_now=5000;fake_elapsed=140
            assert(not controller:collect(false))
            assert(controller.active.boundary_reason=='clock_changed')
            fake_now=5030;fake_elapsed=170
            assert(not controller:collect(false))
            assert(controller.active.window.start_time==5030 and controller:summary().pending==30)
        ''')

    def test_pending_install_version_is_not_used_for_the_open_epub(self):
        self.lua.execute('''
            local Metadata=require('miuread.readtime_metadata')
            local record={path='/books/current.epub',book={book_id='book',version=999},
                record={book_id='book',file='/books/current.epub',progress_source_book_version=43,
                    pending_install=true,pending_file='/books/new-pending.epub'}}
            assert(Metadata.resolve(store,record)==0)
            function store:epub_identity(path)
                assert(path=='/books/current.epub')
                return {book_id='book',progress_source_book_version=42}
            end
            local version,source=Metadata.resolve(store,record)
            assert(version==42 and source=='epub_identity')
        ''')


if __name__ == "__main__":
    unittest.main()
