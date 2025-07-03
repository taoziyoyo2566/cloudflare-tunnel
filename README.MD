# python3 -m http.server 10101

# Cloudflare Tunnel 管理脚本

一个功能完整的 Cloudflare Tunnel 管理工具，支持隧道创建、配置管理、DNS路由、服务管理和连通性测试。

## 📋 功能特性

### 🚀 核心功能
- **隧道管理**：创建、删除、列出隧道
- **配置管理**：添加、删除、测试入口规则
- **DNS路由**：自动管理DNS记录
- **服务管理**：启动、停止、重启隧道服务
- **状态监控**：查看服务状态和日志
- **连通性测试**：验证隧道配置是否正确

### 🔧 高级功能
- **多隧道支持**：同时管理多个隧道
- **配置验证**：自动验证配置文件语法
- **备份恢复**：自动备份和配置恢复
- **错误处理**：完善的错误处理和回滚机制
- **用户友好**：数字选择界面，避免手动输入错误

## 📁 文件结构

```
cf-tunnel-manager/
├── cf-tunnel-manager.sh    # 主管理脚本
├── test_server.py          # 测试HTTP服务器
├── test_page.html          # 测试页面模板
├── add_test_rule.py        # 测试规则添加工具
└── README.md               # 本说明文件
```

## 🛠️ 系统要求

### 必需软件
- **操作系统**：Debian/Ubuntu Linux
- **权限**：root 或 sudo 权限
- **软件包**：
  - `wget` - 下载工具
  - `curl` - HTTP客户端
  - `python3` - Python解释器
  - `python3-yaml` - YAML处理库
  - `systemd` - 系统服务管理

### 网络要求
- 能够访问互联网
- 能够连接到 Cloudflare API (api.cloudflare.com)

## 🚀 快速开始

### 1. 下载和准备
```bash
# 下载脚本文件到工作目录
cd /opt/cf-tunnel-manager
wget [脚本下载链接]

# 添加执行权限
chmod +x cf-tunnel-manager.sh
chmod +x test_server.py
chmod +x add_test_rule.py
```

### 2. 首次运行
```bash
sudo ./cf-tunnel-manager.sh
```

### 3. 系统初始化
```
选择 0) System Setup & Environment Check
```
这将自动：
- 安装必要的系统依赖
- 安装或更新 cloudflared
- 引导 Cloudflare 认证

### 4. 创建第一个隧道
```
选择 1) Create New Tunnel
输入隧道名称，如：my-first-tunnel
```

### 5. 配置域名规则
```
选择 4) Add Ingress Rule
选择隧道
输入域名：app.example.com
输入服务地址：http://127.0.0.1:8080
```

### 6. 创建DNS路由
```
选择 15) Manage DNS Routes
选择 2) Add DNS route
选择隧道
输入域名：app.example.com
```

### 7. 启动隧道服务
```
选择 6) Start Tunnel Service
选择要启动的隧道
```

## 📖 详细功能说明

### 🏗️ 设置和信息
| 选项 | 功能 | 说明 |
|------|------|------|
| 0 | 系统设置与环境检查 | 安装依赖、配置认证 |
| 1 | 创建新隧道 | 创建新的 Cloudflare Tunnel |
| 2 | 列出所有隧道 | 显示所有隧道及状态 |
| 3 | 显示隧道详情 | 查看隧道配置和DNS路由 |

### ⚙️ 配置管理
| 选项 | 功能 | 说明 |
|------|------|------|
| 4 | 添加入口规则 | 配置域名到服务的映射 |
| 5 | 测试入口规则 | 验证URL匹配规则 |
| 11 | 删除入口规则 | 移除域名配置 |

### 🔧 服务管理
| 选项 | 功能 | 说明 |
|------|------|------|
| 6 | 启动隧道服务 | 启动并设置开机自启 |
| 7 | 停止隧道服务 | 停止隧道服务 |
| 8 | 重启隧道服务 | 重启隧道服务 |
| 9 | 显示服务状态 | 查看服务状态和日志 |

### 🌐 DNS和路由
| 选项 | 功能 | 说明 |
|------|------|------|
| 15 | 管理DNS路由 | 自动管理Cloudflare DNS记录 |

### 🔧 维护功能
| 选项 | 功能 | 说明 |
|------|------|------|
| 10 | 删除隧道 | 完全删除隧道和相关配置 |
| 13 | 备份与恢复 | 配置文件备份和恢复 |
| 14 | 更新Cloudflared | 更新到最新版本 |

### 🧪 测试功能
| 选项 | 功能 | 说明 |
|------|------|------|
| 16 | 测试隧道连通性 | 验证隧道配置是否正确 |

## 🧪 连通性测试功能

### 临时测试服务
创建一个临时的HTTP测试服务来验证隧道配置：

1. **选择测试隧道**
2. **输入测试域名**（如：test.example.com）
3. **自动启动**端口10101的测试服务器
4. **自动配置**临时入口规则和DNS路由
5. **验证连接**：访问 https://test.example.com
6. **自动清理**：测试完成后自动恢复原始配置

### 现有服务测试
测试已配置的域名连通性：

- **DNS解析测试**：验证域名解析
- **HTTP响应测试**：检查服务响应
- **隧道状态检查**：确认隧道连接状态
- **浏览器测试**：可选择打开浏览器手动验证

## 💻 命令行选项

```bash
# 显示帮助信息
./cf-tunnel-manager.sh --help

# 查看所有隧道服务状态
./cf-tunnel-manager.sh --status

# 查看最近的服务日志
./cf-tunnel-manager.sh --logs
```

## 📝 配置文件

### 隧道配置文件位置
- **配置文件**：`~/.cloudflared/config_<tunnel-name>.yml`
- **认证文件**：`~/.cloudflared/<tunnel-id>.json`
- **备份目录**：`~/cloudflared_backups/`
- **日志文件**：`/var/log/cloudflared_manager.log`
- **系统服务**：`/etc/systemd/system/cloudflared-<tunnel>.service`

### 配置文件示例
```yaml
# Cloudflare Tunnel Configuration
tunnel: 1234abcd-5678-90ef-1234-567890abcdef
credentials-file: ~/.cloudflared/1234abcd-5678-90ef-1234-567890abcdef.json

# Ingress rules - order matters!
ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:8080
  - hostname: api.example.com
    service: http://127.0.0.1:3000
    originRequest:
      noTLSVerify: true
  - service: http_status:404
```

## 🎯 使用场景

### 1. Web应用部署
```
隧道：web-app
域名：app.example.com
服务：http://127.0.0.1:8080
```

### 2. 多服务部署
```
隧道：main-services
规则1：web.example.com -> http://127.0.0.1:8080
规则2：api.example.com -> http://127.0.0.1:3000
规则3：admin.example.com -> http://127.0.0.1:9000
```

### 3. SSH访问
```
隧道：ssh-tunnel
域名：ssh.example.com
服务：ssh://127.0.0.1:22
连接：ssh user@ssh.example.com
```

### 4. 开发测试
```
隧道：dev-tunnel
域名：dev.example.com
服务：http://127.0.0.1:3000
测试：使用测试功能验证配置
```

## 🔒 安全建议

### 配置文件安全
- 配置文件自动设置为 `600` 权限
- 认证文件存储在安全目录
- 定期备份重要配置

### 服务安全
- 隧道使用加密连接
- 仅允许出站连接，无需开放入站端口
- 支持 Cloudflare Access 集成

### 运维安全
- 定期更新 cloudflared
- 监控服务状态和日志
- 及时清理测试配置

## 🚨 故障排除

### 常见问题

#### 1. 认证失败
**问题**：`Cloudflare authentication not found`
**解决**：
```bash
cloudflared tunnel login
# 或使用脚本选项 0 进行系统设置
```

#### 2. 配置验证失败
**问题**：`Configuration validation failed`
**解决**：
- 检查配置文件语法
- 使用选项 5 测试入口规则
- 查看备份文件恢复配置

#### 3. 服务启动失败
**问题**：`Failed to start cloudflared-tunnel.service`
**解决**：
```bash
# 检查服务状态
sudo systemctl status cloudflared-tunnel-name
# 查看详细日志
sudo journalctl -xeu cloudflared-tunnel-name
```

#### 4. DNS解析失败
**问题**：域名无法访问
**解决**：
- 确认DNS路由已创建
- 等待DNS传播（1-2分钟）
- 检查域名是否在Cloudflare管理

#### 5. 测试文件缺失
**问题**：`Required file missing: test_server.py`
**解决**：
确保所有文件在同一目录：
```bash
ls -la test_server.py test_page.html add_test_rule.py
```

### 日志分析
```bash
# 查看管理脚本日志
tail -f /var/log/cloudflared_manager.log

# 查看隧道服务日志
sudo journalctl -u cloudflared-tunnel-name -f

# 查看所有cloudflared服务
sudo systemctl list-units | grep cloudflared
```

### 配置恢复
如果配置损坏，可以：
1. 使用选项 13 从备份恢复
2. 手动恢复备份文件
3. 重新创建隧道配置

## 🔄 更新和维护

### 更新脚本
```bash
# 备份当前配置
sudo ./cf-tunnel-manager.sh
# 选择 13) Backup & Restore -> 1) Create backup

# 下载新版本脚本
wget [新版本链接]

# 替换脚本文件
chmod +x cf-tunnel-manager.sh
```

### 更新cloudflared
```bash
# 使用脚本更新
sudo ./cf-tunnel-manager.sh
# 选择 14) Update Cloudflared

# 或手动更新
sudo ./cf-tunnel-manager.sh
```

### 定期维护
- **每月**：检查并更新 cloudflared
- **每周**：查看服务状态和日志
- **配置变更前**：创建配置备份
- **重要更新前**：测试隧道连通性

## 🤝 贡献

### 报告问题
如发现问题，请提供：
- 操作系统版本
- cloudflared 版本
- 错误日志内容
- 复现步骤

### 功能建议
欢迎提出新功能建议和改进意见。

## 📄 许可证

本项目遵循开源许可证，请查看 LICENSE 文件了解详情。

## 📞 支持

- **官方文档**：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- **Cloudflare 社区**：https://community.cloudflare.com/
- **GitHub Issues**：[项目Issue页面]

---

**最后更新**：2025年7月
**版本**：v2.1
**兼容性**：cloudflared 最新版本