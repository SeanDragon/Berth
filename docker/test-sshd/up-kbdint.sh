#!/bin/bash
# keyboard-interactive 专用测试 sshd(issue #12 堡垒机 MFA 回归):
# 禁用 password,只留 keyboard-interactive(PAM 提示输密码,走 RFC 4256 INFO_REQUEST)。
# 监听 127.0.0.1:2223,与常规 test sshd(2222)并存。
# 用法: ./up-kbdint.sh    停止: docker rm -f berth-test-kbdint
set -euo pipefail

docker rm -f berth-test-kbdint >/dev/null 2>&1 || true
docker run -d --name berth-test-kbdint \
  -p 127.0.0.1:2223:2222 \
  -e PASSWORD_ACCESS=true \
  -e USER_NAME=dev \
  -e USER_PASSWORD=berth-kbdint \
  lscr.io/linuxserver/openssh-server:latest >/dev/null

# 等 sshd 起来后改认证方式:关 password,开 kbd-interactive(经 PAM)。
# 注意不能 docker restart —— 镜像的 init 脚本每次启动都会按 PASSWORD_ACCESS
# 重写 sshd_config,把改动冲掉;改完给 sshd 发 SIGHUP 让它原地重读配置。
sleep 3
docker exec berth-test-kbdint sh -c '
  CONF=/config/sshd/sshd_config
  sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$CONF"
  sed -i "s/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/" "$CONF"
  sed -i "s/^#\?UsePAM .*/UsePAM yes/" "$CONF"
  kill -HUP $(pgrep -o -f "sshd.pam.*listener" || pgrep -o sshd)
'
sleep 1

echo "kbd-interactive test sshd 已启动: 127.0.0.1:2223  user=dev  password=berth-kbdint"
echo "验证: ssh -o PreferredAuthentications=keyboard-interactive -p 2223 dev@127.0.0.1"
