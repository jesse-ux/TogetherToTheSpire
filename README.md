# TogetherToTheSpire

一键部署 WireGuard，用于《杀戮尖塔》广域网联机。

## 这是什么

这个项目提供一个服务端控制脚本，用来在 Linux 服务器上快速部署 WireGuard，并通过终端二维码把客户端配置发给朋友。

支持的核心流程：

- 一键部署环境
- 交互式添加 peer
- 删除 peer
- 查看实时状态
- 删除整套环境

## 支持环境

当前支持：

- Ubuntu
- Debian
- Rocky Linux
- AlmaLinux

当前不支持：

- CentOS 8

## 安装

在服务器上执行：

```bash
curl -fsSL https://gitee.com/jesse-chen1/TogetherToTheSpire/raw/main/wg-setup.sh | sudo bash
```

如果你已经把仓库拉到本地，也可以直接执行：

```bash
sudo ./wg-setup.sh
```

## 使用方式

第一次运行时会进入菜单：

- `1` 部署环境
- `2` 添加 peer
- `3` 删除 peer
- `4` 查看状态
- `5` 删除环境
- `0` 退出

部署完成后，也可以直接用子命令：

```bash
sudo ./wg-setup.sh setup
sudo ./wg-setup.sh add-peer 小明
sudo ./wg-setup.sh remove-peer 小明
sudo ./wg-setup.sh status
sudo ./wg-setup.sh remove-env
```

如果安装过程已经生成了本地入口命令，也可以直接使用：

```bash
sudo together setup
sudo together add-peer 小明
sudo together status
```

## 端口

部署时会要求你手动输入 WireGuard 监听端口。

- 允许范围：`1024-65535`
- 不再使用固定默认端口
- 后续生成的安全组提示、联机说明、状态输出都会使用你输入的端口

## 联机流程

1. 运行 `setup`
2. 输入监听端口
3. 输入要联机的人数
4. 给每个玩家命名
5. 让玩家逐个扫码导入二维码
6. 等待 WireGuard 握手成功
7. 在《杀戮尖塔》里走局域网联机流程

## 防火墙和安全组

脚本会尝试处理本机防火墙：

- `ufw`
- `firewalld`

你还需要在云服务器安全组里手动放行脚本提示的 UDP 端口。

## 注意

- 这是服务器侧部署脚本，不是客户端
- 终端二维码需要在宽度足够的 SSH 终端里查看
- 当前不要在 CentOS 8 上直接使用
- 部署前如果服务器上已有旧的 WireGuard 配置，脚本会提示你确认是否覆盖

