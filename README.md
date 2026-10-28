# autClaw

本仓库提供 autClaw 的 Docker 镜像说明与发布产物。镜像分精简版和完整版，按功能需求选择即可。

## 一键安装（推荐）

仓库根目录的 `install.sh` 提供交互式一键安装：自动检测架构、并行测速 GitHub 加速源并直连兜底，支持直装版与 Docker，两条链路都可以选择是否安装 ffmpeg。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WGwuzhi/autClaw/main/install.sh)
```

脚本需要 root 权限，但不用手动加 `sudo`：检测到非 root 时会自动通过 `sudo` 重新执行（会提示输入密码）。也可以先下载再运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/WGwuzhi/autClaw/main/install.sh
bash install.sh
```

执行后只需要按序号选择：

1. 安装方式：直装版 / Docker
2. 安装（或宿主机数据）目录，默认 `/opt/autclaw`
3. 是否安装 ffmpeg
4. 访问端口，默认 `8200`

脚本会自动完成：

- `amd64` / `arm64` 架构检测；
- 并行测速内置的 GitHub 加速源，选最快源下载最新 release；失败时按顺序回退，直连始终兜底；
- 下载 `autclaw-bundle-linux-<arch>.tar.gz`，并用同一 release 的 `SHA256SUMS` 校验；
- 直装版：安装 `mise`、运行产物和可选的 ffmpeg，注册 `autclaw.service`（没有 systemd 时用 nohup 后台运行）；
- Docker：拉取 `nolan1121953/autclaw:latest`，选择 ffmpeg 时改用 `nolan1121953/autclaw:full`，预拉取运行产物后创建并启动容器；
- 等待 `/healthz` 就绪，输出访问地址、日志和停止命令。

直装版默认以 root 运行，与官方容器行为一致；数据、`dist/`、`plugin/`、`envs/` 都保存在所选目录，重跑脚本会保留用户插件和数据库。

非交互场景可以用环境变量预设选项：

```bash
AUTCLAW_INSTALL_MODE=direct \
AUTCLAW_INSTALL_DIR=/opt/autclaw \
AUTCLAW_INSTALL_FFMPEG=1 \
AUTCLAW_HTTP_PORT=8200 \
bash <(curl -fsSL https://raw.githubusercontent.com/WGwuzhi/autClaw/main/install.sh)
```

设置 `AUTCLAW_NONINTERACTIVE=1` 后，缺少必填项会直接报错。`AUTCLAW_GITHUB_PROXY`、`AUTCLAW_MISE_VERSION`、`AUTCLAW_IMAGE`、`AUTCLAW_SKIP_PULL` 等高级选项见脚本头部注释。

> 脚本安装的是 `WGwuzhi/autClaw` 发布的最新 release，不会在本机构建源码。Docker 模式按 rootful Docker 设计；使用 rootless Docker 时请改用直装版或手动部署。

## 镜像版本

| 镜像 | Dockerfile | 说明 |
| --- | --- | --- |
| `nolan1121953/autclaw:latest` | `autclaw.Dockerfile` | 精简版（默认） |
| `nolan1121953/autclaw:full` | `autclaw-full.Dockerfile` | 完整版 |

完整版 = 精简版 + 音视频转码：

- `ffmpeg`、`libavcodec-extra`：语音 / 视频转码

两个镜像都不含浏览器；网页截图 / 页面渲染需要自行补装 chromium 和中文字体，见「按需安装依赖」。

### 精简版不支持

- 音频 / 视频转码：没有 ffmpeg / ffprobe
  - 飞书：语音转 Opus、视频转 MP4
  - 微信公众号：语音转 AMR（发送）、AMR 转 WAV（接收）
  - 千寻：语音转 AMR、视频转 MP4

QQ、Telegram、微信官方 Bot 发送媒体时使用原格式，不依赖 ffmpeg，精简版可正常使用。

需要转码请部署 `:full`。

## 按需安装依赖

只想补某一项能力时，可以在运行中的容器里直接安装，装完立即生效，不用重启容器。容器重建或升级镜像后会丢失，长期使用请自建镜像（见下文）。

### 音视频转码（ffmpeg）

```bash
docker exec -it autclaw bash -lc \
  'apt-get update && apt-get install -y --no-install-recommends ffmpeg libavcodec-extra && rm -rf /var/lib/apt/lists/*'
```

- 飞书语音（Opus）、飞书 / 千寻视频（MP4）：装 `ffmpeg`
- 微信公众号 / 千寻语音（AMR）：装 `ffmpeg libavcodec-extra`

直装版的安装脚本会自动补装 `libavcodec-extra`，并在结束时探测 `libopencore_amrnb` 编码器；缺少时会在安装总结里标注“AMR 语音转码不可用”。

### 网页截图（chromium + 中文字体）

chromium 本体约 300MB，加上依赖通常 400MB 以上，所以两个镜像都没有内置。

```bash
docker exec -it autclaw bash -lc \
  'apt-get update && apt-get install -y --no-install-recommends chromium fonts-wqy-zenhei && rm -rf /var/lib/apt/lists/*'
```

中文字体按需选一个，不装的话截图里的中文会显示成方块：

| 包 | 安装后占用 | 说明 |
| --- | --- | --- |
| `fonts-wqy-zenhei` | 约 16MB | 常用中文够用，推荐 |
| `fonts-noto-cjk` | 约 91MB | 字形覆盖更全，适合生僻字、多语言页面 |

验证安装：

```bash
docker exec autclaw chromium --version
docker exec autclaw ls /usr/share/fonts/truetype/wqy   # fonts-wqy-zenhei
docker exec autclaw ls /usr/share/fonts/opentype/noto  # fonts-noto-cjk
```

容器默认以 root 运行，Chromium 必须带 `--no-sandbox` 才能启动；插件没传这个参数时会报 `Running as root without --no-sandbox is not supported`，需要在插件里补上（chromedp：`chromedp.Flag("no-sandbox", true)`）。

### 自建镜像（长期方案）

```dockerfile
FROM nolan1121953/autclaw:latest
# 语音 / 视频转码
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg libavcodec-extra && \
    rm -rf /var/lib/apt/lists/*
# 网页截图 + 中文字体
RUN apt-get update && \
    apt-get install -y --no-install-recommends chromium fonts-wqy-zenhei && \
    rm -rf /var/lib/apt/lists/*
```

只需要截图时删掉转码那一层；已有转码能力时，把基础镜像换成 `nolan1121953/autclaw:full` 只保留截图层。

```bash
docker build -t autclaw:media .
docker rm -f autclaw
docker run -d --name autclaw --restart unless-stopped \
  --network bridge -p 8200:8200 \
  -v /opt/autclaw:/opt/autclaw \
  autclaw:media
```

## 部署要求

- Linux `amd64` / `arm64`
- Docker 部署：已安装并启动 Docker（一键脚本按 rootful Docker 设计）
- 一键脚本：需要 root 权限（脚本会自动通过 `sudo` 提权）；直装版会自动安装 `mise`，Docker 模式需要宿主机可访问 Docker Hub
- 容器端口 `8200`
- 持久化目录 `/opt/autclaw`（数据库、插件、运行时都在这里）
- 宿主机可访问 GitHub（首次启动拉取 release bundle）与 Docker Hub
- 建议使用 bridge 网络 + 端口映射

## 部署

```bash
docker run -d \
  --name autclaw \
  --restart unless-stopped \
  --network bridge \
  -p 8200:8200 \
  -v /opt/autclaw:/opt/autclaw \
  nolan1121953/autclaw:latest
```

完整版把镜像换成 `nolan1121953/autclaw:full` 即可。

启动后访问 `http://服务器IP:8200`。首次启动会自动拉取 release bundle 并安装默认运行时，需要几分钟。

### 精简版 / 完整版切换

挂载目录保持不变，只换镜像重建容器，数据不会丢失：

```bash
docker rm -f autclaw
docker run -d --name autclaw --restart unless-stopped \
  --network bridge -p 8200:8200 \
  -v /opt/autclaw:/opt/autclaw \
  nolan1121953/autclaw:full
```

## 升级

### 1. 后台在线升级（推荐）

登录后台，点击右上角的更新图标 → 系统升级 → 检查更新 → 升级。完成后自动重启。

### 2. 上传升级包

系统升级 → 上传压缩包升级，选择 release 中的 `autclaw-bundle-linux-<arch>.tar.gz`。

### 3. 更新镜像

```bash
docker pull nolan1121953/autclaw:latest
docker rm -f autclaw
docker run -d --name autclaw --restart unless-stopped \
  --network bridge -p 8200:8200 \
  -v /opt/autclaw:/opt/autclaw \
  nolan1121953/autclaw:latest
```

数据都在 `/opt/autclaw`，重建容器不影响。

### 4. 手动替换产物

适用于无法在线升级或需要指定版本：

```bash
cd /tmp
base=https://github.com/WGwuzhi/autClaw/releases/latest/download
curl -fLO "$base/autclaw-bundle-linux-amd64.tar.gz"
curl -fLO "$base/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf autclaw-bundle-linux-amd64.tar.gz

docker stop autclaw
install -m 0755 autclaw/autclaw /opt/autclaw/autclaw
rm -rf /opt/autclaw/dist && cp -a autclaw/dist /opt/autclaw/dist
cp -a autclaw/plugin/. /opt/autclaw/plugin/
docker start autclaw
```

> 升级包只包含 7 个系统 middleware 文件，`plugin/adapters`、`plugin/replies` 和普通脚本不会被覆盖。升级前仍建议备份 `/opt/autclaw`。
