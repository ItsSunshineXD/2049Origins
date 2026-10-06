# CRE 赏金演示

这个目录是 Chainlink CRE 机密工作流的完整演示。飞地里的计算信任 AWS Nitro TEE，离开飞地之后的签名报告信任 Workflow DON。触发器、链上读写和工作流二进制对 DON 可见。工作流只要跑了，运行这件事本身 DON 就看得到。

未公开的是 `AttackDeployer` 的 creation bytecode。本地 simulate 把它放进 `SECRET_CREATION_CODE`。处理函数在飞地里 `getSecret`，再向本机 anvil 发 `eth_call`。报告和返回字符串里只有 journal 加收款地址，没有字节码。

`postBalance` 是构造函数 `assembly { return(...) }` 的返回值。飞地不会在执行后再读一次金库余额。撒谎的构造函数只要返回真实的 `pre` 和一个低于阈值的 `post`，报告里的数字也会如此。你选中的 RPC 能看见这笔 `eth_call` 的字节码。这个 demo 的 RPC 是本机 anvil。

## 输入

`bounty-cre/config.staging.json` 里的地址由 `script/cre-demo.sh` 在部署之后写成临时文件。仓库里的那份是占位。

| 字段 | 含义 |
| --- | --- |
| `rpcUrl` | 飞地里 `eth_call` 的地址。demo 是 `http://127.0.0.1:18545` |
| `secretId` | `CREATION_CODE`，对应环境变量 `SECRET_CREATION_CODE` |
| `vault` / `bounty` | 本机刚部署的金库和 `CreBounty` |
| `caller` | anvil 账户 0。`eth_call` 的 `from` |
| `payout` | anvil 账户 1。报告里的收款地址 |
| `value` | 创建交易附带的 1 ETH |
| `threshold` | 1 ETH。谓词是 `pre >= threshold && post < threshold` |

链上 `CreBounty` 在构造时固定 forwarder、workflow id、workflow owner，以及 workflow name 的 bytes10。name 的算法是 `sha256(name)` 的十六进制前 10 个字符，再把这 10 个 ASCII 字符当作 `bytes10`。demo 的名字是 `bounty-cre`。没有管理员热更新。

`onReport` 的 metadata 是打包的 `workflowId || workflowName || workflowOwner`。长度至少 62 字节。生产环境的 KeystoneForwarder 会在后面多带 2 字节 report id，这两种长度都接受。

## 跑

需要 Foundry、`cre` CLI、bun，以及 solc 0.8.28。不需要 Docker，不需要 `ALCH_KEY`。`cre workflow simulate` 要先 `cre login`，或者导出 `CRE_API_KEY`。不要把这个 key 写进仓库。主网机密工作流权限是另一件事，simulate 用不到。

在本目录执行：

```bash
bash script/cre-demo.sh
```

`lib/forge-std` 需要 forge-std v1.17.0。没有这份目录时：

```bash
git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std.git lib/forge-std
```

脚本会起一条链 id `11155111` 的 anvil，部署本目录的金库和 `CreBounty`，编译 `examples/reentrancy/Deployer.sol`，把 creation bytecode 放进本地 secret，执行 `cre workflow simulate`，挖一个空块，再用 anvil 账户 2 扮演 forwarder 调用 `onReport`。成功时金库 `paused == true`，赏金余额为 0，账户 1 多 10 ETH，日志里有 `CRE_DEMO_OK`。

端口 `18545` 和另一套演示相同。两条不要同时跑。

主网机密工作流权限还没到之前，不要 `cre workflow deploy`，也不要把 workflow 发到生产 DON。

## 权限到了之后

工作流代码不用重写。换两处，然后重新部署 `CreBounty`：

1. secret 不再由本机环境变量注入，改由 Vault DON 释放进有证明的飞地。`getSecret({ id: "CREATION_CODE" })` 保持不变。
2. 构造参数里的 forwarder、workflow id、workflow owner 换成 Chainlink 给出的主网值。`onReport` 的检查不变。

## 布局

| 路径 | 作用 |
| --- | --- |
| `src/` | `CreBounty` 和本目录自己的 `VulnerableVault` |
| `examples/reentrancy/` | 示例 Deployer。不引用 `src/` |
| `bounty-cre/` | 机密工作流。secret 进，journal 报告出 |
| `script/cre-demo.sh` | 本机 simulate 的端到端检查 |
