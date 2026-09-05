# 5.8.0-beta.9 verification

Scope: beta.8 cumulative behavior plus the compact QuickPanel/UI information-architecture changes. Schema remains 128.

Checks performed in the build environment:

- Lua load/compile syntax: 134/134 plugin Lua files pass `texluac -p`.
- Implementation assertions: 79/79 passed for the beta.9 QuickPanel/customization/SVG/update-entry requirements.
- QuickPanel layout assertions: one row only; visual cap 8; supported items are filtered before the cap; 1/3/5/6/7/8 item width distribution exactly consumes the available row width including gaps.
- Customization assertions: candidate pool remains 16 items; new selections are refused at 8; legacy >8 selections are not destructively normalized; customization displays the selected count and overflow guidance.
- Detail-row assertions: detail height is conditional at whole-row level; no-detail layouts do not reserve a blank third line; layouts with runtime status keep all icon/label baselines aligned.
- QuickPanel labels/status assertions: Wi-Fi detail contains no SSID; sync/orientation statuses are compact; Return/KO settings/File/Exit/Restart use short labels.
- SVG assertions: every built-in QuickPanel `icon_key` resolves to an existing SVG after aliases. `koreader-settings`, `reboot`, and `poweroff` map to bundled files; missing icons fall back to `more.svg` with a one-time warning rather than a bullet.
- Performance-boundary assertions: QuickPanel still starts from `HomeData.cached_device_state()` and `_home_sync_status_label_cached()`; no new network probe, persistent session scan, download-queue detail lookup, or periodic polling was added to the opening path.
- Update information architecture: “更新与关于” contains channel selection immediately followed by manual check for that channel; “系统维护” no longer contains a duplicate MiuRead update action.
- Release package hygiene: no forbidden `.md`/`.epub`/`.log`/runtime-settings file exists under `miuread.koplugin`.

Real e-ink visual spacing, touch hit comfort, frontlight hardware behavior, and perceived latency still require device validation; static/build checks cannot prove hardware UX.
