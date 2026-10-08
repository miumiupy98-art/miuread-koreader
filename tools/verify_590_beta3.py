#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
def read(p): return (root/p).read_text(encoding='utf-8')
meta=read('miuread.koplugin/_meta.lua')
config=read('miuread.koplugin/miuread/config.lua')
main=read('miuread.koplugin/main.lua')
reader=read('miuread.koplugin/miuread/reader.lua')
center=read('miuread.koplugin/miuread/extension_center.lua')
protocol=read('miuread.koplugin/miuread/protocol.lua')
internal=read('miuread.koplugin/miuread/internal_links.lua')
localmeta=read('miuread.koplugin/miuread/local_metadata.lua')
legacy=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
excerpt=read('miuread.koplugin/miuread/book_excerpt_dialog.lua')
ch=read('CHANGELOG.md')
wf=read('.github/workflows/release-beta.yml')

ok('version = "5.9.0-beta.3"' in meta,'metadata version beta.3')
ok('VERSION = "5.9.0-beta.3"' in config,'config version beta.3')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('## 5.9.0-beta.3' in ch,'beta.3 changelog section exists')

# PR #120 translation parity + 5.9 integration.
for rel in ['miuread.koplugin/miuread/translation.lua','miuread.koplugin/miuread/translation_generation.lua']:
    ok((root/rel).is_file(),f'{rel} exists')
ok('_show_reader_translation_panel' in main and '_request_reader_translation_mode' in main,'reader translation UI and request path wired')
ok('translation_font_scale' in main and '80' in read('miuread.koplugin/miuread/translation.lua'),'translation font scaling retained')
ok('generate_translation_uid' in main and 'translation_mode' in main,'translation generation and pending install wired')
ok('rebase_settings' in main and 'recover_settings' in main,'translation EPUB settings migration and recovery wired')
ok('opt.translation==true' in reader,'translation path present in reader')
ok('function Reader:chapter_state(book_id,chapter_uid,keepalive,fresh)' in reader,'translation fresh context coexists with cached normal context')
ok('READER_CONTEXT_MAX_AGE = 240' in reader,'normal whole-book reader context reuse retained')
ok('headers["Cache-Control"]="no-cache, no-store, max-age=0"' in reader,'translation fresh reader page bypasses cache')
ok('context and context.translation' in reader and 'pclts' in protocol,'translation browser request nonce/signing fields retained')
ok('MiuReadTranslationContentPending' in reader,'unfinished translation cannot become empty structure page')
ok('href' in internal and '&amp;' in read('tools/test_internal_links.lua'),'internal-link escaping regression test retained')

# Extension Center UX.
ok('UPDATE_AUTO_INTERVAL=12*60*60' in center,'extension auto-check interval')
ok('UPDATE_VISIBLE_TTL=24*60*60' in center,'extension update-state TTL')
ok('run_async_silent' in center and 'maybe_auto_check' in center,'silent background update discovery')
ok('previous.status=="update" or previous.status=="same" or previous.status=="blocked"' in center,'network failure preserves recent known update state')
ok('text="可更新扩展"' in center and 'text="扩展更新"' in center and 'text="检查扩展更新"' in center,'state-specific update rows')
ok('text="全部更新"' in center and 'start_bulk_update(plugin,updates)' in center,'bulk extension update exposed')
ok('尚未处理的更新状态会保留' in center,'bulk failure preserves remaining markers')
ok('text="已安装扩展"' in center,'installed plugins moved to submenu')
rec=center[center.index('local function recommendation_entry_row'):center.index('local function recommendation_category_menu')]
ok('installed_status_label' not in rec and 'status="已安装"' in rec,'recommendation rows suppress version numbers')
show=main[main.index('function Plugin:show_downloads'):]
idx_book=show.index('text="书籍下载"')
ok(show.index('text="下载扩展"')<idx_book and show.index('text="更新扩展"')<idx_book and show.index('text="插件下载任务"')<idx_book,'extension actions stay before book download rows')
ok('startup_idle' in main and 'network_restored' in main,'automatic discovery wired to idle/network recovery')

# #117 parity / later strengthening.
ok('pcall(Device.input.setClipboardText,text)' in main,'#117 thought clipboard API fix retained')
ok('pcall(Device.input.setClipboardText, clean_text(self.context.text))' in excerpt,'#117 excerpt clipboard API fix retained')
ok('local function percent_to_ratio' in legacy,'#117 0-100 percent conversion retained')
ok('refusing 100% progress outside final readable chapter' in read('miuread.koplugin/miuread/legacy/read_report_worker.lua') or 'terminal_progress' in read('tools/test_terminal_progress_guard.lua'),'post-#117 false-100 guard retained')

# #118 parity / later strengthening.
ok('decode_numeric_entities' in localmeta,'#118 numeric XML entity decode retained')
ok('strip_cdata' in localmeta,'#118 CDATA handling retained')
ok('set_identity' in localmeta and 'in_account_shelf' in localmeta,'#118 shelf identity merge protection retained')
ok('miuread.json' in localmeta and 'protected_title' in localmeta,'post-#118 MiuRead manifest title protection retained')
ok('<rdf:' in localmeta or 'rdf:' in localmeta,'post-#118 RDF/XMP metadata protection retained')

# 5.9 core invariants must not regress.
for needle,msg in [
 ('正在同步最新阅读位置…','opening sync surface'),
 ('late_remote_after_user_interaction','late remote interaction guard'),
 ('_show_position_undo','position undo'),
 ('POSITION_CLOCK_SKEW_GRACE_SECONDS','clock skew guard'),
 ('remote_exact_coordinate_missing_local_safe','exact remote target required')]:
    ok(needle in main or needle in config,msg)
ok('mapped_percent_equivalent' not in main,'old percent-equivalent success path absent')
ok('python3 tools/verify_590_beta3.py' in wf,'release workflow runs beta3 verifier')
ok('luajit tools/test_translation_fetch.lua' in wf,'release workflow runs translation fetch regression')
ok('python3 tools/test_extension_center_ux.py' in wf,'release workflow runs extension UX verifier')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL'),m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
