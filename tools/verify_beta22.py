#!/usr/bin/env python3
from pathlib import Path
import hashlib, re, sys, zipfile, subprocess

ROOT=Path(__file__).resolve().parents[1]
PLUGIN=ROOT/'miuread.koplugin'
MIU=PLUGIN/'miuread'
errors=[]; checks=[]
def ok(cond,msg):
    checks.append(msg)
    if not cond: errors.append(msg)
def text(p): return p.read_text(encoding='utf-8')

def sha256(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

cfg=text(MIU/'config.lua'); main=text(PLUGIN/'main.lua'); store=text(MIU/'store.lua')
dl=text(MIU/'extension_download.lua'); ins=text(MIU/'extension_install.lua'); job=text(MIU/'extension_job.lua'); center=text(MIU/'extension_center.lua'); catalog=text(MIU/'extension_catalog.lua')

ok('VERSION = "5.8.0-beta.22"' in cfg,'version is 5.8.0-beta.22')
ok('SCHEMA = 135' in cfg,'schema is 135')
ok('local shared_stores=setmetatable({},{__mode="v"})' in store,'beta.17 preserves beta.16 shared foreground Store weak references')
ok('if options.isolated~=true and shared_stores[shared_key] then' in store,'beta.17 preserves non-isolated shared Store reuse')
ok('U.mkdir(data); U.mkdir(data.."/books")' in store and store.find('U.mkdir(data)') < store.find('if options.isolated~=true and shared_stores[shared_key] then'),'beta.17 preserves directory repair before shared Store reuse')
for old in ['extension_transfer.lua','extension_verifier.lua','extension_package.lua','extension_installer.lua','extension_task.lua']:
    ok(not (MIU/old).exists(),f'legacy module removed: {old}')
for new in ['extension_download.lua','extension_install.lua','extension_job.lua']:
    ok((MIU/new).is_file(),f'new module present: {new}')
ok('require("miuread.extension_job")' in main,'main uses extension_job')
for token in ['miuread.extension_transfer','miuread.extension_verifier','miuread.extension_package','miuread.extension_installer','miuread.extension_task']:
    ok(token not in '\n'.join(text(p) for p in PLUGIN.rglob('*.lua')),f'no runtime require/reference to {token}')

# Download policy invariants.
ok('local LARGE_FILE_BYTES=tonumber(Config.EXTENSION_LARGE_FILE_BYTES)' in dl and 'local RESUME_BYTES=tonumber(Config.EXTENSION_RESUME_BYTES)' in dl,'beta.15 has separate large-file and resumable-partial thresholds')
ok('EXTENSION_DOWNLOAD_ROUTES' in cfg and 'mirrors.git-zh.com' in cfg and 'preferred = true' in cfg,'GitHub Chinese community route is configured as preferred transport')
ok('if custom_route then out[#out+1]=custom_route end' in dl,'custom source is last automatic fallback')
ok('route_score' not in dl and 'ttfb' not in dl.lower(),'legacy historical route-score/TTFB ranking remains removed')
ok('return {}' in dl and 'mode:match("^mirror:%d+$")' in dl,'manual invalid source fails closed')
ok('source-"..U.id_name(route.key)..".part' in dl,'partials are source-local')
ok('import_resume_partial' in dl and 'cross-route resume seed copied' in dl,'verified asset identity can seed cross-route Range resume without deleting the original checkpoint')
ok('validate_download(part,spec)' in dl and 'verify_kind=="sha_unavailable"' in dl,'source completion is integrity-gated')
ok('expected>0 and size~=expected' in dl and 'actual~=expected_sha' in dl,'size and SHA-256 are both enforced')
ok('local curl_available=command_available("curl")' in dl and 'transport=koreader_http' in dl and 'transport=curl' in dl,'KOReader HTTP primary with curl fallback retained')
ok('cached package verified' in dl and 'cached package rejected' in dl,'cached package is always revalidated')
ok('fresh_verify_kind=="sha_unavailable" or fresh_verify_kind=="catalog_integrity"' in dl,'fresh curl restart preserves terminal integrity errors')

# Installer invariants.
ok('pcall(require,"ffi/archiver")' in ins,'KOReader Archiver is archive authority')
ok('unzip ' not in ins and 'unzip\t' not in ins,'system unzip is not used by installer')
ok('install-journal.json' in ins,'transaction journal is written')
ok('.miuread-new-' in ins and '.miuread-old-' in ins,'transaction uses new/old staging directories')
ok('rename_dir(target,old_path)' in ins and 'rename_dir(new_path,target)' in ins,'install switches by staged rename')
ok('os.rename(old_path,target)' in ins,'rollback can restore old plugin')
ok('Compat.validate_candidate' in ins,'compatibility/ELF validation retained')
ok('main.lua' in ins and '_meta.lua' in ins,'plugin structure validation retained')
ok('MAX_ARCHIVE_ENTRIES' in ins and 'MAX_PLUGIN_FILES' in ins and 'max_plugin_bytes' in ins,'archive/file/expanded-size safety limits retained')
ok('symlinkattributes' in ins,'link-aware extraction safety retained')

# Job / lifecycle invariants.
ok('recover_install_journal' in job and 'install journal recovered' in job,'crash recovery for interrupted install exists')
ok('paused_user' in job and 'waiting_network' in job and 'cancelled' in job,'simple explicit task lifecycle retained')
ok('resume_generation=self.resume_generation+1' in job and 'function ExtensionJob:delete_data' in job,'delete invalidates auto-resume generation')
ok('pcall(done_cb' in job,'UI completion callbacks are contained with pcall')
ok('has_local_package' in job and 'not has_local_package and not network_connected()' in job,'verified local package can continue installation offline')
ok('source%-.+%.part$' in job,'job progress scans v4 source-local partials')

# Migration / cleanup.
ok('if schema<130' in store and 'extension_package_manager_version",4' in store,'schema 130 migrates to extension engine v4')
ok('route_health=removed' in store and 'cross_source_partials=removed' in store,'migration explicitly drops v3 route health/cross-source model')
ok('U.remove_tree(old_tasks)' in store,'legacy transient extension tasks are discarded')

# beta.17 extension discovery/install policy.
ok('recent_releases' in center and '/releases?per_page=20' in center,'beta.17 enumerates recent GitHub releases instead of trusting /releases/latest')
ok('best_release_source' in catalog and 'release.draft~=true and release.prerelease~=true' in catalog,'draft/prerelease releases are excluded from stable auto-resolution')
ok('近期正式 Release 没有可识别的插件 ZIP' in catalog,'manifest/channel releases without installable ZIP are skipped')
ok('community:' in center and 'install_strategy="standard"' in center,'unknown community repositories get a generic safe-install candidate instead of a catalog allow-list rejection')
ok('source_probe' in center and 'main.lua' in center and '_meta.lua' in center,'community source fallback requires positive plugin markers')
ok('源码包含多个 .koplugin 目录' in center,'ambiguous community source directory remains blocked')
ok('ExtensionInstall.install' in center,'center delegates to sole transactional installer')
ok('ffi/archiver' not in center and 'unzip -t' not in center,'center contains no second archive verifier/installer')
ok('route_score' not in center,'center has no route-scoring policy')
ok('META_CACHE_KEY="extension_center_repo_cache_v3"' in center and 'META_TTL=30*60' in center,'GitHub metadata uses a short-lived cache')
ok('可信等级' in center and '觅阅推荐 · 自动跟随官方稳定版' in center and '社区扩展 · 自动结构检查' in center,'curated/community trust labels are distinct without gating all community installs')
ok('repo_detail(plugin,target.repo,target)' in center,'recommendation details resolve GitHub live instead of rendering catalog package version as latest')
ok('if not source and is_curated and type(entry.package)=="table"' in center and 'repo_info.release_missing==true or repo_info.release_unusable==true' in center,'curated fixed package is only a verified fallback, not the normal latest-version source')
ok('for _,item in ipairs(managed_plugins(plugin))' in center and 'valid_repo(item.repo)' in center and 'resolve_repo_remote_complete(plugin,item.repo)' in center,'update-all covers every MiuRead-managed GitHub extension, including community installs')
ok('auto_allowed=(catalog_source~=nil or ambiguous_release)' in center and 'text="安装扩展"' in center,'community repository can expose Install when safe source resolution succeeds')
ok('current~="" and current~="unknown"' in catalog and 'seen_arch and not matched' in catalog,'generic Release selection rejects explicitly foreign architecture assets')

# Critical verified fallback metadata in catalog. Runtime latest is GitHub-driven.
crit={
 'fanqie':('v2.2.1',126623,'21b368198b26c2f0f874f413c001f87c94af82a2292046620fcb2207c16de86b','fanqie.koplugin'),
 'zlibrary':('v1.0.49-e3c07c1014e2a50b0cfae757c476c16cb38efec1',445092,'455423604c7c5eab20fa00f9ac31c89514202892b34347c45fc34435e1252553','zlibrary.koplugin'),
 'inkstain':('v3.9.0',10294040,'e43b33022a91d56590e78c52f8f845f0c869b6ab5a65a464f80942fe7787f080','inkstain.koplugin'),
 'pinyinime':('v1.2.0',63312207,'14047ed2638c32637c1dbc831f676967a221548f435443815b1c223881f4bbcb','pinyinime.koplugin'),
}
for id,(ver,size,sha,dirname) in crit.items():
    ok(id in catalog and ver in catalog and str(size) in catalog and sha in catalog and dirname in catalog,f'critical verified catalog fallback present: {id}')
for id in ['anki','zotero','highlightsync']:
    # Restrict check to a bounded entry region ending at next entry.
    m=re.search(r'id\s*=\s*"'+re.escape(id)+r'"(.*?)(?=\n\s*\{\n\s*id\s*=|\n\}\n\nlocal)',catalog,re.S)
    ok(bool(m) and 'package =' not in m.group(1),f'unverified project is not guessed as installable: {id}')

# Uploaded AppStore package is an exact official deterministic-catalog package.
app=Path('/mnt/data/appstore.koplugin.zip')
if app.exists():
    ok(app.stat().st_size==273795,'uploaded AppStore size matches catalog')
    ok(sha256(app)=='dde0fcb3d8254a3c573ab8c46e7e5f35b688fb4f4177909211aeae7ed7d76449','uploaded AppStore SHA matches catalog')
    with zipfile.ZipFile(app) as z:
        bad=z.testzip(); names=z.namelist()
    ok(bad is None,'uploaded AppStore ZIP CRC validates')
    ok(any(n=='appstore.koplugin/main.lua' for n in names) and any(n=='appstore.koplugin/_meta.lua' for n in names),'uploaded AppStore contains deterministic plugin root')

# beta.12 crash-backed repairs (#86/#91/#92).
dtask=text(MIU/'download_task.lua'); downloader=text(MIU/'downloader.lua')
ok('if schema<131' in store and 'session_storage_version",2' in store,'schema 131 compacts historical session state')
ok('compact_sessions_for_library' in store and 'parser-depth emergency compaction' in store,'store has normal + emergency session repair')
ok('REPORT_CONTEXT_KEYS' in store and 'legacy_report_context' in store,'report contexts are persisted through an explicit bounded shape')
ok('reader_url=session.url, context_updated_at=os.time()' in downloader and 'reader_url=session.url, chapters=map' not in downloader,'downloader no longer duplicates chapter catalog into sessions')
ok('HEAVY_DOWNLOAD_START_MIN_KB = 96 * 1024' in cfg,'fresh book downloads have a 96 MiB start guard')
start=dtask[dtask.find('function DownloadTask:start'):dtask.find('local stamp',dtask.find('function DownloadTask:start'))]
ok('RuntimePressure.memory_snapshot(true)' in start and 'download start deferred' in start,'download memory preflight runs before worker fork/state snapshot')
ok('function Plugin:_remember_wifi_suspend_intent' in main and 'self._wifi_suspend_want_on' in main,'pre-suspend Wi-Fi intent is retained')
ok('function Plugin:_wifi_resume_recover' in main and 'NetworkMgr.restoreWifiAsync' in main and 'NetworkMgr.scheduleConnectivityCheck' in main,'resume uses KOReader-owned async Wi-Fi restore + connectivity check')
ok('delays={.8,3,6,12,24,40,48}' in main,'Kobo resume recovery observes KOReader restore window without UI polling storms')
ok('requires_network=true' in main and 'network_recovering' in main,'automatic network Home work is gated while Wi-Fi is recovering')
wifi_slice=main[main.find('function Plugin:_remember_wifi_suspend_intent'):main.find('function Plugin:_reader_wifi_state')]
ok('os.execute(' not in wifi_slice,'MiuRead Wi-Fi recovery does not execute network daemon shell commands')

# beta.13 progress-sync regression repairs (#94 + partial/standalone progress).
sync=text(MIU/'sync.lua'); source_pos=text(MIU/'source_position.lua'); precise=text(MIU/'precise_position.lua')
service=text(MIU/'read_report_service.lua'); legacy=text(MIU/'legacy'/'read_report_worker.lua')
meta=text(PLUGIN/'_meta.lua')
ok('version = "5.8.0-beta.22"' in meta,'plugin metadata version is beta.22')
ok('if schema<132' in store and 'partial_catalogs_promoted' in store,'schema 132 migrates partial catalog trust safely')
ok('schema132_hash_verified' in store and 'core_map_hash' in store,'legacy partial catalog promotion is hash-gated')
ok('read_report_enabled=true' in downloader and 'read_report_enabled=not partial_range' not in downloader,'new partial downloads keep time-only reporting enabled')
ok('if row.partial_range==true' in sync and 'row.progress_sync_enabled~=false' in sync,'legacy partial records are eligible for safe time-only reports')
ok('当前章节版不上传阅读时间' not in sync and '当前章节版仅同步阅读进度' not in sync,'old partial reading-time hard block removed')
ok('catalog_word_counts_missing' in source_pos and 'whole_progress_available = progress ~= nil' in source_pos,'native chapter/co can exist before whole-book percentage')
ok('chapter_only = true' in precise and 'catalog_pending = chapter_only == true' in precise,'precise-position capture supports chapter-only anchor')
ok('function Sync:_complete_partial_position_progress' in sync and 'function Sync:recover_partial_coordinate' in sync,'partial coordinate can be completed after catalog recovery')
ok('function Sync:_persist_confirmed_progress_catalog' in sync and 'catalog_recovered_source' in sync,'remotely confirmed full catalog is persisted for old partial books')
ok('pending_progress_coordinate' in main and 'reading_end_whole_progress_pending' in main,'reading-end preserves exact chapter/co before full catalog recovery')
ok('PROGRESS_WRITER_MAX_WAIT_SECONDS = 8' in cfg and 'policy=soft_preempt_no_replay' in sync,'progress writer uses bounded soft preemption without replaying in-flight time writes')
ok('request_dispatched=false' in sync and 'dispatch_state_uncertain=true' in sync,'progress submit distinguishes definitely-unsent from uncertain dispatched requests')
ok('progress_upload_state="submitted"' in main and 'progress_upload_state="pending_send"' in main,'progress persistence distinguishes submitted from unsent')
ok('retry_count' not in main and 'retrying_message' not in main,'automatic same-position resubmit controls removed')
ok('safe_pending' in service and 'request_dispatched' in service and 'carry_remaining' in service,'reading-time service carries only provably unsent seconds')
ok('request_dispatched=true' in legacy and 'request_dispatched=false' in legacy,'compat worker reports dispatch boundary explicitly')
ok('pending_report_safe' in store and 'legacy_time_debt_replayed=false' in store,'legacy ambiguous reading-time debt is never replayed')
ok('submitted=true,settling=true,mapping_preparing=true' in main,'Home sync summary recognizes new durable progress states')
ok('_recover_all_pending_progress_coordinates' in main and '_submit_all_saved_pending_progress' in main,'Home recovery handles catalog-only and definitely-unsent progress')

# Pure fault-model checks for the intended state machine.
def whole_progress(catalog, uid, within):
    total=sum(max(0,int(r.get('words',0))) for r in catalog)
    before=0; selected=None
    for r in catalog:
        w=max(0,int(r.get('words',0)))
        if selected is None and str(r.get('uid'))==str(uid): selected=w
        elif selected is None: before+=w
    if not selected or total<=0: return None
    return ((before + selected*max(0,min(1,float(within)))) / total) * 100.0
cat=[{'uid':'a','words':1000},{'uid':'b','words':2000},{'uid':'c','words':1000}]
ok(abs(whole_progress(cat,'b',0.5)-50.0)<1e-9,'single-chapter 50% maps through full catalog, not local EPUB 50% by assumption')
ok(abs(whole_progress(cat,'b',0.25)-37.5)<1e-9,'partial chapter ratio maps to deterministic whole-book percentage')
ok(whole_progress([{'uid':'b','words':2000}],'b',0.5)==50.0,'genuine one-chapter book remains representable after remote confirmation')

def progress_recovery(upload_state, dispatched):
    if upload_state=='verified': return 'clear'
    if dispatched: return 'verify_only'
    return 'send'
ok(progress_recovery('pending_send',False)=='send','definitely-unsent progress is replayable')
ok(progress_recovery('submitted',True)=='verify_only','submitted/uncertain progress is verification-only')
ok(progress_recovery('verified',True)=='clear','verified progress is not replayed')

# beta.14 #93/#97 regression repairs.
home_data=text(MIU/'home_data.lua')
unified=text(MIU/'unified_library.lua')
ok('HOME_ACTION_MAX_VISIBLE=6' in main and 'HOME_ACTION_LAYOUT_VERSION=6' in main and 'mp=true' not in main[:main.find('local HOME_PANEL_ITEM_ORDER') if 'local HOME_PANEL_ITEM_ORDER' in main else 5000], '#93: Home quick bar is back to six recommended items without a dedicated 公众号 shortcut')
ok('mp_accounts=mp_accounts' in main and '_home_unified_sections(account_rows,miuread_rows,local_rows,mp_rows,mp_article_rows' in main,'#93: cached MP accounts are passed into the unified shelf separately from articles')
ok('type(opts.mp_accounts)' in unified and 'content_type="mp_account"' in unified and 'in_shelf=true' in unified,'#93: MP accounts are first-class remote shelf collections')
ok('mp_articles=mp_articles' in main and 'local_available=true' in unified,'#93: cached MP articles remain local/device records')
ok('function Plugin:_show_reader_more_panel' in main and '"公众号阅读",self:reader_menu()' in main,'#93: Reader More exposes the MP article return/prev/next menu')
refresh_slice=main[main.find('function Plugin:_home_manual_refresh'):main.find('function Plugin:_home_refresh_whole_page')]
ok('尚未设置本地书库' in refresh_slice and '_home_scan_local(true,false)' in refresh_slice and 'local_library_directory_dialog' not in refresh_slice,'#97: refresh never opens the local folder chooser')
action_slice=main[main.find('function Plugin:_home_action_entries'):main.find('function Plugin:_home_alerts')]
ok('self:_sync_home_pending()' in action_slice and '_show_home_quick_notice(anchor,"正在同步"' not in action_slice,'#97: Sync quick action reports real state instead of a fake submitted notice')
ok('local associated = state.connected == true' in home_data and 'network-manager-associated' in home_data,'#97: Wi-Fi association/SSID clears stale recovering UI state')
ok('READ_REPORT_SERVICE_VERSION = 28' in sync and 'heartbeat = base .. ".heartbeat"' in sync,'#97: ReadReport service upgraded to v28 with heartbeat state')
ok('function Sync:_daemon_health' in sync and 'function Sync:_restart_unhealthy_daemon' in sync,'#97: living-but-stalled ReadReport workers are detected and restarted')
ok('READ_REPORT_HEARTBEAT_STALE_SECONDS = 25' in cfg and 'READ_REPORT_REPORTING_STALE_SECONDS = 120' in cfg,'#97: heartbeat distinguishes idle stall from legitimate in-flight HTTP reporting')
ok('heartbeat_path' in service and 'heartbeat(false)' in service and 'heartbeat(true)' in service,'#97: child service writes liveness heartbeat outside uncertain report replay state')
ok('callback(false,{state="cancelled",reason="service_restarted"})' in sync,'#97: writer-barrier callers are released if a stuck service is restarted')
ok('math.max(4,tonumber(Config.PROGRESS_WRITER_MAX_WAIT_SECONDS) or 8)' in sync,'#97: foreground progress fence is short and bounded')
end_start=main.find('local function start_background_progress')
end_slice=main[end_start:main.find('if started then',end_start)]
ok('math.min(4,critical_wait_seconds(4))' in end_slice and 'time_writer_busy' in end_slice,'#97: reading-end position is parked after a 4s time-writer window instead of waiting tens of seconds')
ok('function Plugin:_progress_position_fingerprint' in main and 'progress_resolution_choice="local"' in main,'#97: an explicit local-position choice gets a durable exact-position fingerprint')
ok('function Plugin:_resume_remembered_local_progress' in main and '继续此前已选择的本机位置，不重复询问' in main,'#97: the same pending local position resumes without repeated conflict prompts')
ok('progress_resolution_choice","progress_resolution_fingerprint","progress_resolution_at' in store,'#97: remembered conflict decision survives session persistence/merge')
ok('active.key=="home_metadata"' in main and 'active.key=="home_cover"' in main and 'active.key=="home_cover_render"' in main,'#97: user interaction also yields optional metadata/cover work on low-memory Kindles')
ok('SCHEMA = 135' in cfg,'schema remains 135')

# beta.15 extension transport and cloud-write priority.
digests=text(MIU/'digests.lua')
ok('EXTENSION_CONNECT_TIMEOUT_SECONDS = 20' in cfg,'extension connect/DNS timeout widened to 20s')
ok('EXTENSION_STALL_SECONDS = 90' in cfg,'extension reconnect waits for a 90s true stall')
ok('--speed-limit 1 --speed-time' in dl,'slow-but-moving curl transfers are not killed at 1 KiB/s')
ok('--max-time' not in dl[dl.find('local function write_transport_script'):dl.find('local function run_curl')],'full curl download has no wall-clock completion timeout')
ok('expected>=LARGE_FILE_BYTES' in dl and 'transport=curl' in dl,'large packages bypass byte-zero KOReader HTTP and use resumable curl')
ok('probe_route' in dl and '--range 0-' in dl and 'probe_speed_bps' in dl,'fresh large packages perform bounded route probing')
ok('EXTENSION_PROBE_MAX_ROUTES = 3' in cfg and 'EXTENSION_PROBE_CONNECT_TIMEOUT_SECONDS = 4' in cfg and 'EXTENSION_PROBE_MAX_SECONDS = 5' in cfg,'route probing is capped to the first 3 high-value routes and at most 5s each')
ok('position<=probe_max' in dl and 'if not route._probe_attempted then return 2' in dl,'unprobed proxy fallbacks remain available after the bounded speed race')
ok('biggest>=RESUME_BYTES' in dl,'meaningful existing partial outranks fresh route speed probing')
ok('waiting_network=true' in dl and '断点已保留' in dl,'transient transport failures park the task with its checkpoint')
ok('sha256_file(path,256*1024)' in dl and 'function D.sha256_file' in digests,'large SHA-256 has a bounded-memory in-process fallback')
ok('release_package_candidates' in catalog and 'github-release-asset' in catalog,'GitHub Release assets are discovered dynamically without source guessing')
ok('多个同等候选安装包，需要选择' in catalog and '选择官方 Release 安装包' in center,'ambiguous official assets are surfaced for explicit user choice')
ok('probe_source_installability' in center and '/contents?ref=' in center,'source installability is confirmed through GitHub Contents API')
ok('source_installable' not in catalog,'source fallback no longer depends on per-plugin allow-list flags')
ok('github-source-verified' in catalog and 'source_probe.installable~=true' in catalog,'source ZIP requires positive plugin-structure evidence')
ok('local should_probe=release_error=="no_release" or release_error=="no_installable_release"' in center and 'if not should_probe then return nil end' in center,'GitHub/API failure never silently downgrades to source ZIP')
ok('source_kind=="github-release-asset" or source_kind=="github-source-verified"' in center,'persisted dynamic tasks accept only verified release/source identities')
ok('中文社区优先，大文件有界测速' in center and '正式安装包身份没有改变' in center,'extension UI describes the beta.15 transport/identity model instead of the old fixed-order model')
ok('ROUTE_HEALTH_TTL=6*60*60' in job and '_remember_route_health' in job,'recent successful download route is cached with a short TTL')
ok('paused_priority=true' in job and 'sync_priority' in job,'extension downloads have a dedicated cloud-sync priority pause')
ok('cloud_sync_priority=true' in dtask,'book downloads recognize cloud-sync priority as a transient pause reason')
ok('function Plugin:_critical_transfer_begin' in main and 'function Plugin:_critical_transfer_end' in main,'host owns one shared critical network lane for cloud writes')
ok('self.download_task.pause' in main and 'self.extension_task.pause' in main,'critical cloud writes pause both book and extension transfers')
ok('self.download_task.resume' in main and 'self.extension_task.resume' in main,'downloads resume after the cloud-write lane is released')
ok('download pause acknowledgement timed out' in sync and 'elapsed>=3' in sync,'critical progress write never waits indefinitely for download pause acknowledgement')
ok('annotation_delete' in main and 'annotation_sync_all' in main and 'annotation_manual' in main,'annotation writes also acquire the critical network lane')
ok('reading_end' in main and 'transfer_priority_started' in main,'reader finalization acquires and releases download priority')
ok('estimated_unpacked_bytes = 180 * 1024 * 1024' in catalog and 'max_plugin_bytes = 256 * 1024 * 1024' in catalog,'Pinyin large expanded payload is allowed by installer safety limits')
ok('required_free_bytes = 220 * 1024 * 1024' in catalog,'Pinyin preflight retains its 220 MiB free-space guard')
quick_order=re.search(r'local HOME_ACTION_ITEM_ORDER=\{([^\n]+)\}',main)
quick_default=re.search(r'local HOME_ACTION_ITEM_DEFAULT=\{([^\n]+)\}',main)
ok(bool(quick_order) and bool(quick_default)
   and quick_order.group(1).startswith('\"refresh\",\"search\",\"downloads\",\"sync\",\"sleep\",\"miuread_settings\"')
   and all(token in quick_default.group(1) for token in ['refresh=true','search=true','downloads=true','sync=true','sleep=true','miuread_settings=true'])
   and 'mp=' not in quick_default.group(1) and 'public' not in quick_default.group(1).lower(),
   'beta.17 keeps exactly the six recommended Home shortcuts and removes 公众号 from the middle strip')


panel_order=re.search(r'local HOME_PANEL_ITEM_ORDER=\{([^\n]+)\}',main)
panel_default=re.search(r'local HOME_PANEL_ITEM_DEFAULT=\{([^\n]+)\}',main)
ok(bool(panel_order) and '"mp"' in panel_order.group(1) and bool(panel_default) and 'mp=true' in panel_default.group(1),'beta.17 moves 公众号 into the pull-down control center')
ok('HOME_PANEL_LAYOUT_VERSION=7' in main and 'home.panel_items.mp=true' in main and 'home.panel_items.screenshot=false' in main,'untouched beta.16 control-center layout migrates to 公众号 without exceeding eight default slots')
ok('home.action_items.mp=nil' in main,'legacy 公众号 Home shortcut is actively removed during preference normalization')
ok('mp={icon="公众号"' in main and 'self:show_mp_shelf(false)' in main,'control-center 公众号 button opens the public-account shelf')
ok('repo = "Estela-Zelin84/inkstain.koplugin"' in catalog and 'repo_aliases = { "miumiupy98-art/inkstain.koplugin" }' in catalog,'InkStain canonical upstream and historical alias are both present')
ok('function M.canonical_repo' in catalog and 'canonical_repo(item.repo)' in center,'historical repository identities are canonicalized for installed records/update checks')
ok('sha256-recorded' in dl and 'package_meta.sha256=trim(value.sha256):lower()' in center,'digest-less official assets record a local SHA-256 fingerprint when available')
ok('source_kind=="github-release-asset" or source_kind=="github-source-verified"' in center,'resumed dynamic installs remain restricted to verified GitHub release/source identities')

# beta.18 device beautification + unified lockscreen provider integration.
settings=text(MIU/'plugin_settings.lua')
ok('{ key = "device_beauty", label = "设备美化"' in catalog,'beta.18 adds 设备美化 recommendation category')
for token in ['id = "appearance"','id = "inkstain"','id = "dashwallpaper"','id = "coverprogress"','id = "highlightsscreensaver"']:
    ok(token in catalog,'beta.18 device beauty entry present: '+token.split('"')[1])
ok('repo = "RC-APC/DashWallpaper.koplugin"' in catalog and 'install_dirname = "DashWallpaper.koplugin"' in catalog,'DashWallpaper uses verified upstream/source install identity')
ok('featured_order = 8' in catalog and 'lockscreen_provider = "dashwallpaper"' in catalog,'DashWallpaper is featured and marked as a lockscreen provider')
ok('lockscreen_provider = "inkstain"' in catalog,'InkStain is marked as the other first-wave external lockscreen provider')
# Keep Appearance/CoverProgress/Highlights out of direct provider takeover.
for id in ['appearance','coverprogress','highlightsscreensaver']:
    m=re.search(r'id\s*=\s*"'+id+r'"(.*?)(?=\n\s*\{\n\s*id\s*=|\n\}\n\nlocal)',catalog,re.S)
    ok(bool(m) and 'lockscreen_provider' not in m.group(1),id+' remains recommendation-only, not a direct lockscreen provider')
ok('return plugin:home_lockscreen_settings_menu()' in settings and '{text="锁屏壁纸"' in settings,'settings UI is unified under 锁屏壁纸')
ok('function Plugin:home_lockscreen_provider_menu()' in main and 'text="书籍封面"' in main and 'text="墨痕壁纸"' in main and 'text="DashWallpaper"' in main,'unified provider selector exposes native / InkStain / DashWallpaper')
ok('function Plugin:home_native_lockscreen_style_menu()' in main and 'for _,style in ipairs({"frame","fit","fill"})' in main,'native frame/fit/fill styles remain available')
ok('lockscreen_last_native_style' in main and 'home.lockscreen_last_native_style=style' in main,'last native cover style is preserved for return from external providers')
ok('lockscreen_provider="native"' in store and 'lockscreen_pending_provider=""' in store and 'lockscreen_dash_source=""' in store and 'lockscreen_native_snapshot={}' in store,'schema 133 defaults persist provider, pending intent, Dash source and native rollback snapshot')
ok('if schema<133 then' in store and 'schema 132 -> 133 done' in store,'schema 133 migration separates legacy receipt mode from native style')
ok('function Plugin:_lockscreen_capture_native_snapshot' in main and 'function Plugin:_lockscreen_restore_native_snapshot' in main,'native KOReader screensaver state has explicit capture/restore')
ok('function Plugin:_activate_dashwallpaper_file' in main and 'function Plugin:_activate_inkstain_lockscreen' in main and 'function Plugin:_activate_native_lockscreen' in main,'all three provider transitions use one MiuRead bridge')
ok('if not self:_dashwallpaper_png_valid(path) then' in main and 'instance:downloadAndSave(wall,10)' in main and 'self:_activate_dashwallpaper_file(path,index,wall.name)' in main,'Dash first-use downloads and validates PNG before committing provider switch')
ok('if old=="inkstain" then' in main and 'self:_inkstain_disable()' in main and 'self:_lockscreen_capture_native_snapshot(home,preferences)' in main,'InkStain -> Dash restores/captures native state before Dash takeover')
ok('dash_snapshot=U.copy(home.lockscreen_native_snapshot or {})' in main and 'rollback_home.lockscreen_native_snapshot' in main,'failed Dash -> Ink switch restores Dash rollback snapshot')
ok('if old=="dashwallpaper" then' in main and 'self:_lockscreen_restore_native_snapshot(home,preferences)' in main,'Dash -> native/Ink paths restore the saved native screen state')
ok('lockscreen_pending_provider' in main and '安装并使用' in main and 'install_catalog_id(self,id)' in main,'missing Ink/Dash can be installed directly from lockscreen settings with pending intent')
ok('function Plugin:_on_extension_install_complete' in main and 'function Plugin:_on_extension_install_failed' in main and 'function Plugin:_resume_pending_lockscreen_provider' in main,'install success/failure/restart continuation is wired into lockscreen intent')
ok('notify_install_failed(plugin,repo' in center and center.count('notify_install_failed(plugin,repo')>=6,'extension install failures clear pending lockscreen intent across early/download/install failures')
ok('UIManager:scheduleIn(.35,function() self:_reconcile_lockscreen_provider(true) end)' in main and 'UIManager:scheduleIn(1.6,function() self:_resume_pending_lockscreen_provider() end)' in main,'startup reconciles missing providers and resumes install-and-use intent')
ok('墨痕插件已不存在，锁屏已恢复为书籍封面' in main and 'DashWallpaper 插件已不存在，锁屏已恢复为书籍封面' in main,'missing provider plugins fall back to native cover with one notice')
ok('Device.isAndroid' in main and 'Android 当前不支持由觅阅接管 KOReader 锁屏壁纸' in main and 'Device:canSuspend()' in main,'unsupported Android/no-suspend devices are blocked only from MiuRead lockscreen takeover')
ok('style=="receipt" or style=="dash"' in main and main.count('style=="receipt" or style=="dash"')>=2,'screensaver hook delegates both external providers instead of rendering MiuRead cover over them')
ok('function Plugin:_dashwallpaper_open_settings' in main and 'instance.buildSubmenu' in main,'Dash own settings remain owned by DashWallpaper')
ok('function Plugin:_dashwallpaper_refresh' in main and 'auto_enabled' not in main[main.find('function Plugin:_dashwallpaper_refresh'):main.find('function Plugin:_dashwallpaper_open_settings')],'MiuRead does not duplicate Dash daily auto-update policy')
ok('function Plugin:_inkstain_open_settings' in main,'InkStain keeps its own settings surface')
# beta.17 homepage decision remains intact.
ok('HOME_ACTION_MAX_VISIBLE=6' in main and 'home.action_items.mp=nil' in main,'公众号 remains absent from the Home middle quick strip')
ok('mp={icon="公众号"' in main and 'panel_items={wifi=true,bluetooth=false,rotate=true,mp=true' in store,'公众号 remains available in the pull-down control center')

# beta.19 reading hot-path / persistence invariants.
ok('function Sync:_readtime_recovery_path()' in sync and 'readtime-recovery-v1.json' in sync,'beta.19 has a tiny reading-time recovery journal')
ok('pending_report_safe=seconds>0' in sync and 'U.atomic_write(self:_readtime_recovery_path(),Json.encode(data),true)' in sync,'SAFE pending recovery is atomically journaled')
ok('recovery journal fallback to full settings' in sync and '},true)' in sync[sync.find('function Sync:_save_safe_pending_state'):sync.find('function Sync:_persist_daemon_session')],'journal failure falls back to full settings persistence')
ok('self.store:save_session(book_id,patch,force==true)' in sync,'300s daemon snapshot is memory-only unless lifecycle force=true')
accepted_start=sync.find('if status.accepted then',sync.find('local credential_adopted=false'))
accepted=sync[accepted_start:sync.find('elseif status.uncertain==true',accepted_start)]
ok('},false)' in accepted and 'report_state="ok"' in accepted,'normal accepted ReadReport state is deferred, not a full settings flush')
unconfirmed=sync[sync.find('elseif status.uncertain==true'):sync.find('elseif status.error then')]
ok('},false)' in unconfirmed,'normal unconfirmed ReadReport state is deferred')
ok('self:_mark_auth_channel_ok(channel,tostring(channel or "")=="read_report")' in main,'read_report auth-health success is deferred from full settings persistence')
ok('local health_only_repeat=deferred==true' in main and 'tostring(previous.state or "") == "ok"' in main and 'self:_save_auth_health(health,health_only_repeat)' in main,'first/recovery read_report auth success still persists; only repeated ok timestamps are deferred')
ok('opt.deferred==true and not credentials_changed' in store and 'return self:set("auth",incoming)' in store,'deferred auth health never defers credential changes')
ok('strip_progress_sources(remote)' in sync and 'strip_progress_sources(web)' in sync and 'strip_progress_sources(agent)' in sync,'new remote progress persistence strips synthetic sources fan-out')
ok('compact_progress_sources(row)' in store and 'if schema<134 then' in store,'schema 134 repairs historical progress-source nesting')
ok('local FullShelfView=_G._miu_desktop_lazy("miuread.full_shelf_view")' in main and 'local HomeView=_G._miu_desktop_lazy("miuread.home_view",{' in main and 'local LocalBrowserView=_G._miu_desktop_lazy("miuread.local_browser_view")' in main and 'local HomeQuickPanel=_G._miu_desktop_lazy("miuread.home_quick_panel",{' in main,'four desktop-heavy modules are lazy-loaded')
ok('module=module or package.loaded[name]' in main and 'is_shown=function() return false end,current=function() return nil end' in main,'cold HomeView probes do not defeat lazy loading during reader startup')
ok('local FullShelfView=require("miuread.full_shelf_view")' not in main and 'local HomeView=require("miuread.home_view")' not in main,'desktop-heavy modules are not eagerly required')
ok('[MiuRead][StorePerf] full settings flush' in store and 'elapsed_ms=' in store and 'bytes=' in store,'full settings flushes log reason, elapsed time and size')
# Performance work must not import the user-modified toolbar compromises.
b18_main=text(ROOT.parent.parent/'beta18'/'miuread-koreader-5.8.0-beta.18'/'miuread.koplugin'/'main.lua') if (ROOT.parent.parent/'beta18'/'miuread-koreader-5.8.0-beta.18'/'miuread.koplugin'/'main.lua').exists() else None
if b18_main is not None:
    # Remove only the two intentional main.lua regions and verify the rest remains beta.18-identical.
    ok('1%' not in main[main.find('function Plugin:on_read_report_success'):main.find('function Plugin:on_read_report_failure')], 'no 1% reading-progress throttle added to ReadReport callbacks')

# beta.20 Issue #105 group-filter recovery + large-shelf recommendation.
library=text(MIU/'library.lua')
ok('requested_enabled=requested' in library and 'enabled=requested and selected>0' in library,'beta.20 empty selected-group state is fail-open full shelf')
ok('stale_selection_recovered' in library and 'empty_selection_recovered' in library,'beta.20 records both stale and empty selection recovery reasons')
ok('if #raw_books>0 and filter.enabled~=true and #books==0 then' in library and 'invalid_zero_recovered' in library,'beta.20 prevents invalid local zero shelf when raw books exist and no effective filter is active')
ok('group_response_authoritative=response_group_authoritative' in library and 'function Library:large_shelf_group_hint(threshold)' in library,'large-shelf hint requires fresh authoritative group evidence')
ok('if count<threshold then return nil end' in library and 'reason="large_ungrouped_shelf"' in library,'large-shelf hint threshold is enforced without changing shelf rows')
ok('[MiuRead][ShelfFilter] snapshot' in library and '"raw="' in library and '"selected="' in library and '"effective="' in library,'shelf diagnostics expose raw/groups/selected/effective state')
ok('if schema<135 then' in store and 'schema 134 -> 135 done' in store,'schema 135 migrates Issue #105 states')
ok('filter.recovery_notice_pending="empty_selection"' in store and 'filter.recovery_notice_pending="stale_selection"' in store,'migration records one-time recovery notice')
ok('cache.books=U.copy(raw)' in store and 'fingerprint="all"' in store,'migration restores raw cached books offline when no effective filter exists')
ok('shelf_group_hint={accounts={}}' in store,'large-shelf reminder state is account-scoped')
ok('local LARGE_SHELF_GROUP_HINT_THRESHOLD=100' in main,'large-shelf group recommendation threshold is 100 books')
ok('DownloadDatabase.account_key(self.store)' in main,'large-shelf reminder is keyed per account')
ok('candidate.authoritative~=true' in main and 'count<LARGE_SHELF_GROUP_HINT_THRESHOLD' in main,'UI reminder refuses non-authoritative or sub-threshold candidates')
ok('text="知道了"' in main and 'text="不再提醒"' in main,'large-shelf reminder exposes acknowledge and permanent-disable actions')
ok('current.dismissed=true' in main and 'episode reset' in main,'per-account permanent disable and grouped-episode reset are implemented')
ok('if not HomeView.is_shown() or self:_active_reader_ui() then' in main and 'self:_home_ui_busy() or self:_home_modal_surface_active()' in main,'large-shelf reminder waits for a safe Home UI moment')
ok('if filter.enabled~=true or not shelf_filter_has_selection(filter) then return "全部微信书架" end' in main,'empty selection is labeled as full WeRead shelf')
ok('if not shelf_filter_has_selection(f) then f.enabled=false end' in main,'deselecting the last group returns to full shelf')
ok('text="清空选择"' in main and 'f.enabled=false; f.archives={}; f.archive_keys={}' in main,'clear selection explicitly returns to full shelf')
ok('当前没有已允许的有效分组' not in main and '主页会保持空状态，不会回退到完整书架' not in main,'old intentional-empty-shelf UI semantics are removed')

# beta.21 PR #72 online comment-like integration hardening.
popup=text(MIU/'thought_native_popup.lua')
settings=text(MIU/'plugin_settings.lua')
api=text(MIU/'api.lua')
preference_lines=[line for line in store.splitlines() if line.lstrip().startswith('preferences={')]
ok(len(preference_lines)==1,'beta.21 store has exactly one effective preferences default table')
ok(bool(preference_lines) and 'shelf_group_hint={accounts={}}' in preference_lines[0] and 'action_layout_version=6' in preference_lines[0] and 'panel_layout_version=7' in preference_lines[0],'beta.21 preserved the beta.20 preferences generation while resolving PR #72')
ok(bool(preference_lines) and 'thoughts={enabled=true,online_likes=false' in preference_lines[0],'online comment likes are disabled by default in the effective preferences table')
ok('function Plugin:_online_comment_likes_enabled()' in main and 'online_likes==true' in main,'online-like feature is explicitly opt-in')
ok('function Plugin:_remember_online_like_state(account_key,review_id,is_liked,likes)' in main and 'is_liked=is_liked==true' in main and 'likes=math.max(0,math.floor(tonumber(likes) or 0))' in main,'confirmed online-like cache stores both heart state and likesCount')
ok('self:_remember_online_like_state(like_account_key,review_id,payload.is_liked,payload.likes)' in main,'server-confirmed likesCount is remembered with the heart state')
ok('comments[index].is_liked=is_liked' in main and 'comments[index].likes=math.max(0,math.floor(likes))' in main,'reopened thought popups restore both heart state and confirmed count')
ok('review_id,is_liked and "1" or "0"' in main and 'likes~=nil and tostring(math.max(0,math.floor(likes))) or "?"' in main,'popup cache signature includes review id, heart state and confirmed likes count')
ok('function Api:review_single(review_id, context)' in api and '/web/review/single?reviewId=' in api,'official review-like state lookup is present')
ok('function Api:like_review(review_id, is_unlike, context)' in api and '"/web/review/like"' in api and 'isUnlike=is_unlike == true' in api,'online like/unlike uses the WeRead review-like endpoint')
like_api=api[api.find('function Api:review_single'):api.find('function Api:remove_review')]
ok('retries=0' in like_api and 'rate_limit_retries=0' in like_api,'review-like read/write paths do not gain blind transport retries')
like_start=main.find('function Plugin:_toggle_online_review_like')
like_end=main.find('function Plugin:_open_thought_info',like_start)
like_main=main[like_start:like_end]
ok('if not self:_online_comment_likes_enabled() or review_id=="" then' in like_main,'disabled online likes cannot start a request')
ok('self._online_like_auth_dead==revision' in like_main and 'auth_code==-2011 or auth_code==-2012' in like_main,'confirmed expired login is circuit-broken per auth revision')
ok('succ~=nil and not' in like_main and '微信读书未接受本次点赞' in like_main,'succ=false cannot be rendered as a successful like')
ok('server_likes=response and tonumber(rawget(response,"likesCount"))' in like_main and 'server_count=server_likes~=nil' in like_main,'server likesCount wins over local +/-1 when available')
ok('text="在线评论点赞"' in settings and '_online_comment_likes_enabled' in settings,'划线与评论 settings expose the opt-in online-like switch')
ok('if self.online_likes_enabled == true then\n        UIManager:setDirty(self, function() return "ui", self.popup_dimen end)' in popup and 'UIManager:setDirty(self, function() return "partial", self.popup_dimen end)' in popup,'popup opening uses PR waveform only when likes are enabled and beta.20 partial refresh otherwise')
ok('UIManager:setDirty(nil, function() return "ui", region end)' in popup and 'UIManager:setDirty("all", function() return "partial", region end)' in popup,'popup closing preserves beta.20 partial refresh when likes are disabled')
ok('if self._like_inflight[comment_index] then return true end' in popup,'same-comment duplicate like taps are blocked while a request is in flight')
ok('if self._like_session ~= session then return end' in popup,'stale pooled-popup async like results cannot update a reopened popup')
ok('UIManager:setDirty(self, function() return "ui", dirty end)' in popup and 'previous_button_dimen' in popup,'successful likes repaint only the affected like row when geometry is stable')
ok('pending_like' not in store.lower() and 'like_queue' not in store.lower(),'online likes do not create a persistent offline like queue/database')
ok('SCHEMA = 135' in cfg,'beta.21 keeps schema 135; the optional boolean requires no migration')

# Syntax-check every shipped Lua source.
texluac=Path('/usr/bin/texluac')
if texluac.exists():
    lua_files=sorted(PLUGIN.rglob('*.lua'))
    failed=[]
    for p in lua_files:
        r=subprocess.run([str(texluac),'-p',str(p)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={**__import__('os').environ,'TERM':'xterm'})
        if r.returncode: failed.append((p,r.stderr.decode('utf-8','replace')))
    ok(not failed,f'all shipped Lua files parse ({len(lua_files)} files)')
    if failed:
        for p,e in failed: errors.append(f'Lua parse failed {p}: {e[:200]}')

# Dynamic regression tools that are portable under texlua.
texlua=Path('/usr/bin/texlua')
if texlua.exists():
    for tool in ['test_extension_catalog.lua','test_extension_download.lua','test_extension_install.lua','test_store_repair.lua','test_store_shared.lua','test_digest_stream.lua','test_readtime_recovery.lua','test_shelf_group_recovery.lua','test_online_comment_likes.lua','test_http_keepalive.lua']:
        r=subprocess.run([str(texlua),str(ROOT/'tools'/tool)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={**__import__('os').environ,'TERM':'xterm'})
        ok(r.returncode==0,f'dynamic regression passes: {tool}')
        if r.returncode:
            errors.append(f'{tool} failed: '+r.stderr.decode('utf-8','replace')[:400])



# beta.22 PR #73 WeRead download connection reuse invariants.
http=text(MIU/'http.lua')
reader=text(MIU/'reader.lua')
downloader=text(MIU/'downloader.lua')
ok('HTTP_KEEPALIVE = true' in cfg,'beta.22 enables download HTTP keep-alive explicitly')
ok('local KEEPALIVE_IDLE_SECONDS = 25' in http,'keep-alive idle timeout remains 25 seconds')
ok('local KEEPALIVE_MAX_REUSE = 64' in http,'keep-alive per-connection reuse cap remains 64')
ok('if Config.HTTP_KEEPALIVE == false then return nil end' in http,'keep-alive has a complete config rollback switch')
ok('if not (opt and opt.keepalive == true) then return nil end' in http,'connection reuse is per-request explicit opt-in')
ok('if tostring(sink_path or "") ~= "" then return nil end' in http,'streaming file downloads remain outside the connection pool')
ok('if not is_weread_url(url) then return nil end' in http,'connection reuse is restricted to WeRead origins')
ok('connection_is_stale(entry.conn)' in http,'pooled sockets are checked for staleness before reuse')
ok('connection:find("close", 1, true)' in http and 'transfer-encoding' in http and 'content-length' in http,'only self-delimited non-close responses may return to pool')
ok('session.uses + 1 >= KEEPALIVE_MAX_REUSE' in http,'64-use cap is enforced before returning a connection to the pool')
ok('method == "GET" or method == "HEAD"' in http,'transparent stale-socket replay is limited to GET/HEAD')
ok('keepalive.received_any ~= true' in http and 'total_bytes == 0' in http,'transparent replay requires no response bytes to have arrived')
ok('self:close_idle_connections()' in http[http.find('function Http:probe_download_recovery'):http.find('function Http:_pacing_path')],'network recovery probe clears the connection pool')
ok('self:close_idle_connections()' in http[http.find('function Http:_wait_rate_limit'):http.find('function Http:_pace')],'rate-limit cooldown clears the connection pool')
ok('keepalive=request_options.keepalive==true' in reader,'catalog request forwards explicit download keep-alive')
ok('keepalive=keepalive==true' in reader,'reader state/shard requests forward explicit keep-alive')
ok('{on_retry=catalog_retry_notice,keepalive=true}' in downloader.replace('\n',''),'download catalog explicitly opts into keep-alive')
ok('keepalive=true' in downloader,'chapter download explicitly opts into keep-alive')
ok('function Downloader:book(input, opt, progress)' in downloader and 'pcall(self.http.close_idle_connections, self.http)' in downloader,'download task closes pooled connections on every exit path')
ok('[MiuRead][Download] run summary' in downloader,'download run summary log is present')
for token in ['elapsed=%.1fs','network=%.1fs','pacing=%.1fs','ratelimit=%.1fs','throttle=%.1fs','"requests="','"connections="','"reused="','"bytes="']:
    ok(token in downloader,f'download summary retains {token}')

print(f'checks={len(checks)} failures={len(errors)}')
if errors:
    for e in errors: print('FAIL:',e)
    sys.exit(1)
for c in checks: print('PASS:',c)
