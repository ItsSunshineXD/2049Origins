# CRE 赏金演示

这个目录是 Chainlink CRE 机密工作流在 Solana 上的本地演示。飞地里的计算信任 AWS Nitro TEE，离开飞地之后的签名报告信任 Workflow DON。触发器、链上读写和工作流二进制对 DON 可见。工作流只要跑了，运行这件事本身 DON 就看得到。这不是零知识证明。

## 漏洞

`programs/vulnerable_vault` 是一个正常可用的存取款池：`deposit` 存入并记到签名者自己的仓位，`withdraw` 付清签名者自己的仓位。池子还把闲置 lamports 作为闪电贷借出：`flash_borrow` 转出资金，并通过 Instructions sysvar 确认同一笔交易后面有一条 `flash_end`；`flash_end` 要求金库余额回到借出前的数值。

Solana 不允许程序经由别的程序被重入，所以闪电贷没法回调借款人。借款人改为在 `flash_borrow` 和 `flash_end` 之间放自己的指令。这段区间就是 EVM 里回调期间的那段"状态未结清"窗口。

漏洞是跨指令的重入：`withdraw` 和 `flash_borrow` 在借款未结清时都会拒绝，`deposit` 却没有这道检查。攻击者借出全部闲置资金，用 `deposit` 存回去。金库余额恢复了，`flash_end` 通过；可这笔还款同时变成了攻击者的仓位，`flash_end` 之后再 `withdraw` 就能把它取走。攻击者除手续费和仓位租金外不需要本金。

本地账本里协议方存 10 SOL，金库流动余额是 10 SOL 再加租金，阈值是 1 SOL。正常借款并直接转账归还，金库余额前后不变，谓词不成立。攻击交易是 `flash_borrow → deposit → flash_end → withdraw`，金库只剩租金，谓词成立。链上金库余额不变，因为攻击只发生在模拟里。赏金是另外锁着的 10 SOL。

飞地不读这笔交易的返回数据。模拟前余额来自 `getBalance`，模拟后余额来自 `simulateTransaction` 返回的金库账户。模拟开启签名校验，提交者只能用自己真正持有的密钥签名，不能冒充金库 admin。未公开的是这笔四条指令的攻击交易。

## 输入

收款地址和交易都在机密输入里，格式是 `<收款地址>:<base64 交易>`。公开配置不能改收款地址。工作流拒绝把金库或赏金账户当作收款地址。

| 字段 | 含义 |
| --- | --- |
| `rpcUrl` | 飞地里 JSON-RPC 的地址。demo 是 `http://127.0.0.1:8899` |
| `secretId` | `ATTACK_TX`，对应环境变量 `SECRET_ATTACK_TX` |
| `vault` | 本机刚部署的金库 PDA |
| `bounty` | 本机刚部署的赏金 PDA。只用来拒绝把它当作收款地址 |
| `threshold` | 1 SOL，单位 lamports。谓词是 `pre >= threshold && post < threshold` |

`script/test.sh` 在部署之后写一份临时配置。仓库里的 `bounty-cre/config.staging.json` 是占位。

工作流签出的报告是 96 字节：`pre`、`post`、`slot`、`threshold`（u64 小端），再接收款地址和金库地址。`on_report` 按同样的布局解码，`test.sh` 把工作流输出的这 96 字节原样提交。

本地 forwarder 是 `keys/forwarder.json`。赏金程序只核对这个签名者。它不核对 workflow id，不重放那笔交易，也不验证零知识证明。撒谎的报告只要数字满足阈值，链上检查也会通过。生产环境的 Keystone Forwarder 会先验证 DON 签名，再调用接收程序。

赏金只能由 admin `register`，并且金库的 guardian 必须是赏金 PDA、金库未暂停、余额不低于阈值。admin 撤回要先 `request_cancel`，7 天后才能 `cancel`；等待期间报告照样可以领取，所以 admin 无法看到报告交易后抢先撤回。

你选中的 RPC 能看见这笔 `simulateTransaction`。这个 demo 的 RPC 是本机 `http://127.0.0.1:8899`。

## 跑

需要 Solana CLI（含 `solana-test-validator` 和 `cargo-build-sbf`）、`cre` CLI 和 bun。不需要 Docker，不需要 Foundry，不需要 `ALCH_KEY`。`cre workflow simulate` 要先 `cre login`，或者导出 `CRE_API_KEY`。不要把这个 key 写进仓库。主网机密工作流权限是另一件事，simulate 用不到。

在本目录执行：

```bash
bash script/launch.sh
bash script/test.sh "$(solana-keygen pubkey keys/payout.json)"
```

`launch.sh` 重置一条从 Solana 主网克隆来的本地验证器，克隆当前主网的 feature set，以及 Keystone Forwarder 程序 `GFrSSvQXaVGkc6Nrr8y2msie6pivJkR1s2EnDk4et294` 和它的状态账户 `9FgdPyU28bGMCuJyD34pzw9W7Ys36ziLbT9cbZtsaraV`。克隆只用来证明加载了主网账户。脚本不向这些主网程序发送交易，也不向公共集群广播。

然后它部署金库和赏金程序，协议方存入 10 SOL，锁上 10 SOL 赏金，把地址写进 `proofs/launch.env`，留下验证器后退出。端口是 `8899`。端口已被占用时直接退出。

`test.sh` 的参数是已经存在的收款账户。它先本地模拟一笔正常归还的闪电贷，确认模拟后余额仍不低于阈值。再把攻击交易放进 secret，执行 `cre workflow simulate`。forwarder 提交报告后，金库暂停标志为 1，指定账户增加 10 SOL，链上金库余额与提交前相同。日志里有 `CRE_DEMO_OK`。这步不关闭验证器。

另一套 EVM 演示使用 anvil 端口 `18545`。

主网机密工作流权限还没到之前，不要 `cre workflow deploy`，也不要把 workflow 发到生产 DON。

## 权限到了之后

工作流里的 `getSecret` 和 `simulateTransaction` 不用重写。换两处，然后重新部署赏金程序：

1. secret 不再由本机环境变量注入，改由 Vault DON 释放进有证明的飞地。`getSecret({ id: "ATTACK_TX" })` 保持不变。
2. 本地 forwarder 密钥对换成生产 Keystone Forwarder。主网程序是 `GFrSSvQXaVGkc6Nrr8y2msie6pivJkR1s2EnDk4et294`，状态账户是 `9FgdPyU28bGMCuJyD34pzw9W7Ys36ziLbT9cbZtsaraV`。接收指令要改成该 forwarder 要求的 `on_report` 账户顺序，并重新部署。

## 布局

| 路径 | 作用 |
| --- | --- |
| `programs/vulnerable_vault` | 带闪电贷的存取款池，`deposit` 缺少借款中的锁 |
| `programs/cre_bounty` | 核对报告、暂停金库、支付赏金，带撤回时间锁 |
| `bounty-cre/` | 机密工作流。未公开交易进，96 字节报告出 |
| `script/launch.sh` | 编译并启动本机验证器、金库和赏金 |
| `script/test.sh` | 提交未公开的闪电贷攻击交易并领走赏金 |
| `script/chain.ts` | 部署账户、构造交易、提交报告 |
