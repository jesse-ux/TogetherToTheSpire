# TogetherToTheSpire

《杀戮尖塔》广域网联机专用部署工具。在 Linux 服务器上一键搭建 WireGuard 虚拟局域网，让异地朋友像在同一个 WiFi 下一样联机。

## 联机只需三步

```
1. 服务器执行一键部署 → 自动生成玩家配置和二维码
2. 朋友扫码导入 WireGuard → 等待握手成功
3. 打开《杀戮尖塔》→ 走局域网联机流程
```

## 快速开始

在服务器上执行：

```bash
curl -fsSL https://gitee.com/jesse-chen1/TogetherToTheSpire/raw/main/wg-setup.sh | sudo bash
```

或下载后执行：

```bash
sudo ./wg-setup.sh
```

脚本会引导你完成所有操作：选端口 → 填人数 → 给玩家命名 → 扫码。

## 客户端下载

朋友们需要先安装 WireGuard 客户端，才能扫码连接。

| 平台 | 版本 | 下载方式 |
|------|------|---------|
| Windows | v0.6.1 | [Browse MSIs](https://www.wireguard.com/install/) |
| macOS | v1.0.16 | Mac App Store 搜索 "WireGuard" |
| iOS | v1.0.16 | App Store 搜索 "WireGuard" |
| Android | v1.0 | [仓库内置 APK](assets/android/) 或 Google Play |

安装完成后打开 WireGuard → 点 **+** → 扫描二维码 → 连接。

## 详细联机流程

1. **部署服务器** — 执行 `setup`，输入监听端口（1024-65535）
2. **创建玩家** — 输入联机人数（2-5人），逐个命名
3. **扫码连接** — 把终端上的二维码发给朋友，朋友用 WireGuard 扫码导入
4. **确认连接** — 脚本自动检测握手状态，全部成功即可开游戏
5. **开始联机** — 在《杀戮尖塔》中选择局域网联机

> 部署完成后，脚本会自动在终端打印联机说明，并将完整说明保存到 `~/wg-clients/联机说明.txt`。

## 安全组设置（必须）

脚本会自动处理本机防火墙（ufw / firewalld），但你还需要在**云服务器控制台**手动放行对应的 **UDP 端口**，否则外部客户端无法连接。

部署时脚本会提示具体的端口号和放行方向。

## 日常管理

部署完成后，通过菜单或子命令管理：

```bash
# 交互式菜单（首次运行自动进入）
sudo ./wg-setup.sh

# 或直接用子命令
sudo ./wg-setup.sh add-peer 新玩家    # 添加新玩家
sudo ./wg-setup.sh remove-peer 旧玩家  # 移除玩家
sudo ./wg-setup.sh status             # 查看连接状态
sudo ./wg-setup.sh remove-env         # 卸载整套环境
```

如果安装时生成了本地入口，也可以用：

```bash
sudo together add-peer 新玩家
sudo together status
```

## 支持的服务器系统

| 系统 | 支持情况 |
|------|---------|
| Ubuntu | 支持 |
| Debian | 支持 |
| Rocky Linux | 支持 |
| AlmaLinux | 支持 |
| CentOS 8 | 不支持（内核模块兼容问题） |

## 注意事项

- 这是**服务器端**部署脚本，不是客户端
- 终端二维码需要 SSH 终端宽度足够才能正常显示
- 部署前如果已有旧的 WireGuard 配置，脚本会提示确认是否覆盖
- 如果服务器已有 WireGuard 在运行，新部署会先停止旧服务
