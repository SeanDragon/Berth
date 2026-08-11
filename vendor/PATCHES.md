# Vendored packages & patches

`vendor/Citadel` 与 `vendor/swift-nio-ssh` 是本地 vendor 的依赖,`project.yml` 通过本地
路径引用(不再走 SPM 远程)。基线:

- **Citadel** 0.12.0(github.com/orlandos-nl/Citadel @ 0.12.0)
- **swift-nio-ssh** 0.3.4(github.com/Joannis/swift-nio-ssh @ b93961a,Citadel 用的 fork)

vendor 后各自删除了 `.git`,`Citadel/Package.swift` 的 nio-ssh 依赖改为 `.package(path: "../swift-nio-ssh")`。

## 补丁:RSA 用 rsa-sha2-512 签名(替代 SHA-1 ssh-rsa)

**动机**:Citadel 原生只用 SHA-1(`ssh-rsa`)给 RSA 密钥签名,OpenSSH 8.8+ 默认拒收,
导致 RSA 密钥连不上现代服务器(报「服务器拒绝了认证」)。RFC 8332 的 `rsa-sha2-256/512`
是替代方案:**密钥 blob 类型仍是 `ssh-rsa`,但签名算法名与签名哈希换成 SHA-2**。

难点:nio-ssh 把「user-auth 广播的签名算法名」和「密钥 blob 类型」共用同一个
`publicKeyPrefix`,无法只改 Citadel。故补丁分布在两个包,均以 `[Berth patch]` 注释标记。

### swift-nio-ssh
- `Keys And Signatures/CustomKeys.swift`:给 `NIOSSHPublicKeyProtocol` 加
  `static var userAuthPrefix`,默认 `= publicKeyPrefix`(对所有现有密钥无影响)。
- `Keys And Signatures/NIOSSHPublicKey.swift`:给 wrapper 加 `userAuthPrefix` 计算属性,
  仅 `.custom` 密钥返回自定义值,其余等于 `keyPrefix`。
- `SSHMessages.swift` `writeUserAuthRequestMessage`:算法名字段改用 `key.userAuthPrefix`。
- `User Authentication/UserAuthSignablePayload.swift`:待签 payload 的算法名改用
  `publicKey.userAuthPrefix`(RFC 8332 §3.3,签名数据里的算法名须与广播一致)。

### Citadel
- `Algorithms/RSA.swift`:
  - `PublicKey.userAuthPrefix = "rsa-sha2-512"`(`publicKeyPrefix` 保持 `"ssh-rsa"`)。
  - `Signature.signaturePrefix = "rsa-sha2-512"`。
  - `PrivateKey.signature(for:)`:`SHA512` + `NID_sha512`(原为 SHA-1 + `NID_sha1`)。

### 影响面与已知边界
- ed25519 / ECDSA / 密码认证:不受影响(`userAuthPrefix` 默认等于原 `keyPrefix`)。
- RSA **验签**(`PublicKey.isValidSignature`)仍是 SHA-1,只在 RSA 作 **host key** 时用;
  连接普遍用 ed25519/ecdsa host key,故未受影响。若将来需连「host key 为 ssh-rsa 且用
  SHA-2 签 KEX」的服务器,需再补验签路径(当前不阻塞)。
- 验证:对 OpenSSH 9.2 真机(192.168.1.111 / .222)用 RSA 密钥连通 OK;ed25519 / 密码 /
  known_hosts 全回归通过;35 项单测通过。

## 补丁:connect(on:settings:) 在 event loop 上加 handler

`Sources/Citadel/ClientSession.swift` 的 `SSHClientSession.addHandlers` 原来直接调
`channel.pipeline.syncOperations.addHandlers(...)`,而 syncOperations 要求在 channel 自身的
event loop 上执行。`SSHClient.connect(on:settings:)`(经代理自建 channel 时用)从任意异步
上下文调用它,触发 `assertInEventLoop` 崩溃。补丁把 addHandlers 包进 `channel.eventLoop.submit { … }`,
使其在正确的 event loop 上运行。标记 `[Berth patch]`。

## 补丁:DataToBufferCodec 设为 public

`Sources/Citadel/DirectTCPIP/Client/DirectTCPIP+Client.swift` 的 `DataToBufferCodec`
(SSHChannelData ↔ ByteBuffer)原为 `internal`。远程端口转发的 forwarded-tcpip 入通道
**不会**自动安装此 codec(direct-tcpip 会),导致包成 `NIOAsyncChannel<ByteBuffer>` 后收不到
数据。补丁把类与其协议方法、init 设为 `public`,Berth 在 `withRemotePortForward` 的
`configure` 闭包里手动 `addHandler(DataToBufferCodec())`。标记 `[Berth patch]`。

## 补丁:握手/认证失败时关闭底层 channel

Citadel 三条连接路径(`SSHClientSession.connect(settings:)` 直连、`SSHClient.connect(on:settings:)`
代理、`SSHClient.jump(to:)` 跳板)在 `handshakeHandler.authenticated` 失败时都**不关闭 channel**,
每次失败连接会留下一条半开 TCP,直到服务器 LoginGraceTime(默认 2 分钟)回收。半开连接
占用 sshd 的 MaxStartups 名额,并助长 OpenSSH 9.8+ PerSourcePenalties 的源 IP 封禁
(表现为后续连接在版本交换前即被服务器关闭)。补丁在三处失败路径统一 `channel.close(promise: nil)`:
- `ClientSession.swift` `connect(settings:)`:future 链尾加 `flatMapError`。
- `Client.swift` `connect(on:settings:)` 与 `jump(to:)`:`authenticated` 外包 do/catch。

均标记 `[Berth patch]`。

## 补丁:keyboard-interactive 认证(RFC 4256,堡垒机 MFA)

**动机**(issue #12):阿里云堡垒机等「密码 + MFA 动态码」登录走 keyboard-interactive,
nio-ssh 完全没有实现该方法,这类服务器无法连接。

### swift-nio-ssh
- `SSHMessages.swift`:新增 `UserAuthInfoRequestMessage`(60)/`UserAuthInfoResponseMessage`(61)
  及其编解码。**报文号 60 与 PK_OK 复用**(RFC 4252/4256 历史遗留),解码按内容判别:先按
  PK_OK 解(首字段必为已知密钥算法名),失败回退按 INFO_REQUEST 解。客户端只要不发
  「无签名 publickey 试探」(Citadel 从不发)就无歧义。`UserAuthRequestMessage.Method`
  增加 `.keyboardInteractive(submethods:)` 及读写。
- `UserAuthenticationMethod.swift`:`NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive`
  (解析/广播 "keyboard-interactive");offer 增加 `.keyboardInteractive`;公开
  `NIOSSHKeyboardInteractiveChallenge`(name/instruction/prompts)。
- `ClientUserAuthenticationDelegate.swift`:协议新增 `keyboardInteractiveChallenge(_:responsePromise:)`,
  带默认实现(直接失败),现有 delegate 不受影响。
- `UserAuthenticationStateMachine.swift`:客户端 `awaitingResponses` 状态下收 INFO_REQUEST →
  调 delegate 应答(异步,等 UI 输 MFA 码),状态不变;`sendUserAuthInfoResponse` 记账;
  服务端收到 kbd-int 请求一律按失败应答(Berth 只做客户端)。
- `SSHConnectionStateMachine.swift` + `Operations/AcceptsUserAuthMessages.swift` +
  `Operations/SendsUserAuthMessages.swift`:userAuthentication 状态下 INFO_REQUEST 入站
  分发与 INFO_RESPONSE 出站序列化。

### Citadel
- `SSHAuthenticationMethod.swift`:
  - 记录在途 implementation,`keyboardInteractiveChallenge` 转发给当前 `.custom` 实现
    (否则新协议方法落在默认实现上直接失败)。
  - **多轮认证修复**:`.custom` 在途时后续 `nextAuthenticationType` 回调持续转发给它,
    由它自管耗尽。原逻辑每轮弹出一个 implementation,单个 custom delegate 第二轮就被
    误判「全部用尽」——password 失败转 kbd-int 永远走不通。
  - offer 校验 switch 补 `.keyboardInteractive` 分支。

### Berth 侧配套(非 vendor)
- `Core/SSH/KeyboardInteractiveAuth.swift`:认证 delegate(password 先行,失败转 kbd-int;
  首个不回显提示自动用存储密码作答,MFA 码冒泡 UI)+ 质询呈现模型。
- `TerminalSession`:`keyboardInteractivePrompt` + sheet(`KeyboardInteractivePromptSheet`),
  `.password` 认证统一走该 delegate。
- 验收:`docker/test-sshd/up-kbdint.sh`(2223,仅 kbd-int)+ `BERTH_KBDINT_AUTOTEST=1`
  (存储密码自动应答、无密码 UI 质询两条路径)。

## 升级 Citadel/nio-ssh 时
本地 vendor 已脱离 SPM 版本管理。若要升级,需重新 vendor 对应版本并重放上述 `[Berth patch]`
改动(`grep -rn "\[Berth patch\]" vendor/` 可列出全部补丁点)。
