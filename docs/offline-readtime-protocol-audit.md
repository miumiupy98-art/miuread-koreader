# E-Ink 离线阅读时长协议核对

当前实现以文末“上游设计收敛复查”为准；前面的 beta.8 迁移和首次 rebase 段落保留为历史记录。

核对日期：2026-10-25。参照对象为微信读书 E-Ink 2.1.2 缓存二进制中的离线补传代码。

核心语义一致：补传的是尚未成功上报的阅读时长，保留历史小时，收到明确成功回执后清理本地记录。
官方客户端支持集中提交累计离线记录，不能把“联网后补回数小时”本身认定为异常。
异常标记和可信的本地书籍版本已接入持久队列。小时结算、随机源和请求生命周期仍有差异，
尚不能称为官方客户端的完整复现。

## 核对范围和证据

依据是客户端 DEX 的方法实现、Retrofit 注解、Fastjson 字段注解及序列化路径，以及签名库常量；
不是官方公开接口规范，也不是官方客户端的网络抓包。服务端接受一次请求不能证明所有字段都被校验，
本核对也不能推导服务端的封号规则或安全上传阈值。

原始文件位于本机临时目录 `miuread-eink-protocol-20261023`，没有复制二进制或账号数据到仓库。
源文件 SHA256、完整字段清单及关键方法位置保存在
[协议夹具](../tools/fixtures/eink_readtime_212_contract.json)，可用于识别同一份二进制。

| 编号 | 客户端证据 |
| --- | --- |
| S1 | `classes3.dex`：`BaseReportService.batchUploadProgress` 的 POST、JSONEncoded、JSONField 注解；`BaseReportService$DefaultImpls.batchUploadProgress$default` |
| S2 | `classes3.dex`：`ReportService.generateBookReadPostBody`、`generateBookReadPostBodyList` 及其 lambda |
| S3 | `classes3.dex`：`ReportService.updateReadProgress$lambda-6$lambda-3`、`resendOfflineReadingInfos`、`clearReadingInfo` |
| S4 | `classes3.dex`：`ReportService.generatePayLoad`；`classes4.dex`：`Encrypt.encryptAntiReplaySignature`；`classes5.dex`：`FeatureGuestTokenWrapper`；`libencrypt.so` 的映射表与盐 |
| S5 | `classes9.dex`：`AntiReplayAction$DefaultImpls.getAntiReplaySignature` 和 `getRandom` |
| S6 | `classes3.dex`：`BaseBookReadPostBody` 字段、getter 与 `JSONField` 注解 |
| S7 | `classes11.dex`：`ParameterHandler$JSONField.apply`、`JSONBody$Builder.build` 及其过滤器；`classes5.dex`：`JavaBeanProxy.has`；`classes6.dex`：`TypeUtils.computeGetters` |
| S8 | `classes3.dex`：`ReportServiceKt.hourBeginTime`、`saveHoursTime`；`Hour$Companion.generateCurrentTimeZone` |
| S9 | `classes13.dex`：`BooleanResult.isSuccess` |
| S10 | `classes4.dex`：`TimeChangeCheck.recordCurrentTime`、`checkTimeZone`；`classes7.dex`：`ModuleInitializer$initAppService$11.invoke`；`classes5.dex`：`FeatureServerTimeMaxOffsetWrapper` |

## 请求与字段

| 项目 | 官方客户端 | 当前实现和结论 |
| --- | --- | --- |
| 接口 | POST `/book/batchUploadProgress`，JSON 请求体。S1 | 一致，沿用 E-Ink 授权通道。 |
| 外层字段 | `books`、`timestamp`、`random`、`signature`；`recordCreateTimeZone` 可选。离线调用传默认 null，参数处理器跳过 null。S1、S7 | 已修正：离线请求省略外层可选时区；书籍与小时中的时区仍保留。 |
| 外层时间 | `System.currentTimeMillis()`，毫秒。S3 | 已修正：有高精度时钟时保留毫秒，不再始终把整秒乘 1000。 |
| 随机数 | 内层、外层分别调用随机数生成器，范围均为 0 至 999。S2、S5 | 已修正：分别取值。官方用 `SecureRandom`，我们仍用 Lua `math.random`，随机源不同。 |
| 外层签名 | SHA256，输入为毫秒时间戳字符串、config token、外层随机数的直接拼接。S5 | 一致；回归覆盖毫秒尾数以及内外层随机数不同的情况。 |
| 内层时间 | 构造补传书籍记录时取当前秒级时间；历史归属放在 `hours`。S2 | 一致。没有把历史阅读时间冒充当前请求时间。 |
| 内层签名 | 按 VID、deviceId、appId、bookId、risk、记录创建时区、readingTime、ttsTime、各小时四元组拼接，再结合 guest token、随机数、秒级时间戳计算。S4 | 输入顺序一致；公开请求向量验证签名变换，另有仅时长 DTO 的空 appId 输入回归。 |
| 签名种子 | 读取 feature 的 guest_token，缺失或空值时取客户端内置默认值。S4 | 一致；默认值不是账号凭证。 |
| 只补时长 | chapterUid 为特定哨兵时构造 `BaseBookReadPostBody`，不含 chapterUid、chapterIdx、chapterOffset。S2 | 使用这一官方分支的字段形状，阅读位置由既有进度同步机制处理。没有复现其他会携带坐标的分支。 |
| appId 和 installId | 上述 Base 分支保持默认空串，deviceId 取本机设备标识。S2 | 字段形状一致；deviceId 使用当前 E-Ink 登录凭证绑定的标识。 |
| voiceType 和 inMyShelf | `JSONField(serialize=false)`，不进入 JSON。S6、S7 | 已移除误发的 voiceType；inMyShelf 原本就未发送。 |
| finish | `isFinish()` 经 Fastjson 的 is 前缀规则序列化为 `finish`，Base DTO 默认 false。S6、S7 | 已补齐 `finish=false`。它不在内层签名输入中。 |
| novalTime | 内部属性叫 novelTime，但注解明确把 JSON 名称设为 novalTime。S6 | 原实现正确，保留 novalTime，值为 0。 |
| bookVersion | 取 `BookService.getBookCurrentVersion(bookId)`。S2 | 已补齐：阅读开始时读取当前文件绑定的 `progress_source_book_version` 等版本字段，缺失时核对同书内嵌元数据；随片段落盘。不同版本分批上传，不取云端最新版本回填。无可信信息仍为 0，并记录来源 unavailable；旧片段保留未知状态。 |

## 时长与小时归属

| 项目 | 官方客户端 | 当前实现和结论 |
| --- | --- | --- |
| 增量或累计 | 把新阅读秒数加入本地 OfflineReadingInfo.readingTime，提交累计未发送值；成功后按书清理。S3 | 同一语义：队列只保存开启同步后的新增秒数，成功后移除该批片段。不是提交书籍终身总时长。 |
| 小时字段 | startOfHour、timeZone、readingTime、ttsTime；时长为秒。S2、S8 | 一致；不把本机总统计重复上传。 |
| 小时起点 | 用 GMT+8 日历把分、秒、毫秒置零，再转 Unix 秒。S8 | 一致，等价于 `timestamp - timestamp % 3600`。即使设备在半小时时区也不改小时边界。 |
| 跨小时归属 | `updateReadProgress` 调用 `saveHoursTime$default`，把该次结算秒数加入结算时的当前小时。S3、S8 | **有意不同**：按 KOReader 片段的真实时间范围跨小时拆分。总量守恒，但边界附近每小时的秒数不保证和官方结算方式逐项相同。 |
| 时区含义 | `TimeZone.getRawOffset()`，不包含夏令时；小时保存采集时的值，DTO 创建时区另取当前值。S2、S8 | 已修正：新采集记录和请求使用标准偏移；夏令时、半小时夏令时、负夏令时均有回归。已有队列中的时区保持原值，不追溯改写。 |
| risk | 时钟变更标记 OR 1，异常时区变更标记 OR 4，带入 DTO 和签名。S2、S8、S10 | 已补齐：以真实时钟观测按官方规则生成标记，随片段持久化；同批取位或并参与签名。已观测标记不因后续恢复正常而从旧片段中清除。 |
| 多设备重叠 | 此补传流程提交本机离线数据；客户端代码没有揭示服务端如何合并不同设备的重叠时间。 | 本地水位可防止本插件重复发送，不能证明手机与阅读器的重叠时长会由服务端自动去重。 |

例如某片段从 10:59:50 阅读到 11:00:10，我们保存两个小时各 10 秒；
官方这条结算路径可把本次 20 秒记到结算时的 11 点小时。这是本地采集语义差异，
没有证据表明更精确地拆分小时会触发封号，也不能把它称为逐条复刻官方统计。

## 提交和恢复

| 项目 | 官方客户端 | 当前实现和结论 |
| --- | --- | --- |
| 批次 | 查询最多 10 条离线书籍记录，生成 DTO 列表后提交；这条路径未见 600 秒批次限制。S2、S3 | 每批同一本书、同一版本最多 600 秒、100 个片段，是我们的资源与调度设置，**不是官方安全阈值**。 |
| 发送互斥 | `ReportServiceManager.lockOffline()` 控制离线处理。S3 | SQLite claim 加共享 worker 保证本插件同一片段只有一个发送者；另外与进度写入互斥。 |
| 成功判断 | BooleanResult 的 succ 字节等于 1。S9 | 一致；另兼容 JSON true。HTTP 200 本身不算成功。 |
| 清理时机 | 明确成功后按书删除 OfflineReadingInfo。S3 | 明确成功后事务删除本批已 claim 片段，新片段保持待传。确认先落盘，再做可选位置核对。 |
| 失败重试 | 流水线含 `RetryWithDelay(1, 100)`；失败不清理离线记录，后续触发仍可再次提交。S3 | **有意不同**：请求可能已经发出但无明确回执时转待确认，不自动重发，不假定服务端支持幂等。 |
| 配置刷新 | READ_TROUBLE 为空时先同步签名配置。S3 | 每批预检读取 config/feature，增加了只读请求，尚未复刻官方缓存策略。 |
| 位置保护 | 若其他设备位置更新，官方可使用不含坐标的 Base DTO。S2 | 始终选择只补时长的 Base 形状；发送前后核对位置，发现变化暂停后续补传。 |
| 上传节奏 | 此离线代码没有给出防封上传速度或累计时长上限。 | 后台基础批次间隔为 10 秒；阅读中还受设置间隔约束。不能称为官方节奏或防封参数。 |

## 异常标记与本地版本修复

`readtime_clock.lua` 按 S10 的规则实现检测。运行时优先使用 KOReader 的
[CLOCK_BOOTTIME](https://github.com/koreader/koreader/blob/master/frontend/ui/time.lua)，
它包含休眠时间；不支持时退回单调时钟。按设备系统时区的标准偏移检测变化，
不把觅阅显示时区设置或夏令时切换当成系统标准时区变化。

- 对照墙钟和运行时钟的增量，偏差达到 10 秒时识别校时；按官方逻辑，向后校时设置位 1，
  向前校时不因此设置位 1。重启通过 boot id 和运行时钟变化识别。
- 首次标准时区切换建立变化时间；距离上次切换不足 3600 秒的再次切换设置位 4。
  连续 259200 秒没有再次切换时，恢复该检测状态。已经保存到旧片段的位 4 仍保留。
- 从有效进度响应的服务器时间戳观测服务器偏差，采用可用配置的 `server_time_max_offset`，
  缺失时使用客户端默认 600 秒；0 表示关闭此检测。检测状态按官方回调更新，后续采集采用相应位 1。

检测到校时或无法确定发生时刻的标准时区变化时，在上次可信采样点封窗，再自动建立新基线。
这段边界内无法可靠归属的秒数不补造。时间回拨时持久保留采集下界，防止同一 KOReader 统计前缀再次入队；
尚在设备当前时间之后的片段等待时间恢复，不提交成未来阅读记录。

`readtime_metadata.lua` 只接收当前文件路径和书籍身份一致的下载记录或内嵌元数据。
文件版本在窗口创建时固定，即使之后刷新书架、更新云端目录或替换下载记录，也不会改变已采集片段的版本。
若新下载包正等待关书后安装，下载记录中的新版本不用于仍在阅读的旧文件，只核对当前文件内嵌版本。
同书不同版本不能混进一个 DTO。发送前会重新核对 risk、版本、时间和时区，
预检期间发生元数据变化时拒绝旧 claim，重新准备签名。

队列写入格式升级为 v3，兼容读取 v1、v2。旧记录没有版本或异常观测信息时不推测补填：
发送使用兼容值 0，诊断来源记为 legacy_unknown。待确认和已发出记录不被重新放回待发送状态。

## 仍有差异和实机验证范围

1. **平台检测来源**：采用 KOReader 提供的时钟而非 Android 广播；缺少休眠计时能力的平台，
   单调时钟回退不等于 Android 的完整事件覆盖。旧记录的未观测历史无法还原。
2. **版本缺失**：旧下载可能没有可信版本字段，此时继续保留 0，不能用云端最新版本冒充文件版本。
3. **官方请求实测对照**：请求头、鉴权生命周期、配置缓存和随机源尚未与同版本官方客户端抓包逐项比对。
   当前成功验证支持的是现有 E-Ink 通道可用，不能扩大为客户端身份和所有行为完全一致。
4. **服务端累计行为**：真实多批次、同小时连续补传、跨日、多设备重叠仍需核对云端增量。
   本地夹具覆盖队列和数据形状，不代表服务端每种场景已通过实机验收。

## 本次修正和验证

修正涉及请求形状、外层时间和随机取值、标准时区偏移，以及新片段的异常标记和文件版本。
旧队列的未知历史元数据不追溯猜测，本次没有发送真实接口请求。
协议夹具按源二进制记录排除字段、序列化名称、时间单位和方法证据。

运行 `tools/test_offline_readtime.py` 验证完整 DTO 字段集合、内外层独立随机数、毫秒签名、
原始历史小时、夏令时处理、官方异常判定边界、休眠和重启、版本隔离、预检并发变化，
以及既有队列恢复与防重放行为。
接口字段一致、请求成功和账号长期安全是不同结论，本核对只支持前两者中已经核实的部分。

## 2026-10-26 实机回传

用户提供的 `miuread-diagnostics-20261026-190731.log` 包含一次完整离线自检：

- 19:00:23 断网后的采集窗口开始，19:01:38 封窗，实际入队 75 秒。
- 19:01:41 在 `/config` 预检阶段遇到网络错误，该轮没有进入写请求；19:02:42 重新预检。
- 19:02:43 仅对该测试窗口发送 75 秒，发送日志记录 `risk=0`、文件版本 `2143702002`、来源 `file_record`。
- 单书云端时长由 10485 增至 10560 秒，增量恰为 75 秒；E-Ink 位置维持章节 `29`、偏移 `478`，Web 回读也为该位置。
- 19:02:45 自检结果为 `passed`，完成本机位置、设置与网络状态的恢复流程。

## 基于 beta.8 的正式功能迁移

正式功能分支基于阅读位置确认修复提交 `8b3884d`，保留 beta.8 的位置同步与待传记录保护。
E-Ink 时长补传仍使用同一统计账本和历史小时接口；Web 兼容路径仅在结束阅读后处理最近两分钟的本次窗口，
每次最多 60 秒，未尝试的剩余片段保留。重新打开书籍、切换账号或重启后不重用旧 Web 窗口。
升级前已确认未发送的旧版时长不猜测时间、不复制进新账本，保留原恢复路径，与新队列串行写入。

迁移包含正式菜单、持久队列、时钟与版本元数据、签名、两种传输、诊断、许可及打包支持。
临时设备自检入口和自检专用下载改动不属于该分支。上述 75 秒入账来自先前测试构建；
beta.8 上的迁移以本地自动化回归核对，未将其描述为新的实机验收结果。

## 2026-10-29 上游 rebase 与缺陷复查

分支已 rebase 到上游 `beta` 的 `a5cbf76`，保留其发布、评论和精确进度修复。
上游 Web Worker 已改为校验可信会话位置；旧入口缺少该参数会在发送前被拒绝。
现在在结束阅读后的补传 Worker 中，经主 Web API 获取新的原始位置，再交给既有 Worker
校验书籍、章节目录和完整请求；不调用旧 Legacy GET，也不回显开书时的旧位置。
响应缺少章节索引时，只使用同一章节 UID 的目录索引补齐，已有索引不一致时仍拒绝发送。
云端位置读取失败、账号切换或队列 claim 失败均不进入 POST，不产生待确认债务。

重复关闭回调保留同一近期 Web 窗口，避免第二次关闭清掉尚未发送的尾段；
重新开书、停用同步、切换账号或休眠仍会使该窗口失效。
保留上游 `READ_TIME_BEST_EFFORT` 的旧版跨会话补报关闭规则；历史段落中的旧恢复策略
仅描述 beta.8 迁移时的行为，不代表当前默认配置。新持久队列的 E-Ink 离线补传不受该开关影响。

新增回归覆盖真实 Web Worker 的写前 claim、新云端位置、缺失章节索引、读取失败、
错误书籍、登录会话变化和重复关闭。此次没有向真实微信读书服务发出请求。

## 2026-10-29 上游设计收敛复查

撤回自建 Web 队列上传、临时会话标识及写前 claim 钩子。Web Worker、适配器、周期服务、
配置和旧版补报函数恢复上游实现；Web 继续使用首次约 15 秒、随后约 60 秒及关书尾段链路，
不重新引入 Legacy GET、不复活跨会话债务、不重放不确定请求。
E-Ink 队列只通过原有 E-Ink 授权、HTTP 和通道策略发送，不降级为 Web。
每次开书固定一个计时来源，重复就绪事件、授权变化和接口设置变化不会重新计入同一阅读时段。
历史 E-Ink 队列等待当前 Web 会话及其尾段处理完成后再发送。

重新读取本机 E-Ink 2.1.2 原始文件，8 个 DEX 和 libencrypt 的 SHA-256 均与夹具一致；
直接解析 DEX 复核了 Base DTO 分支、签名字段顺序、内外时间单位、独立随机取值范围、
GMT+8 小时边界、risk 字段、原始文件版本及 succ=1 成功判定。字段协议与既有核对一致，
本轮没有为模仿客户端身份修改设备标识、请求头或授权流程，也没有发送真实接口请求。

仍保留明确差异：跨小时按实际阅读区间拆分；每批最多 600 秒是本地资源限制；
不确定写入不自动重发；每批读取配置；随机源仍为 Lua PRNG，官方使用 SecureRandom。
这些差异不能被描述为官方“安全阈值”。多批次记账、跨日、多设备重叠和当前构建仍需实机核对。
协议字段接近不能保证不封号；官方[用户协议](https://cdn.weread.qq.com/app/weread_user_agreement_android_s.html)
也对未经授权的第三方接入作出限制。
