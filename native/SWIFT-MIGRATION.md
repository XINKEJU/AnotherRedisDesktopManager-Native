# Objective-C → Swift 迁移方案（native/）

目标：删除 `Redis.m`、`Services.m`、`Transport.m` 及 `ARDM.h`、`Transport.h`、`Bridge.h`，
用纯 Swift 实现同等功能；对外调用面（SwiftUI 已使用的类名/方法名/属性名）保持不变，
行为、错误码、只读名单、日志脱敏、TLS 校验、SSH 转发语义不退化。

## 状态：已完成（M1–M4）

`native/` 下已无任何 `.m` / Objective-C 头文件，`build.sh` 仅用 `swiftc` 编译
`swift/*.swift`；`tests/run.sh` 仅编译 Swift 内核 + Swift 探针。

- `bash native/build.sh` 通过，产物 `native/ARDM Native.app`。
- `bash native/tests/run.sh`：core 93/93、updater 15/15。
- 删除：`Redis.m`、`Services.m`、`Transport.m`、`ARDM.h`、`Transport.h`、`Bridge.h`。
- 三个未提交界面文件（`ARDMCodeView.swift`、`App.swift`、`DetailViews.swift`）原样保留。

当前基线（迁移前）：

- `bash native/build.sh` 通过，产物 `native/ARDM Native.app`。
- `bash native/tests/run.sh`：core 93/93、updater 15/15。
- 三个 `.m` 共约 3,200 行；Swift 侧仅通过 `Bridge.h → ARDM.h / Transport.h` 调用。
- `native/swift/ARDMCodeView.swift`、`App.swift`、`DetailViews.swift` 有未提交的界面改动，**全程不改动**。

## 依赖关系

```
Services.m  ──> ARDMConnectionConfig（导入/导出/生成 JSON）
Transport.m ──> ARDMConnectionConfig（导出连接）
Redis.m     ──> 定义 Config / Keychain / CommandLog / RedisClient / KeyType
```

`ARDMFormatters`、`ARDMLocalization`、`ARDMAppServices` 不被任何 ObjC 文件引用，
只被 Swift 和测试探针调用，因此可以按“整文件替换”推进，不需要生成 Swift→ObjC 头文件。

`ARDMAppDelegate`（`ARDM.h`）实际已在 `App.swift` 中用 Swift 定义；
`ARDMMainWindowController` / `ARDMConnectionSheetController` 只有声明、无实现、无调用，
属于历史残留，随 `ARDM.h` 一并删除。

## 模块划分与顺序

每块完成后立即：编译 → 跑测试 → 删除对应 `.m`/`.h`，再进入下一块。

### M1. Transport.m → `swift/AppServices.swift`

| ObjC | Swift（保持调用面） |
| --- | --- |
| `+availableFonts` | `ARDMAppServices.availableFonts() -> [String]` |
| `+commandReference` | `commandReference() -> [String: Any]` |
| `+customFormatters` / `+saveCustomFormatters:` | `customFormatters() -> [[String: String]]` / `saveCustomFormatters(_:)` |
| `+exportConnectionsJSON` | `exportConnectionsJSON() -> String` |
| `+importConnectionsJSON:error:` | `importConnectionsJSON(_:) throws` |
| `+checkForUpdateWithCompletion:` | `checkForUpdate(_ completion:)` |
| `+pendingUpdateVersion` / `AssetName` / `HasChecksum` | 同名静态方法 |
| `+downloadUpdateWithCompletion:` | `downloadUpdate(_ completion:)` |
| `+installUpdateAtURL:completion:` | `installUpdate(_:completion:)` |
| `+bookmarkForURL:` / `+resolveBookmark:` | `bookmark(for:)` / `resolveBookmark(_:)` |

技术选型：

- 网络：`URLSession` + completion（与现状一致，主线程回调）。
- SHA-256：`CryptoKit.SHA256`（流式分块，替代 CommonCrypto）。
- 代码签名：`Security`（`SecStaticCodeCreateWithPath` / `SecStaticCodeCheckValidity` /
  `SecCodeCopySigningInformation`，保持 `kSecCSCheckAllArchitectures | kSecCSStrictValidate`）。
- 解包/挂载：`Process` 调用 `/usr/bin/ditto`、`/usr/bin/hdiutil`（系统进程）。
- 书签：`URL.bookmarkData(options:.withSecurityScope)`，失败回退普通书签。
- `commands.js`：`JavaScriptCore` 求值后 `JSON.stringify`（与现状一致）。

风险：更新安装的原子交换/回滚顺序、`/Applications` 不可写时的降级路径、
拒绝安装时的文案必须与测试断言一致（探针会匹配错误子串）。

验收：`build.sh` 通过；updater 探针 15 条全部通过；`Transport.m/.h` 删除。

### M2. Services.m → `swift/Formatters.swift` + `swift/Localization.swift`

| ObjC | Swift |
| --- | --- |
| `+viewerNames` | `ARDMFormatters.viewerNames() -> [String]` |
| `+detectViewerForData:` | `detectViewer(for:)` |
| `+render:as:error:` / `+render:as:offset:length:error:` | `render(_:as:error:)` / `render(_:as:offset:length:error:)` |
| `+renderCustom:script:error:` | `renderCustom(_:script:error:)` |
| `+encodableViewers` / `+encode:as:error:` | 同名 |
| `+setProtobufSchema:` / `+setProtobufScopes:root:` | 同名 |
| `+formatJSON:pretty:` / `+validateJSON:` | 同名 |
| `ARDMLocalization` | `final class ARDMLocalization`（`shared()`、`languages`、`currentLanguage`、`t(_:)`、`tText(_:)`） |

技术选型：

- 15 个 viewer 与 12 个可写回路径逐行移植：Hex/Binary dump、JSON token 级格式化（保留大整数）、
  MessagePack、PHP serialize、Protobuf（含嵌套/重复字段/`.proto` scope）、Java 序列化、
  Python Pickle、OverSize 分页。
- 压缩：`import zlib` 的 C API（`inflateInit2`/`deflateInit2`，windowBits 31/15/-15），
  与现状字节级一致；Brotli 继续走系统 `brotli` CLI（`Process`）。
- JavaScriptCore 继续用于 Custom viewer 沙箱（`ARDM_BYTES` + 包裹脚本）。
- 本地化继续解析 `langs/*.js`（改 `export default` 后用 JSC 转 JSON）。

风险：codec 边界与错误文案；`detectViewer` 的判定顺序；大整数不得走 `Double`；
Pickle 的 memo/栈语义；Java 句柄表顺序。全部由 core 探针覆盖。

验收：core 93 条全过；`Services.m` 删除；`ARDM.h` 移除 Formatters/Localization 声明。

### M3. Redis.m → `swift/ConnectionConfig.swift` + `swift/Keychain.swift` + `swift/RedisClient.swift`

| ObjC | Swift |
| --- | --- |
| `ARDMConnectionConfig` | `final class ARDMConnectionConfig: NSObject, NSCopying`，属性名/默认值完全一致 |
| `+loadAll` / `+saveAll:` / `+fromDictionary:` / `-toDictionary` / `-persistenceDictionary` | 同名 |
| `-hydrateSecretsFromKeychain:` / `+consumeKeychainMigrationCount` | 同名 |
| `ARDMKeychain` | `enum ARDMKeychain` 静态方法（Security 通用密码项） |
| `ARDMCommandLog` | `final class ARDMCommandLog`（`time/connectionName/command/cost`） |
| `ARDMKeyType` | `enum ARDMKeyType: UInt`，case 名为 `string/list/set/zSet/hash/stream/reJSON/timeSeries/vector/array/unknown` |
| `ARDMRedisClient` | `final class ARDMRedisClient`，方法名按 Swift 现有调用面保留（`send(_:error:)`、`scanKeys(matching:cursor:count:error:)`、`type(ofKey:error:)`、`ttl(ofKey:error:)`、`value(ofKey:type:error:)`、`startLive(withCommand:onEvent:onError:)` 等） |

技术选型：

- RESP：`CFStream`（C API）阻塞读写 + 自建缓冲区，1:1 移植 `readLine/readExactly/readReply`，
  含 RESP3（`# , _ ( % ~ >`）与超 INT64 十进制字符串保留。
- TLS：沿用 `kCFStreamPropertySSLSettings`，`Security` 构建客户端身份链（PKCS#12 / PEM +
  `SecItemImport`）；默认校验证书链，仅 `tlsInsecure` 放宽。SNI 走 `kCFStreamSSLPeerName`。
  说明：`Network.framework` 的异步 `NWConnection` 与本类同步 `send` 语义冲突较大，
  为保证行为等价，本次保留 CFStream；后续可在 `RESPTransport` 协议后替换。
- SSH：`Process` 调 `/usr/bin/ssh -N -L ...`（与现状一致），端口就绪轮询、askpass 临时脚本、
  退出时 `terminate()`。
- 线程：`NSRecursiveLock` 替代 `@synchronized(self)`，保持 MULTI/EXEC 单临界区与重入。
- 只读拦截：完整保留 200+ 写命令名单（含 `CONFIG SET`、`CLIENT KILL`、`HEXPIRE` 等两段式）。
- 日志：AUTH 掩码、PING 过滤、200 字符截断、Data 显示为 `<n bytes>`、5000 条上限。
- MOVED/ASK：IPv6 方括号与“最后一个冒号”解析、NAT 映射、ASK 临时连接、MOVED 永久改连。
- Sentinel：`SENTINEL get-master-addr-by-name` 后重连主节点。

风险：并发重连（`_didRetry`）、live 连接独立队列、事务回滚 `DISCARD`、SSH 隧道失败清理。

验收：core 探针（含事务并发、MOVED IPv4/IPv6、AUTH 脱敏、只读、Keychain、迁移计数）全过；
`Redis.m`、`ARDM.h`、`Bridge.h` 删除。

### M4. 收尾

- `build.sh`：删除 clang 编译步骤、`-import-objc-header`、不再引用 `Bridge.h`。
- `tests/run.sh`：改为 `swiftc` 编译 Swift 内核 + Swift 探针（不再链接 `.m`）。
- `tests/*/probe.m` → `probe.swift`，断言逐条保留（迁移过程中同步完成，作为每块的验收）。
- 清理 `ARDM.h` 中未实现的 `ARDMMainWindowController` / `ARDMConnectionSheetController` 残留。

## 全局风险与对策

1. **行为回归**：每块都用现有探针做字节级断言；新增 Swift 探针只做 1:1 翻译，不改断言。
2. **TLS/SSH 无法被无网测试覆盖**：代码路径逐行移植，保留原错误码与文案；不做“顺手优化”。
3. **大整数 JSON**：继续使用 token 级 `formatJSON`，禁止 `JSONSerialization` 重编码数字。
4. **日志脱敏**：`AUTH`、`Data` 参数、截断规则保持原样；探针有专项断言。
5. **界面不受影响**：只替换同名的 Swift 类型/方法，不改 SwiftUI 调用；三个未提交界面文件保持原样。
6. **回滚**：每块独立可编译；任何一块失败可单独回退该块的 Swift 文件并暂时保留对应 `.m`。

## 验证命令

```bash
bash native/build.sh
bash native/tests/run.sh
```
